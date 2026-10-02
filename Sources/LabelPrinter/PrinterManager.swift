import CoreBluetooth
import Foundation

/// Finds the Y813BT printer over BLE, keeps a connection open, and sends raw TSPL bytes.
/// UUIDs and the write flow are documented in y813bt_ble_notes.md.
final class PrinterManager: NSObject, ObservableObject {
    enum State: Equatable {
        case starting
        case bluetoothOff
        case searching
        case notFound
        case connected(name: String)
        case printing(name: String, progress: Double)
    }

    @Published private(set) var state: State = .starting
    @Published private(set) var lastError: String?
    @Published private(set) var lastTransferSummary: String?

    private let namePrefix = "Y813BT"
    private let serviceUUID = CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
    private let writeUUID = CBUUID(string: "49535343-ACA3-481C-91EC-D85E28A60318")
    /// Supports write-without-response, so chunks don't each wait for an ack. Used when present.
    private let fastWriteUUID = CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")
    private let searchTimeout: TimeInterval = 8
    /// Set to false to always use acknowledged writes on ACA3 (slower, but the original proven path).
    private let preferFastWrite = true

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var fastWriteCharacteristic: CBCharacteristic?
    private var timeoutWork: DispatchWorkItem?

    private var chunks: [Data] = []
    private var chunkIndex = 0
    private var completion: ((Error?) -> Void)?
    private var usingFastWrite = false
    private var transferStart = Date()
    private var transferBytes = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var isPrinting: Bool {
        if case .printing = state { return true }
        return false
    }

    // MARK: - Discovery

    func checkForPrinter() {
        guard central.state == .poweredOn else {
            state = .bluetoothOff
            return
        }
        guard !isPrinting else { return }

        resetConnection()
        lastError = nil
        state = .searching

        let timeout = DispatchWorkItem { [weak self] in self?.searchTimedOut() }
        timeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + searchTimeout, execute: timeout)

        // The printer may already be connected at the system level; skip the scan if so.
        if let existing = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            connect(existing)
            return
        }

        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    private func connect(_ peripheral: CBPeripheral) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    private func searchTimedOut() {
        guard state == .searching else { return }
        resetConnection()
        state = .notFound
    }

    private func resetConnection() {
        timeoutWork?.cancel()
        timeoutWork = nil
        central.stopScan()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        writeCharacteristic = nil
        fastWriteCharacteristic = nil
    }

    private var printerName: String {
        peripheral?.name ?? "printer"
    }

    // MARK: - Printing

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        guard isConnected, let peripheral, writeCharacteristic != nil else {
            completion(PrinterError.notConnected)
            return
        }

        usingFastWrite = preferFastWrite && fastWriteCharacteristic != nil
        let maxLen = usingFastWrite
            ? max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
            : max(20, min(180, peripheral.maximumWriteValueLength(for: .withResponse)))
        chunks = stride(from: 0, to: data.count, by: maxLen).map { offset in
            data.subdata(in: offset..<min(offset + maxLen, data.count))
        }
        chunkIndex = 0
        lastError = nil
        self.completion = completion
        transferStart = Date()
        transferBytes = data.count
        state = .printing(name: printerName, progress: 0)
        if usingFastWrite { sendFastChunks() } else { sendNextChunk() }
    }

    /// Writes without response as fast as CoreBluetooth's flow control allows; resumes from
    /// peripheralIsReady(toSendWriteWithoutResponse:).
    private func sendFastChunks() {
        guard let peripheral, let fastWriteCharacteristic else { return }

        while chunkIndex < chunks.count && peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(chunks[chunkIndex], for: fastWriteCharacteristic, type: .withoutResponse)
            chunkIndex += 1
        }

        if chunkIndex >= chunks.count {
            finishPrint(error: nil)
        } else {
            state = .printing(name: printerName, progress: Double(chunkIndex) / Double(chunks.count))
        }
    }

    private func sendNextChunk() {
        guard let peripheral, let writeCharacteristic else { return }

        if chunkIndex >= chunks.count {
            finishPrint(error: nil)
            return
        }

        state = .printing(name: printerName, progress: Double(chunkIndex) / Double(chunks.count))
        let chunk = chunks[chunkIndex]
        chunkIndex += 1
        peripheral.writeValue(chunk, for: writeCharacteristic, type: .withResponse)
    }

    private func finishPrint(error: Error?) {
        chunks = []
        if let error {
            lastError = error.localizedDescription
        } else {
            let seconds = Date().timeIntervalSince(transferStart)
            lastTransferSummary = String(
                format: "Sent %.1f KB in %.1f s (%@)",
                Double(transferBytes) / 1024, seconds, usingFastWrite ? "fast write" : "acked write"
            )
            print(lastTransferSummary!)
        }
        if peripheral?.state == .connected {
            state = .connected(name: printerName)
        }
        let completion = self.completion
        self.completion = nil
        completion?(error)
    }
}

enum PrinterError: LocalizedError {
    case notConnected
    case disconnected

    var errorDescription: String? {
        switch self {
        case .notConnected: "Printer is not connected"
        case .disconnected: "Printer disconnected during printing"
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension PrinterManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            checkForPrinter()
        } else {
            resetConnection()
            state = .bluetoothOff
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? localName ?? ""
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []

        guard name.hasPrefix(namePrefix) || advertisedServices.contains(serviceUUID) else { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lastError = "Connect failed: \(error?.localizedDescription ?? "unknown error")"
        resetConnection()
        state = .notFound
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral == self.peripheral else { return }
        if isPrinting {
            finishPrint(error: PrinterError.disconnected)
        }
        self.peripheral = nil
        writeCharacteristic = nil
        fastWriteCharacteristic = nil
        state = .notFound
    }
}

// MARK: - CBPeripheralDelegate

extension PrinterManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            lastError = "Printer service not found"
            resetConnection()
            state = .notFound
            return
        }
        peripheral.discoverCharacteristics([writeUUID, fastWriteUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == writeUUID }) else {
            lastError = "Write characteristic not found"
            resetConnection()
            state = .notFound
            return
        }

        writeCharacteristic = characteristic
        fastWriteCharacteristic = service.characteristics?.first {
            $0.uuid == fastWriteUUID && $0.properties.contains(.writeWithoutResponse)
        }
        if characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
        }

        timeoutWork?.cancel()
        timeoutWork = nil
        state = .connected(name: printerName)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isPrinting, !usingFastWrite else { return }
        if let error {
            finishPrint(error: error)
            return
        }
        sendNextChunk()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard isPrinting, usingFastWrite else { return }
        sendFastChunks()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let value = characteristic.value, !value.isEmpty {
            let hex = value.map { String(format: "%02X", $0) }.joined()
            print("Notify \(characteristic.uuid): \(hex)")
        }
    }
}
