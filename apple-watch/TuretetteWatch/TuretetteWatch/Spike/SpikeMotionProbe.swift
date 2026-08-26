import Foundation
import CoreMotion

/// G0-3 の計測。
///
/// 設計 §14.4 は「遡り問い合わせは記録済みデータの読み出しなので、GPS と違って
/// 背景起床の短い実行枠の中で返る」と仮定している。**その仮定を実測で確かめる。**
///
/// 起きたその場で `queryPedometerData` と `queryActivityStarting` を投げ、
/// 所要時間を測る。返る前にアプリがサスペンドされた場合はコールバックが来ないので、
/// 「開始したが完了していない probe」を永続化しておき、次の起床時に取りこぼしとして記録する。
final class SpikeMotionProbe {

    static let shared = SpikeMotionProbe()

    private let pedometer = CMPedometer()
    private let activity = CMMotionActivityManager()
    private let pendingKey = "spike.g0.pendingProbes"
    private let queue = DispatchQueue(label: "com.turetette.spike.probe")

    /// 活動履歴のコールバック先。**メインキューにしてはいけない。**
    /// `run()` は完了を待って block するため、メインに返すと待ち合わせと衝突して固まる。
    private let callbackQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.turetette.spike.probe.callback"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private init() {}

    // MARK: 可用性

    var availabilityText: String {
        var parts: [String] = []
        parts.append("歩数 " + (CMPedometer.isStepCountingAvailable() ? "可" : "不可"))
        parts.append("距離 " + (CMPedometer.isDistanceAvailable() ? "可" : "不可"))
        parts.append("階数 " + (CMPedometer.isFloorCountingAvailable() ? "可" : "不可"))
        parts.append("活動 " + (CMMotionActivityManager.isActivityAvailable() ? "可" : "不可"))
        let auth: String
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized:    auth = "許可"
        case .denied:        auth = "拒否"
        case .restricted:    auth = "制限"
        case .notDetermined: auth = "未決定"
        @unknown default:    auth = "不明"
        }
        parts.append("権限 " + auth)
        return parts.joined(separator: " / ")
    }

    // MARK: 前回の取りこぼしを回収

    /// 起床のたびに最初に呼ぶ。前回の起床で返らなかった probe を記録する。
    func reapLostProbes() {
        let pending = loadPending()
        guard !pending.isEmpty else { return }
        for (id, info) in pending {
            SpikeLog.shared.add(.probeLost, "id=\(id) \(info) — 実行枠内に返らなかった")
        }
        savePending([:])
    }

    // MARK: 本体

    /// 遡り問い合わせを 1 回実行し、所要時間を測る。
    ///
    /// - Important: 完了を待って block するため、**メインスレッドから呼んではいけない。**
    ///   呼び出し側（`SpikeRunner`）が専用キューへ逃がしている。
    /// - Parameter completion: 両方の問い合わせが返った（またはタイムアウトした）時点で呼ばれる。
    func run(reason: String, completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let id = String(UUID().uuidString.prefix(8))
        let now = Date()
        let from = now.addingTimeInterval(-SpikeConfig.lookbackWindow)
        // 直近 30 秒は書き込み遅延で欠けることがあるため、終端を手前に置く（設計 §14.8-3）
        let to = now.addingTimeInterval(-30)

        addPending(id: id, info: reason)
        SpikeLog.shared.add(.probeStart, "id=\(id) 理由=\(reason)")

        guard to > from else {
            SpikeLog.shared.add(.probeEnd, "id=\(id) 窓が狭すぎるため中止 0ms")
            removePending(id: id)
            completion()
            return
        }

        let started = Date()
        let group = DispatchGroup()
        var pedoText = "pedometer: 未取得"
        var actText = "activity: 未取得"
        var pedoMs = -1
        var actMs = -1

        group.enter()
        pedometer.queryPedometerData(from: from, to: to) { data, error in
            pedoMs = Int(Date().timeIntervalSince(started) * 1000)
            if let error {
                pedoText = "pedometer: エラー \(error.localizedDescription)"
            } else if let data {
                let steps = data.numberOfSteps.intValue
                let dist = data.distance?.doubleValue ?? -1
                let up = data.floorsAscended?.doubleValue ?? 0
                let down = data.floorsDescended?.doubleValue ?? 0
                pedoText = String(format: "pedometer: %d歩 %.1fm 階+%.0f/-%.0f", steps, dist, up, down)
            }
            group.leave()
        }

        group.enter()
        activity.queryActivityStarting(from: from, to: to, to: callbackQueue) { acts, error in
            actMs = Int(Date().timeIntervalSince(started) * 1000)
            if let error {
                actText = "activity: エラー \(error.localizedDescription)"
            } else {
                let segments = acts ?? []
                let moving = segments.filter {
                    ($0.walking || $0.running || $0.cycling || $0.automotive) && $0.confidence != .low
                }
                actText = "activity: \(segments.count)区間 うち移動\(moving.count)"
            }
            group.leave()
        }

        // タイムアウト付きで待つ。返らなければ「枠内に返らなかった」側に倒す。
        let timedOut = group.wait(timeout: .now() + SpikeConfig.probeTimeout) == .timedOut
        let total = Int(Date().timeIntervalSince(started) * 1000)

        if timedOut {
            SpikeLog.shared.add(.probeLost,
                "id=\(id) \(SpikeConfig.probeTimeout)秒で打ち切り pedo=\(pedoMs)ms act=\(actMs)ms")
        } else {
            removePending(id: id)
            SpikeLog.shared.add(.probeEnd,
                "id=\(id) 合計\(total)ms (pedo=\(pedoMs)ms act=\(actMs)ms) \(pedoText) / \(actText)")
        }
        completion()
    }

    // MARK: 未完了 probe の永続化

    private func loadPending() -> [String: String] {
        queue.sync {
            UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: String] ?? [:]
        }
    }

    private func savePending(_ dict: [String: String]) {
        queue.sync { UserDefaults.standard.set(dict, forKey: pendingKey) }
    }

    private func addPending(id: String, info: String) {
        var d = loadPending()
        d[id] = info
        savePending(d)
    }

    private func removePending(id: String) {
        var d = loadPending()
        d.removeValue(forKey: id)
        savePending(d)
    }
}
