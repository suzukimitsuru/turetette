import Foundation
import CoreBluetooth

// G0 スパイク用のペリフェラル役。
// Apple Watch を起こす相手として、サービスを広告しハートビートを notify する。
// 使い捨てのため、エラー処理は最小限に留めている。

let serviceUUID   = CBUUID(string: "E7A1B2C0-1D3E-4F5A-8B6C-9D0E1F2A3B4C")
let heartbeatUUID = CBUUID(string: "E7A1B2C1-1D3E-4F5A-8B6C-9D0E1F2A3B4C")

func log(_ message: String) {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss"
    print("[\(df.string(from: Date()))] \(message)")
}

final class Sim: NSObject, CBPeripheralManagerDelegate {

    private var manager: CBPeripheralManager!
    private var heartbeat: CBMutableCharacteristic!
    private var timer: DispatchSourceTimer?

    private var seq: UInt32 = 0
    private var sent = 0
    private var dropped = 0          // 送信バッファが詰まって送れなかった数
    private var subscribers = 0
    private(set) var interval: TimeInterval = 300   // 既定 5 分

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    // MARK: 状態

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            log("Bluetooth 利用可能。サービスを公開します")
            publish()
        case .unauthorized:
            log("Bluetooth が未許可です。システム設定 → プライバシーとセキュリティ → Bluetooth でターミナルを許可してください")
        case .poweredOff:
            log("Bluetooth がオフです")
        default:
            log("状態: \(peripheral.state.rawValue)")
        }
    }

    private func publish() {
        // notify を出せる読み取り専用の characteristic。これが起床トリガになる。
        heartbeat = CBMutableCharacteristic(
            type: heartbeatUUID,
            properties: [.notify, .read],
            value: nil,
            permissions: [.readable]
        )
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [heartbeat]
        manager.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService,
                           error: Error?) {
        if let error {
            log("サービス追加に失敗: \(error.localizedDescription)")
            return
        }
        // 背景の Watch がサービス指定でスキャンできるよう、UUID を広告に載せる
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: "TuretetteSpike"
        ])
        log("広告開始。Watch 側で計測を始めてください")
        startTimer()
    }

    // MARK: 購読

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        subscribers += 1
        log("購読されました（購読者 \(subscribers)）— これ以降の notify が起床トリガになります")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers = max(0, subscribers - 1)
        log("購読が外れました（購読者 \(subscribers)）")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        request.value = makePayload(advance: false)
        manager.respond(to: request, withResult: .success)
        log("read に応答")
    }

    // MARK: 送信

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.notifyOnce(auto: true) }
        t.resume()
        timer = t
        log("送信間隔を \(Int(interval)) 秒に設定")
    }

    private func makePayload(advance: Bool) -> Data {
        if advance { seq &+= 1 }
        var data = Data()
        var s = seq.littleEndian
        var ms = UInt64(Date().timeIntervalSince1970 * 1000).littleEndian
        withUnsafeBytes(of: &s) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &ms) { data.append(contentsOf: $0) }
        return data
    }

    func notifyOnce(auto: Bool) {
        guard manager?.state == .poweredOn, heartbeat != nil else { return }
        let payload = makePayload(advance: true)
        let ok = manager.updateValue(payload, for: heartbeat, onSubscribedCentrals: nil)
        if ok {
            sent += 1
            log("notify 送信 seq=\(seq)\(auto ? "" : "（手動）")")
        } else {
            // false は「送信キューが詰まった」。空いたら didUpdateSubscribers... ではなく
            // peripheralManagerIsReady で通知されるが、スパイクでは数だけ数えておく。
            dropped += 1
            log("notify 送信できず seq=\(seq)（キュー待ち。累計 \(dropped)）")
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        log("送信キューが空きました")
    }

    // MARK: 対話コマンド

    /// サービスを外して戻すことで接続を切る。フェーズ B（切断で予算を消費させる）用。
    func forceDisconnect() {
        guard manager?.state == .poweredOn else { return }
        log("切断します（サービスを外して 2 秒後に戻します）")
        manager.stopAdvertising()
        manager.removeAllServices()
        heartbeat = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.publish()
        }
    }

    func setInterval(_ seconds: TimeInterval) {
        interval = seconds
        startTimer()
    }

    func status() {
        log("状態: 購読者=\(subscribers) 送信=\(sent) 送信失敗=\(dropped) 連番=\(seq) 間隔=\(Int(interval))秒")
        log("Watch 側の受信数と突き合わせてください。差が「起床しなかった回数」です")
    }
}

// MARK: - 起動

let sim = Sim()
sim.start()

print("""

  PeripheralSim — G0 スパイク用ペリフェラル

  n  notify を即時 1 回送る
  d  接続を切る（フェーズ B 用）
  i  送信間隔を変更する
  s  送信状況を表示
  q  終了

""")

// 標準入力を別スレッドで読み、メインは RunLoop に渡す（CoreBluetooth に必要）
Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        let cmd = line.trimmingCharacters(in: .whitespaces).lowercased()
        DispatchQueue.main.async {
            switch cmd {
            case "n": sim.notifyOnce(auto: false)
            case "d": sim.forceDisconnect()
            case "s": sim.status()
            case "i":
                print("秒数を入力してください（例 300）: ", terminator: "")
                // 入力待ちは呼び出し側スレッドで行えないため、次行を読む役を分離する
                DispatchQueue.global().async {
                    if let v = readLine(strippingNewline: true), let n = TimeInterval(v), n >= 5 {
                        DispatchQueue.main.async { sim.setInterval(n) }
                    } else {
                        log("5 秒以上の数値を入力してください")
                    }
                }
            case "q":
                log("終了します")
                exit(0)
            case "":
                break
            default:
                log("未知のコマンド: \(cmd)")
            }
        }
    }
}

RunLoop.main.run()
