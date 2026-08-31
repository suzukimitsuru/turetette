import Foundation
import WatchKit

/// G0 スパイクの司令塔。
///
/// バックグラウンドタスクの完了を**自分で握る**のが要点。
/// 既存の `AppDelegate` は受け取ってすぐ `setTaskCompleted` を呼ぶが、それだと
/// 「実行枠の中で遡り問い合わせが返るか」（G0-3）が測れない。
/// ここではタスクを開いたまま probe を走らせ、返るか打ち切るまで待ってから完了させる。
final class SpikeRunner {

    static let shared = SpikeRunner()

    private let workQueue = DispatchQueue(label: "com.turetette.spike.runner")
    private var didBootstrap = false

    private init() {}

    // MARK: 起動

    /// アプリ起動時に一度だけ呼ぶ。
    func bootstrap() {
        guard SpikeConfig.enabled, !didBootstrap else { return }
        didBootstrap = true

        SpikeLog.shared.add(.launch, "起動 / \(SpikeMotionProbe.shared.availabilityText)")

        // 前回の起床で返らなかった probe を回収する（G0-3）
        SpikeMotionProbe.shared.reapLostProbes()

        SpikeCentral.shared.start()
        scheduleRefresh()
    }

    // MARK: バックグラウンドタスク

    /// `AppDelegate.handle(_:)` から呼ぶ。
    /// - Returns: スパイクがこのタスクを引き受けたら true。false なら本体の処理に任せる。
    func handle(_ task: WKRefreshBackgroundTask) -> Bool {
        guard SpikeConfig.enabled else { return false }

        let label: String
        switch task {
        case is WKApplicationRefreshBackgroundTask:      label = "AppRefresh"
        case is WKBluetoothAlertRefreshBackgroundTask:   label = "BluetoothAlert"
        case is WKWatchConnectivityRefreshBackgroundTask: label = "WatchConnectivity"
        case is WKSnapshotRefreshBackgroundTask:         label = "Snapshot"
        default:                                          label = String(describing: type(of: task))
        }

        // スナップショットは計測対象外。すぐ返す。
        if let snapshot = task as? WKSnapshotRefreshBackgroundTask {
            snapshot.setTaskCompleted(restoredDefaultState: true,
                                      estimatedSnapshotExpiration: .distantFuture,
                                      userInfo: nil)
            return true
        }

        SpikeLog.shared.add(.wake, "種別=\(label)")
        SpikeMotionProbe.shared.reapLostProbes()

        // 次回を先に予約しておく（予約し忘れると二度と起きない）
        if task is WKApplicationRefreshBackgroundTask { scheduleRefresh() }

        // タスクを開いたまま probe を走らせ、返るか打ち切ってから完了させる
        workQueue.async {
            SpikeMotionProbe.shared.run(reason: "wake:\(label)") {
                DispatchQueue.main.async {
                    task.setTaskCompletedWithSnapshot(false)
                }
            }
        }
        return true
    }

    /// notify や切断で起こされたとき、その実行枠で probe を回す。
    /// 前面にいるときは「枠」の話ではないので測らない。
    func probeIfBackground(reason: String) {
        guard SpikeConfig.enabled else { return }
        guard WKApplication.shared().applicationState != .active else { return }

        workQueue.async {
            SpikeMotionProbe.shared.run(reason: reason) { }
        }
    }

    /// 前面から手動で 1 回測る（動作確認用）。
    func probeNow(reason: String = "manual", completion: @escaping () -> Void) {
        workQueue.async {
            SpikeMotionProbe.shared.run(reason: reason) {
                DispatchQueue.main.async { completion() }
            }
        }
    }

    // MARK: 背景更新の予約

    /// 15 分後を希望して予約する。実際に何分後に来たかはログの `wake` 間隔で分かる。
    func scheduleRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: 15 * 60),
            userInfo: nil
        ) { error in
            if let error {
                SpikeLog.shared.add(.note, "背景更新の予約に失敗 \(error.localizedDescription)")
            }
        }
    }
}
