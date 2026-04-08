import SwiftUI

@main
struct TuretetteWatchApp: App {

    /// バックグラウンドタスク・ライフサイクルの受け口
    /// Manager インスタンスは保持せず、NotificationCenter 経由で疎結合に連携する
    @WKApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Manager インスタンスのライフタイムはこの App が管理する
    @StateObject private var bleManager = BLEManager()
    @StateObject private var motionManager = MotionManager()
    @StateObject private var alarmManager = AlarmManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
                .environmentObject(motionManager)
                .environmentObject(alarmManager)
        }
    }
}
