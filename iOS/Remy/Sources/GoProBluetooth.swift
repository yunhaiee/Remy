import Foundation
import CoreBluetooth
import Combine
import RemyCore

struct NearbyGoPro: Identifiable {
    let id: UUID
    let name: String
    let signal: Int
}

/// Foreground Bluetooth setup. Wi-Fi credentials remain in memory and never enter diagnostics.
@MainActor final class GoProBluetooth: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published private(set) var status = "Find the HERO12 over Bluetooth"
    @Published private(set) var cameras: [NearbyGoPro] = []
    @Published private(set) var scanning = false
    @Published private(set) var connecting = false
    @Published private(set) var connected = false
    @Published private(set) var wifiAccepted = false
    @Published private(set) var ssid = ""
    @Published private(set) var password = ""
    @Published private(set) var error: String?
    @Published private(set) var events: [String] = []
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var selected: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var notifyReady = false
    private var settingsRequested = false
    private var enableSent = false
    private var wantsScan = false
    private var attempt = UUID()
    private var targetSuffix = ""
    private var autoConnect = false

    private static let controlService = CBUUID(string: "FEA6")
    private static let wifiService = uuid("0001")
    private static let wifiSSID = uuid("0002")
    private static let wifiPassword = uuid("0003")
    private static let command = uuid("0072")
    private static let response = uuid("0073")
    private static func uuid(_ suffix: String) -> CBUUID { CBUUID(string: "B5F9\(suffix)-AA8D-11E3-9046-0002A5D5C51B") }

    func scan(targetSuffix: String, automaticallyConnect: Bool = false) {
        guard !connecting, !connected else { return }
        self.targetSuffix = targetSuffix; autoConnect = automaticallyConnect
        wantsScan = true; error = nil; cameras = []; peripherals = [:]
        if central == nil { central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
        else { scanIfReady() }
    }

    private func scanIfReady() {
        guard wantsScan, let central else { return }
        switch central.state {
        case .poweredOn:
            scanning = true; status = "Searching for GoPro cameras…"
            central.scanForPeripherals(withServices: [Self.controlService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            let id = UUID(); attempt = id
            Task {
                try? await Task.sleep(for: .seconds(20))
                guard attempt == id, scanning else { return }
                central.stopScan(); scanning = false; wantsScan = false
                status = cameras.isEmpty ? "No GoPro found. Keep its Quik App pairing screen open, then retry." : "Select your HERO12 below."
            }
        case .poweredOff: status = "Turn on Bluetooth on the iPhone, then retry."
        case .unauthorized: status = "Allow Bluetooth for Remy in iPhone Settings."
        case .unsupported: status = "Bluetooth LE is unavailable on this device."
        default: status = "Waiting for iPhone Bluetooth…"
        }
    }

    func connect(_ camera: NearbyGoPro) {
        guard let central, let peripheral = peripherals[camera.id] else { return }
        central.stopScan(); scanning = false; wantsScan = false; connecting = true; error = nil
        ssid = ""; password = ""; connected = false; wifiAccepted = false
        characteristics = [:]; notifyReady = false; settingsRequested = false; enableSent = false
        let id = UUID(); attempt = id
        selected = peripheral; peripheral.delegate = self
        status = "Connecting to \(camera.name)… Accept Pair on the iPhone if prompted."
        record("Connecting to the selected GoPro over BLE.")
        central.connect(peripheral)
        Task {
            try? await Task.sleep(for: .seconds(45))
            guard attempt == id, !wifiAccepted else { return }
            fail("Bluetooth setup timed out. Keep the camera in pairing mode and accept any iPhone pairing prompt.")
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func disconnect() {
        attempt = UUID(); wantsScan = false; central?.stopScan(); scanning = false
        if let selected { central?.cancelPeripheralConnection(selected) }
        selected = nil; characteristics = [:]; connecting = false; connected = false
        wifiAccepted = false; ssid = ""; password = ""
        status = "Bluetooth disconnected"
    }

    private func fail(_ message: String) {
        attempt = UUID(); error = message; connecting = false; connected = false; wifiAccepted = false
        status = "Bluetooth setup needs attention"; ssid = ""; password = ""
        let peripheral = selected; selected = nil; characteristics = [:]
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        record(message)
    }
    private func record(_ message: String) {
        events.append(message); if events.count > 25 { events.removeFirst() }
        let report: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()), "status": status,
            "bleSetupComplete": connected, "wifiEnableAcknowledged": wifiAccepted,
            "networkNameRead": !ssid.isEmpty, "passwordRead": !password.isEmpty,
            "error": error as Any? ?? NSNull(), "events": events,
            "note": "Network names, passwords, and peripheral identifiers are excluded."
        ]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("latest-gopro-bluetooth.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) { scanIfReady() }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "GoPro"
        let camera = NearbyGoPro(id: peripheral.identifier, name: name, signal: RSSI.intValue)
        peripherals[camera.id] = peripheral
        if !cameras.contains(where: { $0.id == camera.id }) { cameras.append(camera) }
        if autoConnect, targetSuffix.count == 3, name.hasSuffix(targetSuffix) { connect(camera) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard selected?.identifier == peripheral.identifier else { return }
        status = "Bluetooth connected. Discovering camera setup…"
        record("BLE link established; discovering services.")
        peripheral.discoverServices([Self.controlService, Self.wifiService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard selected?.identifier == peripheral.identifier else { return }
        fail(error?.localizedDescription ?? "Could not connect to this GoPro.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard selected?.identifier == peripheral.identifier else { return }
        connected = false; connecting = false; wifiAccepted = false; password = ""
        status = "GoPro Bluetooth disconnected. Reconnect if Wi-Fi turns off."
        if let error { self.error = error.localizedDescription }
        record("BLE link disconnected.")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard selected?.identifier == peripheral.identifier else { return }
        if let error { fail(error.localizedDescription); return }
        guard let services = peripheral.services, !services.isEmpty else { fail("GoPro services were not found."); return }
        for service in services {
            peripheral.discoverCharacteristics(service.uuid == Self.controlService ? [Self.command, Self.response] : [Self.wifiSSID, Self.wifiPassword], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard selected?.identifier == peripheral.identifier else { return }
        if let error { fail(error.localizedDescription); return }
        for characteristic in service.characteristics ?? [] { characteristics[characteristic.uuid] = characteristic }
        guard !settingsRequested, let response = characteristics[Self.response], let ssid = characteristics[Self.wifiSSID],
              let password = characteristics[Self.wifiPassword], characteristics[Self.command] != nil else { return }
        settingsRequested = true
        peripheral.setNotifyValue(true, for: response)
        peripheral.readValue(for: ssid)
        peripheral.readValue(for: password)
        status = "Reading camera network details. Accept Pair if prompted."
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard selected?.identifier == peripheral.identifier, characteristic.uuid == Self.response else { return }
        if let error { fail(error.localizedDescription); return }
        notifyReady = characteristic.isNotifying
        enableWiFiIfReady()
    }

    private func enableWiFiIfReady() {
        guard !enableSent, notifyReady, !ssid.isEmpty, !password.isEmpty,
              let selected, let command = characteristics[Self.command] else { return }
        enableSent = true
        status = "Enabling the GoPro’s Wi-Fi…"
        selected.writeValue(GoProBLEProtocol.enableWiFi, for: command, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard selected?.identifier == peripheral.identifier else { return }
        if let error { fail(error.localizedDescription) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard selected?.identifier == peripheral.identifier else { return }
        if let error { fail(error.localizedDescription); return }
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.wifiSSID, Self.wifiPassword:
            guard let value = GoProBLEProtocol.credentialText(data) else { fail("The camera returned invalid Wi-Fi details."); return }
            if characteristic.uuid == Self.wifiSSID { ssid = value } else { password = value }
            enableWiFiIfReady()
        case Self.response:
            guard enableSent else { return }
            do {
                guard let accepted = try GoProBLEProtocol.wifiEnableAcknowledgement(data) else { return }
                guard accepted else { fail("The camera rejected the Wi-Fi enable request. Stop recording and retry."); return }
                wifiAccepted = true; connected = true; connecting = false
                status = "GoPro accepted Wi-Fi setup. Join its network below, then start video."
                record("GoPro acknowledged the Wi-Fi enable command. Joining and video are not yet verified.")
            } catch { fail(error.localizedDescription) }
        default: break
        }
    }
}
