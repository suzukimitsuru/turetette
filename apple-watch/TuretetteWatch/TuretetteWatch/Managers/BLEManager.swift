import Foundation
import CoreBluetooth
import UserNotifications
import WatchKit
import Combine

/// BLE のスキャン・接続・RSSI 監視・距離推定を管理する。
///
/// ## 距離推定式
/// `distance = 10 ^ ((txPower - RSSI) / (10 * n))`
/// - txPower: -59 dBm（1m地点での実測値）
/// - n: 2.0（自由空間の経路損失指数）
/// - 2m 相当の RSSI 閾値: 約 -65 dBm
///
/// ## バックグラウンド動作
/// - `backgroundBLECheckRequested` 通知を受信 → RSSI 単発チェック
/// - `backgroundBLEAlertReceived` 通知を受信 → 切断状態を評価
/// - 圏外検知かつバックグラウンド → `UNUserNotificationCenter` でローカル通知を発火
///
/// ## watchOS BLE 制限（24時間 5 回）
/// バックグラウンド接続の試行は24時間で5回まで保証される。
/// CMMotionActivityManager による歩行トリガー設計は省電力化のためのもの。
final class BLEManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var discoveredPeripherals: [CBPeripheral] = []
    @Published var connectedPeripheral: CBPeripheral?
    @Published var rssi: Int = 0
    @Published var estimatedDistance: Double = 0.0
    @Published var isConnected: Bool = false
    @Published var isScanning: Bool = false
    @Published var isOutOfRange: Bool = false

    // MARK: - Configuration

    /// 圏外と判定する距離閾値（メートル）
    let distanceThreshold: Double = 2.0

    private let txPower: Double = -59.0       // dBm @ 1m
    private let pathLossExponent: Double = 2.0

    // MARK: - Callbacks

    /// フォアグラウンドで圏外になった時に呼ばれる（ContentView → AlarmManager 連携用）
    var onOutOfRange: (() -> Void)?

    // MARK: - Private

    private var centralManager: CBCentralManager!
    private var rssiTimer: Timer?
    private var peripheralMap: [UUID: CBPeripheral] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// バックグラウンド通知の識別子
    private let outOfRangeNotificationID = "com.turetette.watch.outOfRange"

    // MARK: - Init / Deinit

    override init() {
        super.init()
        // RestoreIdentifierKey: バックグラウンドで OS が BLE スタックを復元する際に使用
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.turetette.watch.central"]
        )
        subscribeBackgroundNotifications()
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

    // MARK: - Background Notification Subscription

    private func subscribeBackgroundNotifications() {
        // Background App Refresh: RSSI 単発チェックを実行する
        NotificationCenter.default
            .publisher(for: .backgroundBLECheckRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.performBackgroundRSSICheck()
            }
            .store(in: &cancellables)

        // BLE アラート/切断: 接続状態を評価してローカル通知を発火する
        NotificationCenter.default
            .publisher(for: .backgroundBLEAlertReceived)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleBackgroundBLEAlert()
            }
            .store(in: &cancellables)
    }

    // MARK: - Background BLE Handlers

    /// Background App Refresh で呼ばれる RSSI 単発チェック
    private func performBackgroundRSSICheck() {
        guard isConnected, let peripheral = connectedPeripheral else {
            // 接続が切れていれば圏外通知を発火
            if isOutOfRange {
                sendOutOfRangeNotification(reason: "接続デバイスが見つかりません")
            }
            return
        }
        peripheral.readRSSI()
        // 結果は `didReadRSSI` デリゲートで受け取り、圏外なら通知する
    }

    /// WKBluetoothAlertBackgroundTask で呼ばれる切断状態の評価
    private func handleBackgroundBLEAlert() {
        if !isConnected {
            sendOutOfRangeNotification(reason: "BLEデバイスの接続が切れました")
        } else if isOutOfRange {
            sendOutOfRangeNotification(reason: "BLEデバイスが離れています（距離: \(String(format: "%.1f", estimatedDistance))m）")
        }
    }

    // MARK: - RSSI Polling (Foreground)

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

    // MARK: - Distance Calculation

    private func calculateDistance(from rssiValue: Int) -> Double {
        guard rssiValue != 0 else { return 0 }
        let ratio = (txPower - Double(rssiValue)) / (10.0 * pathLossExponent)
        return pow(10.0, ratio)
    }

    /// 圏外状態を更新し、状態変化に応じて通知またはコールバックを呼ぶ
    private func updateOutOfRange(distance: Double) {
        let wasOutOfRange = isOutOfRange
        isOutOfRange = distance > distanceThreshold
        guard isOutOfRange && !wasOutOfRange else { return }

        let appState = WKApplication.shared().applicationState
        if appState == .active {
            // フォアグラウンド: ContentView の .onReceive → AlarmManager のルートで処理
            onOutOfRange?()
        } else {
            // バックグラウンド: 直接ローカル通知を発火
            sendOutOfRangeNotification(
                reason: "BLEデバイスが離れました（距離: \(String(format: "%.1f", distance))m）"
            )
        }
    }

    // MARK: - Local Notification

    /// バックグラウンド圏外検知時のローカル通知を発火する
    private func sendOutOfRangeNotification(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ アラーム"
        content.body = reason
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: outOfRangeNotificationID,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[BLEManager] Notification error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            break
        default:
            DispatchQueue.main.async {
                self.isConnected = false
                self.isScanning = false
                self.discoveredPeripherals = []
            }
        }
    }

    /// BLE スタックの State Restoration（バックグラウンドからの復元）
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // 復元された接続済みペリフェラルを再設定する
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                peripheral.delegate = self
                peripheralMap[peripheral.identifier] = peripheral
                if peripheral.state == .connected {
                    DispatchQueue.main.async {
                        self.connectedPeripheral = peripheral
                        self.isConnected = true
                    }
                    startRSSIPolling()
                }
            }
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
        // バックグラウンドで切断された場合はローカル通知を発火
        let appState = WKApplication.shared().applicationState
        if appState != .active {
            sendOutOfRangeNotification(reason: "BLEデバイスの接続が切れました")
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
