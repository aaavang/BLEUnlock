import Foundation
import CoreBluetooth
import Accelerate

let DeviceInformation = CBUUID(string:"180A")
let ManufacturerName = CBUUID(string:"2A29")
let ModelName = CBUUID(string:"2A24")
let ExposureNotification = CBUUID(string:"FD6F")

func getMACFromUUID(_ uuid: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let cbcache = plist["CoreBluetoothCache"] as? NSDictionary else { return nil }
    guard let device = cbcache[uuid] as? NSDictionary else { return nil }
    return device["DeviceAddress"] as? String
}

func getNameFromMAC(_ mac: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let devcache = plist["DeviceCache"] as? NSDictionary else { return nil }
    guard let device = devcache[mac] as? NSDictionary else { return nil }
    if let name = device["Name"] as? String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed == "" { return nil }
        return trimmed
    }
    return nil
}

class Device: NSObject {
    let uuid : UUID!
    var peripheral : CBPeripheral?
    var manufacture : String?
    var model : String?
    var advData: Data?
    var rssi: Int = 0
    var scanTimer: Timer?
    var macAddr: String?
    var blName: String?
    
    override var description: String {
        get {
            if macAddr == nil || blName == nil {
                if let info = getLEDeviceInfoFromUUID(uuid.description) {
                    blName = info.name
                    macAddr = info.macAddr
                }
            }
            if macAddr == nil {
                macAddr = getMACFromUUID(uuid.description)
            }
            if let mac = macAddr {
                if blName == nil {
                    blName = getNameFromMAC(mac)
                }
                if let name = blName {
                    // If it's just "iPhone" or "iPad", there's a chance we can get the model name in the following code
                    if name != "iPhone" && name != "iPad" {
                        return name
                    }
                }
            }
            if let manu = manufacture {
                if let mod = model {
                    if manu == "Apple Inc." && appleDeviceNames[mod] != nil {
                        return appleDeviceNames[mod]!
                    }
                    return String(format: "%@/%@", manu, mod)
                } else {
                    return manu
                }
            }
            if let name = peripheral?.name {
                if name.trimmingCharacters(in: .whitespaces).count != 0 {
                    return name
                }
            }
            if let mod = model {
                return mod
            }
            // iBeacon
            if let adv = advData {
                if adv.count >= 25 {
                    var iBeaconPrefix : [uint16] = [0x004c, 0x01502]
                    if adv[0...3] == Data(bytes: &iBeaconPrefix, count: 4) {
                        let major = uint16(adv[20]) << 8 | uint16(adv[21])
                        let minor = uint16(adv[22]) << 8 | uint16(adv[23])
                        let tx = Int8(bitPattern: adv[24])
                        let distance = pow(10, Double(Int(tx) - rssi)/20.0)
                        let d = String(format:"%.1f", distance)
                        return "iBeacon [\(major), \(minor)] \(d)m"
                    }
                }
            }
            if let name = blName {
                return name
            }
            if let mac = macAddr {
                return mac // better than uuid
            }
            return uuid.description
        }
    }

    init(uuid _uuid: UUID) {
        uuid = _uuid
    }
}

protocol BLEDelegate {
    func newDevice(device: Device)
    func updateDevice(device: Device)
    func removeDevice(device: Device)
    func updateRSSI(rssi: Int?, active: Bool)
    func updatePresence(presence: Bool, reason: String)
    func bluetoothPowerWarn()
    func monitoredDeviceChanged(uuid: UUID)
}

class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let UNLOCK_DISABLED = 1
    let LOCK_DISABLED = -100
    var centralMgr : CBCentralManager!
    var devices : [UUID : Device] = [:]
    var delegate: BLEDelegate?
    var scanMode = false
    var monitoredUUID: UUID?
    var monitoredPeripheral: CBPeripheral?
    var proximityTimer : Timer?
    var signalTimer: Timer?
    var presence = false
    var lockRSSI = -80
    var unlockRSSI = -60
    var proximityTimeout = 5.0
    var signalTimeout = 60.0
    var pollInterval = 2.0
    var lastReadAt = 0.0
    var powerWarn = true
    var passiveMode = false
    var thresholdRSSI = -70
    var latestRSSIs: [Double] = []
    var latestN: Int = 5
    var activeModeTimer : Timer? = nil
    var connectionTimer : Timer? = nil
    var matchByName = false
    var monitoredName: String?
    var lastMonitoredAt = 0.0
    var probingPeripherals: [UUID : CBPeripheral] = [:]
    var probedUUIDs: Set<UUID> = []

    func scanForPeripherals() {
        guard !centralMgr.isScanning else { return }
        centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        //print("Start scanning")
    }

    func startScanning() {
        scanMode = true
        scanForPeripherals()
    }

    func stopScanning() {
        scanMode = false
        if activeModeTimer != nil {
            centralMgr.stopScan()
        }
    }

    func setPassiveMode(_ mode: Bool) {
        passiveMode = mode
        if passiveMode {
            activeModeTimer?.invalidate()
            activeModeTimer = nil
            if let p = monitoredPeripheral {
                centralMgr.cancelPeripheralConnection(p)
            }
        }
        scanForPeripherals()
    }

    func startMonitor(uuid: UUID) {
        if let p = monitoredPeripheral {
            centralMgr.cancelPeripheralConnection(p)
        }
        monitoredUUID = uuid
        proximityTimer?.invalidate()
        resetSignalTimer()
        presence = true
        monitoredPeripheral = nil
        activeModeTimer?.invalidate()
        activeModeTimer = nil
        scanForPeripherals()
    }

    func resetSignalTimer() {
        signalTimer?.invalidate()
        signalTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
            print("Device is lost")
            self.delegate?.updateRSSI(rssi: nil, active: false)
            if self.presence {
                self.presence = false
                self.delegate?.updatePresence(presence: self.presence, reason: "lost")
            }
        })
        if let timer = signalTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth powered on")
            if activeModeTimer == nil {
                scanForPeripherals()
            }
            powerWarn = false
        case .poweredOff:
            print("Bluetooth powered off")
            presence = false
            signalTimer?.invalidate()
            signalTimer = nil
            if powerWarn {
                powerWarn = false
                delegate?.bluetoothPowerWarn()
            }
        default:
            break
        }
    }
    
    func getEstimatedRSSI(rssi: Int) -> Int {
        while latestRSSIs.count >= latestN {
            latestRSSIs.removeFirst()
        }
        latestRSSIs.append(Double(rssi))
        var mean: Double = 0.0
        var sddev: Double = 0.0
        vDSP_normalizeD(latestRSSIs, 1, nil, 1, &mean, &sddev, vDSP_Length(latestRSSIs.count))
        return Int(mean)
    }

    func updateMonitoredPeripheral(_ rssi: Int) {
        // print(String(format: "rssi: %d", rssi))
        lastMonitoredAt = Date().timeIntervalSince1970
        if rssi >= (unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI) && !presence {
            print("Device is close")
            presence = true
            delegate?.updatePresence(presence: presence, reason: "close")
            latestRSSIs.removeAll() // Avoid bouncing
        }

        let estimatedRSSI = getEstimatedRSSI(rssi: rssi)
        delegate?.updateRSSI(rssi: estimatedRSSI, active: activeModeTimer != nil)

        if estimatedRSSI >= (lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI) {
            if let timer = proximityTimer {
                timer.invalidate()
                print("Proximity timer canceled")
                proximityTimer = nil
            }
        } else {
            startProximityTimer()
        }
        resetSignalTimer()
    }

    func startProximityTimer() {
        guard presence && proximityTimer == nil else { return }
        proximityTimer = Timer.scheduledTimer(withTimeInterval: proximityTimeout, repeats: false, block: { _ in
            print("Device is away")
            self.presence = false
            self.delegate?.updatePresence(presence: self.presence, reason: "away")
            self.proximityTimer = nil
        })
        RunLoop.main.add(proximityTimer!, forMode: .common)
        print("Proximity timer started")
    }

    func resetScanTimer(device: Device) {
        device.scanTimer?.invalidate()
        device.scanTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
            self.delegate?.removeDevice(device: device)
            if let p = device.peripheral {
                self.centralMgr.cancelPeripheralConnection(p)
            }
            self.devices.removeValue(forKey: device.uuid)
        })
        if let timer = device.scanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func connectMonitoredPeripheral() {
        guard let p = monitoredPeripheral else { return }

        // Idk why but this works like a charm when 'didConnect' won't get called.
        // However, this generates warnings in the log.
        p.readRSSI()

        guard p.state == .disconnected else { return }
        print("Connecting")
        centralMgr.connect(p, options: nil)
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false, block: { _ in
            if p.state == .connecting {
                print("Connection timeout")
                self.centralMgr.cancelPeripheralConnection(p)
            }
        })
        RunLoop.main.add(connectionTimer!, forMode: .common)
    }

    func nameMatches(_ name: String?) -> Bool {
        guard let expected = monitoredName, let n = name else { return false }
        return n.trimmingCharacters(in: .whitespaces) == expected
    }

    // Devices with a rotating private MAC address (e.g. Android) show up under a new UUID.
    // Follow the device to the new UUID if it has the same name.
    func switchMonitoredPeripheral(_ peripheral: CBPeripheral) {
        print("Monitored device found by name: \(peripheral.identifier)")
        if let p = monitoredPeripheral {
            centralMgr.cancelPeripheralConnection(p)
        }
        activeModeTimer?.invalidate()
        activeModeTimer = nil
        monitoredUUID = peripheral.identifier
        monitoredPeripheral = peripheral
        for (_, p) in probingPeripherals where p != peripheral {
            centralMgr.cancelPeripheralConnection(p)
        }
        probingPeripherals.removeAll()
        probedUUIDs.removeAll()
        delegate?.monitoredDeviceChanged(uuid: peripheral.identifier)
    }

    func matchMonitoredName(_ peripheral: CBPeripheral, advertisementData: [String : Any], rssi: Int) {
        // Only while the monitored device is missing. A device can advertise under several
        // UUIDs at once, and we don't want to flip between them or connect to every device around.
        guard monitoredName != nil, Date().timeIntervalSince1970 > lastMonitoredAt + 5 else { return }
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if nameMatches(advName ?? peripheral.name) {
            switchMonitoredPeripheral(peripheral)
            return
        }
        // Name is unknown until connected
        guard advName == nil, peripheral.name == nil else { return }
        guard rssi >= thresholdRSSI, !probedUUIDs.contains(peripheral.identifier) else { return }
        print("Probing name of \(peripheral.identifier)")
        probedUUIDs.insert(peripheral.identifier)
        probingPeripherals[peripheral.identifier] = peripheral
        centralMgr.connect(peripheral, options: nil)
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false, block: { _ in
            self.finishProbe(peripheral)
        })
        RunLoop.main.add(timer, forMode: .common)
    }

    func checkProbedName(_ peripheral: CBPeripheral) {
        guard probingPeripherals[peripheral.identifier] != nil else { return }
        if nameMatches(peripheral.name) {
            switchMonitoredPeripheral(peripheral)
            if passiveMode {
                centralMgr.cancelPeripheralConnection(peripheral)
            }
        } else if peripheral.name != nil {
            finishProbe(peripheral)
        }
        // Otherwise wait for peripheralDidUpdateName or the timeout
    }

    func finishProbe(_ peripheral: CBPeripheral) {
        guard probingPeripherals.removeValue(forKey: peripheral.identifier) != nil else { return }
        if peripheral != monitoredPeripheral && devices[peripheral.identifier] == nil {
            centralMgr.cancelPeripheralConnection(peripheral)
        }
    }

    //MARK:- CBCentralManagerDelegate start

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        if let uuid = monitoredUUID {
            if matchByName && peripheral.identifier.description != uuid.description {
                matchMonitoredName(peripheral, advertisementData: advertisementData, rssi: rssi)
            }
            if peripheral.identifier.description == monitoredUUID?.description {
                if monitoredPeripheral == nil {
                    monitoredPeripheral = peripheral
                }
                if activeModeTimer == nil {
                    //print("Discover \(rssi)dBm")
                    updateMonitoredPeripheral(rssi)
                    if !passiveMode {
                        connectMonitoredPeripheral()
                    }
                }
            }
        }

        if (scanMode) {
            if let uuids = advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID] {
                for uuid in uuids {
                    if uuid == ExposureNotification {
                        //print("Device \(peripheral.identifier) Exposure Notification")
                        return
                    }
                }
            }
            let dev = devices[peripheral.identifier]
            var device: Device
            if (dev == nil) {
                device = Device(uuid: peripheral.identifier)
                if (rssi >= thresholdRSSI) {
                    device.peripheral = peripheral
                    device.rssi = rssi
                    device.advData = advertisementData["kCBAdvDataManufacturerData"] as? Data
                    devices[peripheral.identifier] = device
                    central.connect(peripheral, options: nil)
                    delegate?.newDevice(device: device)
                }
            } else {
                device = dev!
                device.rssi = rssi
                delegate?.updateDevice(device: device)
            }
            resetScanTimer(device: device)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral)
    {
        peripheral.delegate = self
        if scanMode {
            peripheral.discoverServices([DeviceInformation])
        }
        checkProbedName(peripheral)
        if peripheral == monitoredPeripheral && !passiveMode {
            print("Connected")
            connectionTimer?.invalidate()
            connectionTimer = nil
            peripheral.readRSSI()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?)
    {
        finishProbe(peripheral)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?)
    {
        // error is nil when we cancelled the connection ourselves, and Bluetooth turning off is handled elsewhere
        guard peripheral == monitoredPeripheral, error != nil, central.state == .poweredOn else { return }
        print("Disconnected: \(error!.localizedDescription)")
        // The link usually drops because the device went out of range, possibly before the averaged
        // RSSI fell below Lock RSSI. Start the lock delay now instead of waiting for the no-signal timeout,
        // and go back to scanning so an advertisement from a device that is still close can cancel it.
        // Forget the readings from before the drop, so they don't outvote a weak advertisement.
        activeModeTimer?.invalidate()
        activeModeTimer = nil
        latestRSSIs.removeAll()
        startProximityTimer()
        scanForPeripherals()
    }

    //MARK:CBCentralManagerDelegate end -
    
    //MARK:- CBPeripheralDelegate start

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard peripheral == monitoredPeripheral else { return }
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        //print("readRSSI \(rssi)dBm")
        updateMonitoredPeripheral(rssi)
        lastReadAt = Date().timeIntervalSince1970

        if activeModeTimer == nil && !passiveMode {
            print("Entering active mode")
            if !scanMode {
                centralMgr.stopScan()
            }
            startActiveModeTimer(peripheral)
        }
    }

    // How long active mode waits for a reading before falling back to passive mode.
    // Allow a few missed polls before giving up, even with a long polling interval.
    var activeModeFallback: Double {
        return max(10, pollInterval * 3)
    }

    func startActiveModeTimer(_ peripheral: CBPeripheral) {
        activeModeTimer?.invalidate()
        activeModeTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true, block: { _ in
            if Date().timeIntervalSince1970 > self.lastReadAt + self.activeModeFallback {
                print("Falling back to passive mode")
                self.centralMgr.cancelPeripheralConnection(peripheral)
                self.activeModeTimer?.invalidate()
                self.activeModeTimer = nil
                self.scanForPeripherals()
            } else if peripheral.state == .connected {
                peripheral.readRSSI()
            } else {
                self.connectMonitoredPeripheral()
            }
        })
        RunLoop.main.add(activeModeTimer!, forMode: .common)
    }

    func setPollInterval(_ interval: Double) {
        pollInterval = interval
        if activeModeTimer != nil, let p = monitoredPeripheral {
            startActiveModeTimer(p)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        if let services = peripheral.services {
            for service in services {
                if service.uuid == DeviceInformation {
                    peripheral.discoverCharacteristics([ManufacturerName, ModelName], for: service)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?)
    {
        if let chars = service.characteristics {
            for chara in chars {
                if chara.uuid == ManufacturerName || chara.uuid == ModelName {
                    peripheral.readValue(for:chara)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?)
    {
        if let value = characteristic.value {
            let str: String? = String(data: value, encoding: .utf8)
            if let s = str {
                if let device = devices[peripheral.identifier] {
                    if characteristic.uuid == ManufacturerName {
                        device.manufacture = s
                        delegate?.updateDevice(device: device)
                    }
                    if characteristic.uuid == ModelName {
                        device.model = s
                        delegate?.updateDevice(device: device)
                    }
                    if device.model != nil && device.model != nil && device.peripheral != monitoredPeripheral {
                        centralMgr.cancelPeripheralConnection(peripheral)
                    }
                }
            }
        }
    }
    
    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        checkProbedName(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didModifyServices invalidatedServices: [CBService])
    {
        peripheral.discoverServices([DeviceInformation])
    }
    //MARK:CBPeripheralDelegate end -

    override init() {
        super.init()
        centralMgr = CBCentralManager(delegate: self, queue: nil)
    }
}
