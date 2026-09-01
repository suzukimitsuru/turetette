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
///
/// フェーズ C（G0-5）だけは仕組みが違う。`registerForConnectionEvents`（watchOS 6.0+）は
/// 背景 BLE 起床（`WKBluetoothAlertRefreshBackgroundTask`、Series 6 要件）とは**別系統**なので、
/// **要件を満たさない機体でも切断を拾える可能性がある**（設計 §19.5-4）。
/// これを notify 経由の起床と切り分けて測るため、**フェーズ C では notify を購読しない。**
/// 購読したままだと、背景で来たイベントがどちらの経路によるものか判別できなくなる。
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

    /// 購読中のハートビート characteristic。フェーズ切り替えで購読を張り直すために持つ。
    private var heartbeat: CBCharacteristic?

    /// `registerForConnectionEvents` を登録済みか（フェーズ C のみ登録する）。
    private var connectionEventsRegistered = false

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
        heartbeat = nil
        connectionEventsRegistered = false   // 落とさないと再開時にフェーズ C が登録されない
        isConnected = false
        stateText = "停止"
        SpikeLog.shared.add(.note, "SpikeCentral を停止")
    }

    /// フェーズを実際の購読・登録状態に反映する。
    ///
    /// 画面でフェーズを切り替えたときと、Bluetooth が使えるようになったときに呼ぶ。
    /// フェーズ C は「notify を切って `registerForConnectionEvents` だけにする」ことが
    /// 計測の前提なので、切り替えを取りこぼすと結果が濁る。
    func applyPhase() {
        let phase = SpikeLog.shared.phase

        // notify: フェーズ C だけ外す（経路を 1 本に絞って出どころを特定するため）
        if let heartbeat, let peripheral {
            let shouldNotify = (phase != "C")
            if heartbeat.isNotifying != shouldNotify {
                peripheral.setNotifyValue(shouldNotify, for: heartbeat)
                SpikeLog.shared.add(.note, shouldNotify ? "notify を購読" : "notify の購読を解除（フェーズ C）")
            }
        }

        // 接続イベント: フェーズ C でだけ登録する。
        // 常時登録すると、フェーズ A / B で来た背景イベントの出どころが分からなくなる。
        guard let central, central.state == .poweredOn else { return }
        if phase == "C" && !connectionEventsRegistered {
            central.registerForConnectionEvents(options: [
                .serviceUUIDs: [serviceUUID]
            ])
            connectionEventsRegistered = true
            SpikeLog.shared.add(.note, "registerForConnectionEvents を登録（サービス UUID 指定）")
        } else if phase != "C" && connectionEventsRegistered {
            central.registerForConnectionEvents(options: nil)   // nil で登録解除
            connectionEventsRegistered = false
            SpikeLog.shared.add(.note, "registerForConnectionEvents を解除")
        }
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

        if central.state == .poweredOn {
            scanOrReconnect()
            applyPhase()
        }
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

    /// 切断（timestamp 版）。**`timestamp` で「いつ切れたか」が取れる**のがこちらの価値（§19.5-2）。
    ///
    /// 背景起床は切断から数秒遅れるため、旧 API では切断時刻が分からない。
    /// P3 の遡及判定は「切断時刻の前後 60 秒の歩数」を核にするので、この遅延の実測値が要る。
    ///
    /// - Note: このメソッドは SDK ヘッダに可用性注釈が無く、**watchOS 9.0 の
    ///   デプロイメントターゲットのままコンパイルできる**（`@available` を付けると
    ///   「プロトコルが watchOS 9.0 での可用性を要求する」とコンパイルエラーになる）。
    ///   実際に呼ばれるかは OS 側の実装次第なので、旧版も残して**どちらが呼ばれたかを記録する**。
    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime,
                        isReconnecting: Bool,
                        error: Error?) {
        let at = Date(timeIntervalSinceReferenceDate: timestamp)
        let delayMs = Int(Date().timeIntervalSince(at) * 1000)
        handleDisconnect(
            central,
            peripheral,
            detail: "ts版 経過=\(delayMs)ms 再接続中=\(isReconnecting) \(error?.localizedDescription ?? "正常切断")",
            shouldReconnect: !isReconnecting
        )
    }

    /// 切断（旧 API）。watchOS 10 未満、または ts 版が呼ばれない環境向けのフォールバック。
    /// **どちらが呼ばれたかもログに残る**ので、実機での挙動がそのまま結果になる。
    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        handleDisconnect(
            central,
            peripheral,
            detail: "旧版（ts 版は呼ばれていない） \(error?.localizedDescription ?? "正常切断")",
            shouldReconnect: true
        )
    }

    /// 切断時の共通処理。**G0-2 / G0-4 の主眼**: 背景起床したかを appState 付きで残す。
    private func handleDisconnect(_ central: CBCentralManager,
                                  _ peripheral: CBPeripheral,
                                  detail: String,
                                  shouldReconnect: Bool) {
        isConnected = false
        SpikeLog.shared.add(.disconnect, detail)

        // G0-4: この「再接続用の短い枠」でローカル通知を積めるか（§19.4）。
        // 積めなければ方式1 は「再接続を試して黙る」だけになるので、ここが本丸。
        SpikeAlertProbe.shared.tryPostIfBackground(reason: "disconnect")

        // 切断でも背景実行枠を得られたなら、遡り問い合わせを試す（G0-3 の材料が増える）
        SpikeRunner.shared.probeIfBackground(reason: "disconnect")

        // CoreBluetooth はタイムアウト無しで待つので、そのまま再接続を要求しておく。
        // ts 版が `isReconnecting = true` を返したときは OS が張り直すので二重に要求しない。
        if shouldReconnect {
            central.connect(peripheral, options: nil)
        }
    }

    /// `registerForConnectionEvents` の結果（G0-5）。
    ///
    /// **これが `appState = background` で記録されれば、背景 BLE 起床の要件（Series 6 以降）を
    /// 満たさない機体でも切断を検知できる**ことになり、保留中の G0-1 / G0-2 を迂回できる。
    func centralManager(_ central: CBCentralManager,
                        connectionEventDidOccur event: CBConnectionEvent,
                        for peripheral: CBPeripheral) {
        let text: String
        switch event {
        case .peerDisconnected: text = "切断"
        case .peerConnected:    text = "接続"
        @unknown default:       text = "不明(\(event.rawValue))"
        }
        SpikeLog.shared.add(.connEvent, "\(text) id=\(peripheral.identifier.uuidString.suffix(8))")

        // 接続イベント単独で通知を出せるかも、ついでに測る（G0-4 と同じ問い）
        if event == .peerDisconnected {
            SpikeAlertProbe.shared.tryPostIfBackground(reason: "connectionEvent")
        }
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
        heartbeat = ch

        // これが背景起床のトリガになる（WWDC22）。
        // ただしフェーズ C は接続イベント単独の効果を測る回なので購読しない（§19.5-4）。
        if SpikeLog.shared.phase == "C" {
            SpikeLog.shared.add(.note, "フェーズ C のため notify は購読しない")
        } else {
            peripheral.setNotifyValue(true, for: ch)
            SpikeLog.shared.add(.note, "notify を購読")
        }
        // ここで applyPhase() は呼ばない。`isNotifying` はまだ更新されておらず、
        // setNotifyValue とログが二重になる。接続イベントの登録は poweredOn 時に済んでいる。
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
