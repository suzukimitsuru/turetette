import Foundation
import WatchKit

/// G0 実機スパイク — 使い捨ての計測用ログ。
///
/// 計測対象がバックグラウンド起床なので、**アプリが終了しても残る**必要がある。
/// そのため書き込みは即時・同期で `UserDefaults` に落とす。
///
/// - Important: このファイル群（`Spike/`）は G0 の実測が終わったら丸ごと削除する。
///   実装計画 P0 以降のコードと混ぜないこと。
enum SpikeConfig {

    /// true にすると、アプリ起動時に本体ではなく計測画面が出る。
    /// G0 の計測が終わったら false に戻す（あるいは `Spike/` ごと削除する）。
    static let enabled = true

    /// ペリフェラル役（`spike/peripheral-sim`）が公開するサービス。
    static let serviceUUIDString = "E7A1B2C0-1D3E-4F5A-8B6C-9D0E1F2A3B4C"

    /// ハートビート characteristic（notify）。これが背景起床のトリガになる。
    static let heartbeatUUIDString = "E7A1B2C1-1D3E-4F5A-8B6C-9D0E1F2A3B4C"

    /// CoreBluetooth 状態復元の識別子。OS がアプリを起こし直せるかの確認に使う。
    static let restoreIdentifier = "com.turetette.watch.spike.central"

    /// 背景タスクを開いたまま待つ上限。これを超えたら「実行枠内に返らなかった」と記録する。
    static let probeTimeout: TimeInterval = 20

    /// 遡り問い合わせの窓（G0-3）。
    static let lookbackWindow: TimeInterval = 180

    /// 保持するイベント数の上限。
    static let maxEvents = 1500
}

// MARK: - イベント

struct SpikeEvent: Codable, Identifiable {
    let id: UUID
    let at: Date
    let kind: Kind
    let detail: String
    /// 記録時のアプリ状態。`background` なら「起きていた」ことの証拠になる。
    let appState: String

    enum Kind: String, Codable {
        case launch          // アプリ起動
        case restore         // CoreBluetooth 状態復元（= OS が起こし直した）
        case phase           // 計測フェーズの切り替え
        case bleState        // CBCentralManager の状態変化
        case connect
        case disconnect
        case notify          // characteristic の値更新を受信（G0-1）
        case budgetNear      // LeGattNearBackgroundNotificationLimit（G0-2）
        case budgetExceeded  // LeGattExceededBackgroundNotificationLimit（G0-2）
        case wake            // バックグラウンドタスクで起きた
        case probeStart      // 遡り問い合わせ開始（G0-3）
        case probeEnd        // 同 完了
        case probeLost       // 同 実行枠内に返らなかった
        case note
    }
}

// MARK: - ロガー

final class SpikeLog {

    static let shared = SpikeLog()

    private let queue = DispatchQueue(label: "com.turetette.spike.log")
    private let eventsKey = "spike.g0.events"
    private let phaseKey  = "spike.g0.phase"

    private init() {}

    // MARK: 書き込み

    /// イベントを 1 件記録する。バックグラウンドから呼ばれるので即時に永続化する。
    func add(_ kind: SpikeEvent.Kind, _ detail: String = "") {
        // アプリ状態はメインスレッドからしか読めないため、呼び出し元の文脈で先に確定させる
        let state = Self.currentAppState()
        let event = SpikeEvent(id: UUID(), at: Date(), kind: kind, detail: detail, appState: state)

        queue.sync {
            var all = loadRaw()
            all.append(event)
            if all.count > SpikeConfig.maxEvents {
                all.removeFirst(all.count - SpikeConfig.maxEvents)
            }
            saveRaw(all)
        }
    }

    /// 計測フェーズ（A: notify のみ / B: 切断のみ）を切り替える。
    var phase: String {
        get { UserDefaults.standard.string(forKey: phaseKey) ?? "A" }
        set {
            UserDefaults.standard.set(newValue, forKey: phaseKey)
            add(.phase, "フェーズ \(newValue) を開始")
        }
    }

    // MARK: 読み出し

    func events() -> [SpikeEvent] {
        queue.sync { loadRaw() }
    }

    func clear() {
        queue.sync {
            UserDefaults.standard.removeObject(forKey: eventsKey)
        }
        add(.note, "ログを消去")
    }

    /// 共有・貼り付け用のテキスト。
    func exportText() -> String {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss.SSS"
        let lines = events().map { e in
            "\(df.string(from: e.at))\t\(e.kind.rawValue)\t\(e.appState)\t\(e.detail)"
        }
        return ([summaryText(), "", "--- events ---"] + lines).joined(separator: "\n")
    }

    // MARK: 集計

    /// G0 の 3 つの問いに対する現時点の答え。
    func summary() -> SpikeSummary {
        let all = events()
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let recent = all.filter { $0.at >= cutoff }

        // G0-1: バックグラウンドで受け取った notify の数
        let bgNotify = recent.filter { $0.kind == .notify && $0.appState != "active" }
        let fgNotify = recent.filter { $0.kind == .notify && $0.appState == "active" }

        // G0-2: 背景で起きた回数（notify 起床 + 切断起床）と、予算切れの記録
        let bgWakes = recent.filter { $0.kind == .wake }
        let bgDisconnects = recent.filter { $0.kind == .disconnect && $0.appState != "active" }
        let near = recent.filter { $0.kind == .budgetNear }
        let exceeded = recent.filter { $0.kind == .budgetExceeded }

        // G0-3: 遡り問い合わせが返ったか
        let probeStarts = recent.filter { $0.kind == .probeStart }
        let probeEnds = recent.filter { $0.kind == .probeEnd }
        let probeLost = recent.filter { $0.kind == .probeLost }

        return SpikeSummary(
            phase: phase,
            backgroundNotifyCount: bgNotify.count,
            foregroundNotifyCount: fgNotify.count,
            backgroundWakeCount: bgWakes.count,
            backgroundDisconnectCount: bgDisconnects.count,
            restoreCount: recent.filter { $0.kind == .restore }.count,
            budgetNearAt: near.last?.at,
            budgetExceededAt: exceeded.last?.at,
            probeStarted: probeStarts.count,
            probeReturned: probeEnds.count,
            probeLost: probeLost.count,
            probeDurationsMs: probeEnds.compactMap { Self.parseMs($0.detail) }
        )
    }

    func summaryText() -> String {
        let s = summary()
        var out = ["=== G0 スパイク 集計（直近 24 時間） ==="]
        out.append("フェーズ: \(s.phase)")
        out.append("")
        out.append("[G0-1] 背景 BLE 起床は来るか")
        out.append("  背景で受けた notify: \(s.backgroundNotifyCount) 件 / 前面: \(s.foregroundNotifyCount) 件")
        out.append("  状態復元（OS が起こし直した）: \(s.restoreCount) 回")
        out.append("")
        out.append("[G0-2] 予算は切断起床も数えるか")
        out.append("  背景で起きた回数: \(s.backgroundWakeCount) 回")
        out.append("  うち背景での切断イベント: \(s.backgroundDisconnectCount) 回")
        out.append("  予算警告(Near): \(s.budgetNearAt.map(Self.fmt) ?? "未検出")")
        out.append("  予算超過(Exceeded): \(s.budgetExceededAt.map(Self.fmt) ?? "未検出")")
        out.append("")
        out.append("[G0-3] 背景実行枠で遡り問い合わせは返るか")
        out.append("  開始: \(s.probeStarted) / 完了: \(s.probeReturned) / 未返却: \(s.probeLost)")
        if !s.probeDurationsMs.isEmpty {
            let sorted = s.probeDurationsMs.sorted()
            let max = sorted.last ?? 0
            let med = sorted[sorted.count / 2]
            out.append("  所要 中央値: \(med) ms / 最大: \(max) ms")
        }
        return out.joined(separator: "\n")
    }

    // MARK: 内部

    private func loadRaw() -> [SpikeEvent] {
        guard let data = UserDefaults.standard.data(forKey: eventsKey),
              let decoded = try? JSONDecoder().decode([SpikeEvent].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveRaw(_ events: [SpikeEvent]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: eventsKey)
    }

    private static func currentAppState() -> String {
        guard Thread.isMainThread else { return "unknown" }
        switch WKApplication.shared().applicationState {
        case .active:     return "active"
        case .inactive:   return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private static func parseMs(_ detail: String) -> Int? {
        // "pedometer 単独 812ms" のような文字列から数値を拾う
        guard let range = detail.range(of: #"(\d+)ms"#, options: .regularExpression) else { return nil }
        return Int(detail[range].dropLast(2))
    }

    private static func fmt(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss"
        return df.string(from: date)
    }
}

struct SpikeSummary {
    let phase: String
    let backgroundNotifyCount: Int
    let foregroundNotifyCount: Int
    let backgroundWakeCount: Int
    let backgroundDisconnectCount: Int
    let restoreCount: Int
    let budgetNearAt: Date?
    let budgetExceededAt: Date?
    let probeStarted: Int
    let probeReturned: Int
    let probeLost: Int
    let probeDurationsMs: [Int]
}
