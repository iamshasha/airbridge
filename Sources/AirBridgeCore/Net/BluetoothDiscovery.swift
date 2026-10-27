import CoreBluetooth
import Foundation

/// Bluetooth LE presence: advertises our service and reads nearby peers' contact card
/// (id, name, port, IP addresses). Works where multicast/mDNS is blocked, e.g. guest or corporate Wi-Fi.
final class BluetoothDiscovery: NSObject, @unchecked Sendable {
    static let serviceUUID = CBUUID(string: "5A1B0001-6A3F-4E8E-9D2C-A1B2C3D4E5F6")
    static let cardUUID = CBUUID(string: "5A1B0002-6A3F-4E8E-9D2C-A1B2C3D4E5F6")

    struct Card: Codable, Sendable {
        var id: String
        var n: String
        var fp: String
        var pl: String
        var p: UInt16
        var a: [String]
    }

    struct Found: Sendable { var card: Card; var rssi: Int }

    private let queue = DispatchQueue(label: "airbridge.ble")
    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var connecting: [UUID: CBPeripheral] = [:]
    private var lastRead: [UUID: Date] = [:]
    private var rssiByPeripheral: [UUID: Int] = [:]
    private let cardProvider: @Sendable () -> Card
    private let onFound: @Sendable (Found) -> Void
    private(set) var state: CBManagerState = .unknown
    var onStateChange: (@Sendable (CBManagerState) -> Void)?

    init(cardProvider: @escaping @Sendable () -> Card, onFound: @escaping @Sendable (Found) -> Void) {
        self.cardProvider = cardProvider
        self.onFound = onFound
    }

    func start() {
        queue.async {
            self.central = CBCentralManager(delegate: self, queue: self.queue)
            self.peripheralManager = CBPeripheralManager(delegate: self, queue: self.queue)
        }
    }

    func stop() {
        queue.async {
            self.central?.stopScan()
            self.peripheralManager?.stopAdvertising()
            self.peripheralManager?.removeAllServices()
            self.connecting.values.forEach { self.central?.cancelPeripheralConnection($0) }
            self.connecting.removeAll()
            self.central = nil
            self.peripheralManager = nil
        }
    }
}

extension BluetoothDiscovery: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        onStateChange?(central.state)
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        rssiByPeripheral[peripheral.identifier] = RSSI.intValue
        // Re-read a card at most once a minute; the RSSI keeps "nearby" fresh in between.
        if let last = lastRead[peripheral.identifier], Date().timeIntervalSince(last) < 60 { return }
        guard connecting[peripheral.identifier] == nil else { return }
        connecting[peripheral.identifier] = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connecting[peripheral.identifier] = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connecting[peripheral.identifier] = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            return finish(peripheral)
        }
        peripheral.discoverCharacteristics([Self.cardUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == Self.cardUUID }) else { return finish(peripheral) }
        peripheral.readValue(for: ch)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        defer { finish(peripheral) }
        lastRead[peripheral.identifier] = Date()
        guard let data = characteristic.value, let card = try? JSONDecoder().decode(Card.self, from: data) else { return }
        onFound(Found(card: card, rssi: rssiByPeripheral[peripheral.identifier] ?? -100))
    }

    private func finish(_ peripheral: CBPeripheral) {
        central?.cancelPeripheralConnection(peripheral)
        connecting[peripheral.identifier] = nil
    }
}

extension BluetoothDiscovery: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        let ch = CBMutableCharacteristic(type: Self.cardUUID, properties: [.read], value: nil, permissions: [.readable])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [ch]
        peripheral.removeAllServices()
        peripheral.add(service)
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "AirBridge",
        ])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let data = (try? JSONEncoder().encode(cardProvider())) ?? Data()
        guard request.offset <= data.count else {
            return peripheral.respond(to: request, withResult: .invalidOffset)
        }
        request.value = data.subdata(in: request.offset ..< data.count)
        peripheral.respond(to: request, withResult: .success)
    }
}
