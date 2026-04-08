import Foundation
import CoreBluetooth
import Combine

/// Manages BLE scanning, connection, RSSI monitoring, and distance estimation.
///
/// Distance formula: distance = 10 ^ ((txPower - RSSI) / (10 * n))
/// txPower = -59 dBm (measured at 1 m), n = 2.0 (free-space path-loss exponent)
/// At 2 m, the expected RSSI threshold is approximately -65 dBm.
final class BLEManager: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var discoveredPeripherals: [CBPeripheral] = []
    @Published var connectedPeripheral: CBPeripheral?
    @Published var rssi: Int = 0
    @Published var estimatedDistance: Double = 0.0
    @Published var isConnected: Bool = false
    @Published var isScanning: Bool = false
    @Published var isOutOfRange: Bool = false

    // MARK: - Configuration

    let distanceThreshold: Double = 2.0  // metres
    private let txPower: Double = -59.0  // dBm at 1 m
    private let pathLossExponent: Double = 2.0

    // MARK: - Callbacks / publishers

    /// Called on the main queue whenever the device transitions out of range.
    var onOutOfRange: (() -> Void)?

    // MARK: - Private

    private var centralManager: CBCentralManager!
    private var rssiTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Keep a map so we can find peripherals by identifier.
    private var peripheralMap: [UUID: CBPeripheral] = [:]

    // MARK: - Init

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    deinit {
        stopRSSIPolling()
        centralManager.stopScan()
    }

    // MARK: - Public API

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        discoveredPeripherals = []
        peripheralMap = [:]
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        DispatchQueue.main.async { self.isScanning = true }
    }

    func stopScanning() {
        centralManager.stopScan()
        DispatchQueue.main.async { self.isScanning = false }
    }

    func connect(to peripheral: CBPeripheral) {
        stopScanning()
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        stopRSSIPolling()
        centralManager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - RSSI polling

    private func startRSSIPolling() {
        stopRSSIPolling()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.connectedPeripheral?.readRSSI()
        }
    }

    private func stopRSSIPolling() {
        rssiTimer?.invalidate()
        rssiTimer = nil
    }

    // MARK: - Distance calculation

    private func calculateDistance(from rssiValue: Int) -> Double {
        guard rssiValue != 0 else { return 0 }
        let ratio = (txPower - Double(rssiValue)) / (10.0 * pathLossExponent)
        return pow(10.0, ratio)
    }

    private func updateOutOfRange(distance: Double) {
        let wasOutOfRange = isOutOfRange
        isOutOfRange = distance > distanceThreshold
        if isOutOfRange && !wasOutOfRange {
            onOutOfRange?()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Ready — do nothing until user requests scan.
            break
        case .poweredOff, .resetting, .unauthorized, .unsupported, .unknown:
            DispatchQueue.main.async {
                self.isConnected = false
                self.isScanning = false
                self.discoveredPeripherals = []
            }
        @unknown default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        guard peripheralMap[id] == nil else { return }
        peripheralMap[id] = peripheral
        DispatchQueue.main.async {
            self.discoveredPeripherals.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        DispatchQueue.main.async {
            self.connectedPeripheral = peripheral
            self.isConnected = true
        }
        startRSSIPolling()
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectedPeripheral = nil
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        stopRSSIPolling()
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectedPeripheral = nil
            self.rssi = 0
            self.estimatedDistance = 0
            self.isOutOfRange = false
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let rssiValue = RSSI.intValue
        let distance = calculateDistance(from: rssiValue)
        DispatchQueue.main.async {
            self.rssi = rssiValue
            self.estimatedDistance = distance
            self.updateOutOfRange(distance: distance)
        }
    }
}
