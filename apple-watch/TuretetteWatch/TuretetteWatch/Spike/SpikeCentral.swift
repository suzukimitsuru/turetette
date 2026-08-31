import Foundation
import CoreBluetooth
import Combine

/// G0-1 / G0-2 の計測。
///
/// ペリフェラル（`spike/peripheral-sim`）に接続し、ハートビート characteristic を
/// notify 購読したまま放置する。バックグラウンドで値更新が届けば、
/// **watchOS が本当にアプリを起こしている**ことの証拠になる。
///
/// 背景予算（5 回/24h）の警告と超過は NSNotification ではなく
/// **`didUpdateValueFor` の `error` として届く**（WWDC22）。ここではその文字列を見て判定する。
final class SpikeCentral: NSObject, ObservableObject {

    static let shared = SpikeCentral()

    // MARK: 公開状態（画面表示用）

    @Published private(set) var stateText: String = "未初期化"
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastSeq: UInt32 = 0
    @Published private(set) var lastLatencyMs: Int = 0

    // MARK: 内部

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    private let serviceUUID = CBUUID(string: SpikeConfig.serviceUUIDString)
    private let heartbeatUUID = CBUUID(string: SpikeConfig.heartbeatUUIDString)

    private let lastPeripheralKey = "spike.g0.lastPeripheralUUID"
    private let previousSeqKey = "spike.g0.previousSeq"

    private override init() { super.init() }

    // MARK: 開始 / 停止

    /// 計測を開始する。状態復元を有効にするため、起動のたびに同じ識別子で作り直す。
    func start() {
        guard central == nil else { return }
        SpikeLog.shared.add(.note, "SpikeCentral を開始")
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: SpikeConfig.restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    func stop() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        central = nil
        peripheral = nil
        isConnected = false
        stateText = "停止"
        SpikeLog.shared.add(.note, "SpikeCentral を停止")
    }

    /// フェーズ B（切断のみで予算を消費させる）で使う、手動での切断。
    func forceDisconnect() {
        guard let p = peripheral else { return }
        SpikeLog.shared.add(.note, "手動で切断を要求")
        central?.cancelPeripheralConnection(p)
    }

    // MARK: 接続の維持

    private func scanOrReconnect() {
        guard let central, central.state == .poweredOn else { return }

        // 背景スキャンはサービス UUID の明示が必須（設計 §9-3）。ここでも同じ形にしておく。
        if let idString = UserDefaults.standard.string(forKey: lastPeripheralKey),
           let uuid = UUID(uuidString: idString),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            peripheral = known
            known.delegate = self
            SpikeLog.shared.add(.note, "既知ペリフェラルへ再接続を試行")
            central.connect(known, options: nil)
            return
        }

        SpikeLog.shared.add(.note, "スキャン開始（サービス指定あり）")
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }
}

// MARK: - CBCentralManagerDelegate

extension SpikeCentral: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let text: String
        switch central.state {
        case .poweredOn:   text = "利用可能"
        case .poweredOff:  text = "Bluetooth オフ"
        case .unauthorized: text = "未許可"
        case .unsupported: text = "非対応"
        case .resetting:   text = "リセット中"
        case .unknown:     text = "不明"
        @unknown default:  text = "不明"
        }
        stateText = text
        SpikeLog.shared.add(.bleState, text)

        if central.state == .poweredOn { scanOrReconnect() }
    }

    /// OS がアプリを起こし直したときに呼ばれる。**これが記録されれば G0-1 は成立している。**
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        SpikeLog.shared.add(.restore, "復元されたペリフェラル \(restored.count) 件")

        if let p = restored.first {
            peripheral = p
            p.delegate = self
            isConnected = (p.state == .connected)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastPeripheralKey)
        SpikeLog.shared.add(.note, "発見 RSSI \(RSSI) → 接続要求")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        SpikeLog.shared.add(.connect, "接続")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        SpikeLog.shared.add(.note, "接続失敗 \(error?.localizedDescription ?? "-")")
        scanOrReconnect()
    }

    /// 切断。**G0-2 の主眼**: これで背景起床したかどうかを appState 付きで残す。
    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        isConnected = false
        SpikeLog.shared.add(.disconnect, error?.localizedDescription ?? "正常切断")

        // 切断でも背景実行枠を得られたなら、遡り問い合わせを試す（G0-3 の材料が増える）
        SpikeRunner.shared.probeIfBackground(reason: "disconnect")

        // CoreBluetooth はタイムアウト無しで待つので、そのまま再接続を要求しておく
        central.connect(peripheral, options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension SpikeCentral: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            SpikeLog.shared.add(.note, "対象サービスが見つからない")
            return
        }
        peripheral.discoverCharacteristics([heartbeatUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == heartbeatUUID }) else {
            SpikeLog.shared.add(.note, "ハートビート characteristic が見つからない")
            return
        }
        // これが背景起床のトリガになる（WWDC22）
        peripheral.setNotifyValue(true, for: ch)
        SpikeLog.shared.add(.note, "notify を購読")
    }

    /// 値更新。**背景予算の警告・超過はここの `error` に載って届く**（WWDC22）。
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {

        if let error {
            let text = String(describing: error)
            if text.contains("LeGattExceededBackgroundNotificationLimit") {
                SpikeLog.shared.add(.budgetExceeded, text)
                return
            }
            if text.contains("LeGattNearBackgroundNotificationLimit") {
                SpikeLog.shared.add(.budgetNear, text)
                return
            }
            SpikeLog.shared.add(.note, "値更新エラー \(text)")
            return
        }

        guard let data = characteristic.value, data.count >= 12 else {
            SpikeLog.shared.add(.notify, "ペイロード不正")
            return
        }

        // ペリフェラル側の書式: UInt32 seq (LE) + UInt64 送信時刻 ms (LE)
        let seq = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }.littleEndian
        let sentMs = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }.littleEndian
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let latency = Int(Int64(nowMs) - Int64(sentMs))

        // 連番の飛びは「その間に送られた notify が届かなかった」＝起床しなかった回数を表す。
        // G0-1 の核心の数字なので必ず残す。
        let previous = UInt32(UserDefaults.standard.integer(forKey: previousSeqKey))
        let missed = (previous > 0 && seq > previous + 1) ? Int(seq - previous - 1) : 0
        UserDefaults.standard.set(Int(seq), forKey: previousSeqKey)

        lastSeq = seq
        lastLatencyMs = latency

        let gapText = missed > 0 ? " 取りこぼし=\(missed)" : ""
        SpikeLog.shared.add(.notify, "seq=\(seq) 遅延=\(latency)ms\(gapText)")

        // 背景で起きているなら、その実行枠で遡り問い合わせが返るかを測る（G0-3）
        SpikeRunner.shared.probeIfBackground(reason: "notify seq=\(seq)")
    }
}
