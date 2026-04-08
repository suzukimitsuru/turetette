import Foundation
import WatchKit
import UserNotifications
import Combine

/// アラームの開始・停止を管理する。
///
/// ## フォアグラウンド時
/// `WKInterfaceDevice.play()` による繰り返しハプティクスでアラームを通知する。
///
/// ## バックグラウンド時
/// ハプティクスは動作しないため `UNUserNotificationCenter` のローカル通知を使用する。
/// アプリがフォアグラウンドに戻った際、`isAlarmActive == true` ならハプティクスを再開する。
final class AlarmManager: ObservableObject {

    // MARK: - Published State

    @Published var isAlarmActive: Bool = false
    @Published var alarmReason: String = ""

    // MARK: - Private

    private var hapticTimer: Timer?
    private var hapticToggle: Bool = false
    private var cancellables = Set<AnyCancellable>()

    /// バックグラウンド通知の識別子（上書きで重複を防ぐ）
    private let notificationIdentifier = "com.turetette.watch.alarm"

    // MARK: - Init / Deinit

    init() {
        // フォアグラウンド復帰通知を購読してハプティクスを再開する
        NotificationCenter.default
            .publisher(for: .appDidBecomeActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resumeHapticIfNeeded()
            }
            .store(in: &cancellables)
    }

    deinit {
        stopAlarm()
    }

    // MARK: - Public API

    /// アラームを開始する。
    /// - Parameter reason: アラームの理由（画面・通知に表示する）
    func startAlarm(reason: String) {
        guard !isAlarmActive else { return }
        alarmReason = reason
        isAlarmActive = true

        let state = WKApplication.shared().applicationState
        if state == .active {
            // フォアグラウンド: 即時ハプティクス + 繰り返しタイマー
            startHapticTimer()
        } else {
            // バックグラウンド: ローカル通知を発火（ハプティクスはOSが担当）
            // フォアグラウンド復帰後に resumeHapticIfNeeded() でタイマーを開始する
            sendLocalNotification(reason: reason)
        }
    }

    /// アラームを手動停止する。
    func stopAlarm() {
        stopHapticTimer()
        cancelPendingNotifications()
        isAlarmActive = false
        alarmReason = ""
        hapticToggle = false
    }

    /// フォアグラウンドに戻った際、アラームが継続中であればハプティクスを再開する。
    func resumeHapticIfNeeded() {
        guard isAlarmActive, hapticTimer == nil else { return }
        startHapticTimer()
    }

    // MARK: - Haptic Timer

    private func startHapticTimer() {
        stopHapticTimer()
        playHaptic() // 即時1回
        hapticTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.playHaptic()
        }
    }

    private func stopHapticTimer() {
        hapticTimer?.invalidate()
        hapticTimer = nil
    }

    private func playHaptic() {
        let device = WKInterfaceDevice.current()
        device.play(hapticToggle ? .notification : .directionUp)
        hapticToggle.toggle()
    }

    // MARK: - Local Notification

    /// バックグラウンドアラームのローカル通知を発火する。
    /// watchOS はシステムハプティクス付きで通知を届ける。
    private func sendLocalNotification(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ アラーム"
        content.body = reason
        content.sound = .default

        // 1秒後に即時発火（バックグラウンドタスクに余裕を持たせる）
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[AlarmManager] Local notification error: \(error.localizedDescription)")
            }
        }
    }

    /// 未配信のアラーム通知をキャンセルする。
    private func cancelPendingNotifications() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
    }
}
