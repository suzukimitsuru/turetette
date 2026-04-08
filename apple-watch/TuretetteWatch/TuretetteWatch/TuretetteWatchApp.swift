import SwiftUI

@main
struct TuretetteWatchApp: App {
    @StateObject private var bleManager = BLEManager()
    @StateObject private var motionManager = MotionManager()
    @StateObject private var alarmManager = AlarmManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
                .environmentObject(motionManager)
                .environmentObject(alarmManager)
                .onAppear {
                    // Managers are ready; integration logic lives in ContentView
                }
        }
    }
}
