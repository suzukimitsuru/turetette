import WatchKit
import UserNotifications

/// WKApplicationDelegate
///
/// バックグラウンドタスクの受け口として機能する。
/// Manager との結合は NotificationCenter 経由で疎結合に保ち、
/// Manager インスタンスを直接保持しない。
///
/// ## バックグラウンド処理の流れ
/// ```
/// OS (15分ごと)
///   └─ WKApplicationRefreshBackgroundTask
///        └─ NotificationCenter.post(.backgroundBLECheckRequested)
///             └─ BLEManager: RSSI 単発チェック
///                  └─ 圏外なら UNUserNotificationCenter で通知発火
///
/// BLE 切断検知 (OS が自動トリガー)
///   └─ WKBluetoothAlertBackgroundTask
///        └─ NotificationCenter.post(.backgroundBLEAlertReceived)
///             └─ BLEManager: 切断状態を評価してローカル通知発火
/// ```
final class AppDelegate: NSObject, WKApplicationDelegate {

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching() {
        requestNotificationPermission()
        scheduleBackgroundRefresh()
    }

    func applicationWillResignActive() {
        // フォアグラウンドを離れる際に次回リフレッシュを確実に予約する
        scheduleBackgroundRefresh()
    }

    func applicationDidBecomeActive() {
        // フォアグラウンドに戻った際、AlarmManager にハプティクス再開を通知
        NotificationCenter.default.post(name: .appDidBecomeActive, object: nil)
    }

    // MARK: - Background Task Handler

    /// watchOS のバックグラウンドタスクをすべてここで受け取る。
    /// - Important: 受け取った全タスクで必ず setTaskCompleted() を呼ぶこと。
    ///   完了させないと以降のバックグラウンド起動が制限される。
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {

            case let appRefreshTask as WKApplicationRefreshBackgroundTask:
                handleAppRefresh(appRefreshTask)

            case let bluetoothTask as WKBluetoothAlertBackgroundTask:
                handleBluetoothAlert(bluetoothTask)

            case let snapshotTask as WKSnapshotRefreshBackgroundTask:
                // コンプリケーション/スナップショットの更新
                snapshotTask.setTaskCompleted(
                    restoredDefaultState: true,
                    estimatedSnapshotExpiration: .distantFuture,
                    userInfo: nil
                )

            default:
                // 未知のタスクも必ず完了させる
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    // MARK: - Background Refresh Scheduling

    /// 次回 Background App Refresh を 15 分後にスケジュールする。
    /// - Note: OS は battery・activity の状態により実際の起動時刻を調整する。
    ///   希望した通りの間隔で起動されるとは限らない。
    func scheduleBackgroundRefresh() {
        let preferredDate = Date(timeIntervalSinceNow: 15 * 60)
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: preferredDate,
            userInfo: nil
        ) { error in
            if let error = error {
                print("[AppDelegate] Background refresh schedule failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private Task Handlers

    private func handleAppRefresh(_ task: WKApplicationRefreshBackgroundTask) {
        // BLEManager に RSSI の単発チェックを依頼
        NotificationCenter.default.post(name: .backgroundBLECheckRequested, object: nil)

        // 次回リフレッシュをスケジュールしてからタスクを完了
        scheduleBackgroundRefresh()
        task.setTaskCompletedWithSnapshot(false)
    }

    private func handleBluetoothAlert(_ task: WKBluetoothAlertBackgroundTask) {
        // BLE 切断 / アラート発生 → BLEManager に状態評価を依頼
        NotificationCenter.default.post(name: .backgroundBLEAlertReceived, object: nil)
        task.setTaskCompleted()
    }

    // MARK: - Notification Permission

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error = error {
                print("[AppDelegate] Notification permission error: \(error.localizedDescription)")
            }
            print("[AppDelegate] Notification permission granted: \(granted)")
        }
    }
}
