import Foundation
import UserNotifications
import WatchKit

/// G0-4 の計測 — 「切断起床で貰える短い枠でローカル通知を積めるか」。
///
/// WWDC22 の説明では、レンジ外による切断で貰える背景実行は
/// **「`connectPeripheral` を呼んで再接続を試みるための短い枠」**と位置づけられており、
/// notify による「時間に敏感な通知を出すための枠」とは別物に読める（設計 §19.4）。
/// **そこでローカル通知を積めなければ、方式1 は「再接続を試して黙る」だけになる。**
/// ここが方式1 の成否を分けるので、実測して白黒つける。
///
/// 測るのは 2 段階。
/// 1. `add(_:)` の完了ハンドラが**枠の中で**成功を返すか（= 積めたか）
/// 2. それが**実際に配信されたか**（次の起床/前面化で `getDeliveredNotifications` を突き合わせる）
///
/// 1 が成功しても 2 が来なければ「登録はできるが配信されない」ということになり、
/// 結論は変わる。両方残さないと判断できない。
final class SpikeAlertProbe {

    static let shared = SpikeAlertProbe()

    /// 配信確認待ちの通知（識別子 → 登録時刻）。背景で終了しても残す必要がある。
    private let pendingKey = "spike.g0.alertPending"

    /// 配信確認を諦める時間。これを過ぎたものは「配信されなかった」として捨てる。
    private let deliveryGrace: TimeInterval = 10 * 60

    private init() {}

    // MARK: 準備

    /// スパイクは本体の `AppDelegate` を通らない経路でも通知を出すため、自分で許可を取る。
    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    SpikeLog.shared.add(.note, "通知許可エラー \(error.localizedDescription)")
                } else {
                    SpikeLog.shared.add(.note, "通知許可 granted=\(granted)")
                }
            }
    }

    // MARK: 計測本体

    /// 背景にいるときだけ、ローカル通知の登録を試みる。
    ///
    /// 前面での成功は当たり前なので測る意味がない。**背景の枠で通るか**だけが問いである。
    /// - Parameter reason: ログに残す発火理由（`disconnect` など）
    func tryPostIfBackground(reason: String) {
        guard SpikeConfig.enabled else { return }
        guard WKApplication.shared().applicationState != .active else { return }

        let id = "spike.alert.\(UUID().uuidString)"
        let startedAt = Date()
        SpikeLog.shared.add(.alertTry, "理由=\(reason)")

        let content = UNMutableNotificationContent()
        content.title = "G0-4 計測"
        content.body = "切断起床の枠から登録した通知（\(reason)）"
        content.interruptionLevel = .timeSensitive
        content.sound = .default

        // 1 秒後。`UNTimeIntervalNotificationTrigger` は 0 を受け付けないため最小値を使う。
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        rememberPending(id: id, at: startedAt)

        UNUserNotificationCenter.current().add(request) { error in
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            if let error {
                SpikeLog.shared.add(.alertFail, "\(elapsed)ms \(error.localizedDescription)")
                self.forgetPending(id: id)
            } else {
                SpikeLog.shared.add(.alertOK, "登録成功 \(elapsed)ms")
            }
        }
    }

    /// 前回までに登録した通知が**実際に配信されたか**を突き合わせる。
    ///
    /// 起床のたび、および前面化のたびに呼ぶ。配信済みなら記録して通知センターから消す
    /// （放置すると計測用の通知が溜まって邪魔になる）。
    func reapDelivered() {
        guard SpikeConfig.enabled else { return }

        let pending = loadPending()
        guard !pending.isEmpty else { return }

        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let deliveredIDs = Set(delivered.map { $0.request.identifier })
            var remaining: [String: Date] = [:]
            var confirmed: [String] = []

            for (id, at) in pending {
                if deliveredIDs.contains(id) {
                    let lag = Int(Date().timeIntervalSince(at) * 1000)
                    SpikeLog.shared.add(.alertDelivered, "登録から \(lag)ms 後に確認")
                    confirmed.append(id)
                } else if Date().timeIntervalSince(at) > self.deliveryGrace {
                    // 猶予切れ。登録は成功したのに配信されなかった、という重要な結果。
                    SpikeLog.shared.add(.note, "通知が配信されないまま猶予切れ id=\(id.suffix(8))")
                } else {
                    remaining[id] = at
                }
            }

            self.savePending(remaining)
            if !confirmed.isEmpty {
                UNUserNotificationCenter.current()
                    .removeDeliveredNotifications(withIdentifiers: confirmed)
            }
        }
    }

    // MARK: 配信確認待ちの永続化

    private func rememberPending(id: String, at: Date) {
        var all = loadPending()
        all[id] = at
        savePending(all)
    }

    private func forgetPending(id: String) {
        var all = loadPending()
        all.removeValue(forKey: id)
        savePending(all)
    }

    private func loadPending() -> [String: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Double] else {
            return [:]
        }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func savePending(_ all: [String: Date]) {
        let raw = all.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: pendingKey)
    }
}
