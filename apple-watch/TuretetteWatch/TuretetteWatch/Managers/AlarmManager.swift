import Foundation
import WatchKit
import Combine

/// Manages the repeating haptic alarm.
///
/// When `startAlarm(reason:)` is called, a repeating Timer fires every 2 seconds
/// and alternates between `.notification` and `.directionUp` haptic types.
/// Call `stopAlarm()` to silence everything.
final class AlarmManager: ObservableObject {

    // MARK: - Published state

    @Published var isAlarmActive: Bool = false
    @Published var alarmReason: String = ""

    // MARK: - Private

    private var hapticTimer: Timer?
    private var hapticToggle: Bool = false

    // MARK: - Public API

    /// Start the alarm with a descriptive reason string.
    func startAlarm(reason: String) {
        guard !isAlarmActive else { return }
        alarmReason = reason
        isAlarmActive = true

        // Fire immediately once, then repeat.
        playHaptic()
        hapticTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in
            self?.playHaptic()
        }
    }

    /// Stop the alarm and reset state.
    func stopAlarm() {
        hapticTimer?.invalidate()
        hapticTimer = nil
        isAlarmActive = false
        alarmReason = ""
        hapticToggle = false
    }

    // MARK: - Private helpers

    private func playHaptic() {
        let device = WKInterfaceDevice.current()
        if hapticToggle {
            device.play(.notification)
        } else {
            device.play(.directionUp)
        }
        hapticToggle.toggle()
    }
}
