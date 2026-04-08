import Foundation
import CoreMotion
import Combine

/// Monitors user activity (walking, running, stationary) using CMMotionActivityManager.
/// When the user transitions from stationary to walking/running, `isWalking` is set to
/// true and `onMotionStarted` is called.
final class MotionManager: ObservableObject {

    // MARK: - Published state

    @Published var isWalking: Bool = false
    @Published var isStanding: Bool = false  // just transitioned from moving → stationary
    @Published var currentActivity: String = "不明"

    // MARK: - Callbacks

    /// Called on the main queue when the user starts moving (stationary → walking/running).
    var onMotionStarted: (() -> Void)?

    // MARK: - Private

    private let activityManager = CMMotionActivityManager()
    private var previousActivityWasStationary: Bool = true
    private var isMonitoring: Bool = false

    // MARK: - Init / Deinit

    init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public API

    func startMonitoring() {
        guard !isMonitoring else { return }
        guard CMMotionActivityManager.isActivityAvailable() else {
            DispatchQueue.main.async { self.currentActivity = "利用不可" }
            return
        }

        isMonitoring = true
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self = self, let activity = activity else { return }
            self.handleActivityUpdate(activity)
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        activityManager.stopActivityUpdates()
        isMonitoring = false
    }

    // MARK: - Private helpers

    private func handleActivityUpdate(_ activity: CMMotionActivity) {
        let nowWalking = activity.walking || activity.running || activity.cycling
        let nowStationary = activity.stationary

        // Determine human-readable description
        let description: String
        if activity.walking {
            description = "歩行中"
        } else if activity.running {
            description = "走行中"
        } else if activity.cycling {
            description = "自転車"
        } else if activity.automotive {
            description = "車移動"
        } else if activity.stationary {
            description = "静止中"
        } else {
            description = "不明"
        }

        // Transition: stationary → moving
        if nowWalking && previousActivityWasStationary {
            isWalking = true
            isStanding = false
            onMotionStarted?()
        }

        // Transition: moving → stationary
        if nowStationary && !previousActivityWasStationary {
            isWalking = false
            isStanding = true
        }

        // Update general walking flag
        if !nowWalking {
            isWalking = false
        }

        currentActivity = description
        previousActivityWasStationary = nowStationary
    }
}
