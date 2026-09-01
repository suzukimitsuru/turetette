import Foundation
import WatchKit
import UserNotifications
import Combine

/// 「ユーザが止めるまで鳴らす」を実現するアラーム管理。
///
/// 単一の API では実現できないため、設計 §7 のとおり 3 段構えにしている。
///
/// | 段階 | 手段 | 画面消灯時 | 継続時間 |
/// |---|---|---|---|
/// | 1 | ローカル通知（即時） | ○ | 単発 |
/// | 2 | 通知の連投（5 秒 × 48 発） | ○ | 約 4 分 / バッチ |
/// | 3 | `WKExtendedRuntimeSession` のハプティクス | ○ | 停止するまで（上限 1 時間） |
///
/// 段階 3 は **アプリが前面にあるときしか開始できない**（`start()` の制約、§2.3）。
/// そのため「背景で段階 1〜2 が鳴る → ユーザが通知をタップ → 前面化 → 段階 3 が引き継ぐ」
/// という流れになる。
///
/// - Note: 旧実装は「前面で `Timer` + `play()`」だったため、**画面が消えた瞬間に鳴り止んで**いた（§9-6）。
final class AlarmManager: NSObject, ObservableObject {

    // MARK: - 定数

    /// 通知カテゴリ。「停止」アクションを持たせる。
    static let categoryIdentifier = "TURETETTE_ALARM"
    /// 「停止」アクション。
    static let stopActionIdentifier = "TURETETTE_ALARM_STOP"

    /// 通知センターで束ねるためのスレッド ID。連投が 48 件並ぶのを 1 つにまとめる。
    private static let threadIdentifier = "turetette.alarm"
    private static let identifierPrefix = "com.turetette.watch.alarm."

    /// 連投の設定（§7 段階2）。
    /// 未配信の通知リクエストは **アプリあたり 64 件が上限**なので、余裕を残して 48 発にする。
    private static let burstCount = 48
    private static let burstInterval: TimeInterval = 5

    /// 段階 3 のハプティクス間隔。
    private static let hapticInterval: TimeInterval = 2

    // MARK: - 公開状態

    @Published private(set) var isAlarmActive: Bool = false
    @Published private(set) var alarmReason: String = ""

    /// 段階 3（画面消灯中も継続するハプティクス）が動いているか。
    /// false のまま鳴っている場合は、段階 1〜2 の通知だけで鳴っている状態。
    @Published private(set) var isContinuousHapticActive: Bool = false

    // MARK: - 内部

    private var session: WKExtendedRuntimeSession?
    /// 段階 3 を張れなかったときの前面専用フォールバック。
    private var foregroundTimer: Timer?
    private var hapticToggle = false
    private var cancellables = Set<AnyCancellable>()

    private let store = UserDefaults.standard
    private enum Key {
        static let active = "alarm.isActive"
        static let reason = "alarm.reason"
        static let startedAt = "alarm.startedAt"
    }

    /// 連投で使う識別子の全リスト。停止時はこれを丸ごと消す（§9 の「1 個しか消していない」の修正）。
    private var allIdentifiers: [String] {
        (0..<Self.burstCount).map { "\(Self.identifierPrefix)\($0)" }
    }

    // MARK: - 初期化

    override init() {
        super.init()

        // 通知の「停止」アクションは AppDelegate が受け取り、ここへ中継される
        NotificationCenter.default
            .publisher(for: .alarmStopRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.stopAlarm() }
            .store(in: &cancellables)

        // 前面へ戻ったら段階 3 を張り直す（背景では start() できないため）
        NotificationCenter.default
            .publisher(for: .appDidBecomeActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleDidBecomeActive() }
            .store(in: &cancellables)

        // 背景更新のたびに、尽きかけた連投を積み直す
        NotificationCenter.default
            .publisher(for: .alarmRefillRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refillBurstIfNeeded() }
            .store(in: &cancellables)

        restoreFromStore()
    }

    deinit {
        foregroundTimer?.invalidate()
        session?.invalidate()
    }

    // MARK: - 公開 API

    /// アラームを開始する。
    /// - Parameter reason: 通知と画面に出す理由。
    func startAlarm(reason: String) {
        guard !isAlarmActive else { return }

        isAlarmActive = true
        alarmReason = reason
        persist(startedAt: Date())

        // 段階 1 + 2: 背景でも鳴る経路をまず確保する
        scheduleNotificationBurst(reason: reason)

        // 段階 3: 前面にいるときだけ張れる
        startExtendedRuntimeSessionIfPossible()
    }

    /// アラームを停止する。**鳴っている経路をすべて止める。**
    func stopAlarm() {
        cancelAllNotifications()
        stopForegroundTimer()

        session?.invalidate()
        session = nil
        isContinuousHapticActive = false

        isAlarmActive = false
        alarmReason = ""
        hapticToggle = false
        clearStore()
    }

    /// 背景起床時に呼ぶ。連投が尽きかけていたら積み直す。
    ///
    /// 1 バッチは約 4 分で尽きる。アプリが背景で生きている間に補充できれば、
    /// ユーザが気づくまで鳴り続けられる。
    func refillBurstIfNeeded() {
        guard isAlarmActive else { return }
        let ids = allIdentifiers
        UNUserNotificationCenter.current().getPendingNotificationRequests { [weak self] pending in
            guard let self else { return }
            let remaining = pending.filter { ids.contains($0.identifier) }.count
            // 残り 1 分（12 発）を切ったら積み直す
            guard remaining < 12 else { return }
            DispatchQueue.main.async {
                self.scheduleNotificationBurst(reason: self.alarmReason)
            }
        }
    }

    // MARK: - 段階 1 + 2: 通知

    private func scheduleNotificationBurst(reason: String) {
        let center = UNUserNotificationCenter.current()
        // 積み直しの前に必ず古い分を消す。消さないと 64 件上限に当たって捨てられる
        center.removePendingNotificationRequests(withIdentifiers: allIdentifiers)

        let content = UNMutableNotificationContent()
        content.title = "デバイスが離れました"
        content.body = reason
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = Self.threadIdentifier
        // 集中モードを貫通させる。Time Sensitive capability が無い環境では
        // システムが通常の通知に落とすだけで、害はない（§2.4）
        content.interruptionLevel = .timeSensitive

        for index in 0..<Self.burstCount {
            // `repeats: true` は 60 秒以上でないと使えないため、一発ずつ積む（§2.4）
            let delay = 1 + Double(index) * Self.burstInterval
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(Self.identifierPrefix)\(index)",
                content: content,
                trigger: trigger
            )
            center.add(request) { error in
                if let error {
                    print("[AlarmManager] 通知の登録に失敗 #\(index): \(error.localizedDescription)")
                }
            }
        }
    }

    /// 未配信と配信済みの **両方** を、全 ID について消す。
    private func cancelAllNotifications() {
        let center = UNUserNotificationCenter.current()
        let ids = allIdentifiers
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    // MARK: - 段階 3: Extended Runtime Session

    /// 前面にいるときだけ段階 3 を開始する。
    /// `start()` は `WKApplicationState.active` でしか呼べない（§2.3）。
    private func startExtendedRuntimeSessionIfPossible() {
        guard isAlarmActive, session == nil else { return }

        guard WKApplication.shared().applicationState == .active else {
            // 背景では張れない。段階 1〜2 の通知に任せ、前面化を待つ
            return
        }

        let newSession = WKExtendedRuntimeSession()
        newSession.delegate = self
        newSession.start()
        session = newSession
    }

    private func handleDidBecomeActive() {
        guard isAlarmActive else { return }
        // 前面に来た。ここで初めて段階 3 を張れる
        startExtendedRuntimeSessionIfPossible()
    }

    // MARK: - フォールバック（前面専用）

    /// 段階 3 が張れなかったときに、せめて前面の間だけ鳴らす。
    /// **画面が消えると止まる**ので、あくまで保険。
    private func startForegroundTimer() {
        guard foregroundTimer == nil else { return }
        playHaptic()
        foregroundTimer = Timer.scheduledTimer(
            withTimeInterval: Self.hapticInterval, repeats: true
        ) { [weak self] _ in
            self?.playHaptic()
        }
    }

    private func stopForegroundTimer() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    private func playHaptic() {
        WKInterfaceDevice.current().play(hapticToggle ? .notification : .directionUp)
        hapticToggle.toggle()
    }

    // MARK: - 永続化

    /// 背景でアプリが終了してもアラーム状態を失わないようにする（§9-7）。
    private func persist(startedAt: Date) {
        store.set(true, forKey: Key.active)
        store.set(alarmReason, forKey: Key.reason)
        store.set(startedAt.timeIntervalSince1970, forKey: Key.startedAt)
    }

    private func clearStore() {
        store.removeObject(forKey: Key.active)
        store.removeObject(forKey: Key.reason)
        store.removeObject(forKey: Key.startedAt)
    }

    private func restoreFromStore() {
        guard store.bool(forKey: Key.active) else { return }
        isAlarmActive = true
        alarmReason = store.string(forKey: Key.reason) ?? "デバイスが離れました"
        // 復帰直後は前面とは限らないので、段階 3 は appDidBecomeActive に任せる
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension AlarmManager: WKExtendedRuntimeSessionDelegate {

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        isContinuousHapticActive = true
        stopForegroundTimer()   // 段階 3 が動くならフォールバックは不要

        // `repeatHandler` が次回までの秒数を返し続ける限り鳴り続ける。
        // これが「止めるまで鳴らす」の本体で、**画面が消えても継続する**。
        extendedRuntimeSession.notifyUser(hapticType: .notification) { [weak self] type in
            guard let self, self.isAlarmActive else {
                return 0    // 0 を返すと繰り返しが終わる
            }
            type.pointee = .notification
            return Self.hapticInterval
        }
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // セッションの上限が近い。通知の連投を積み直して鳴動を引き継ぐ
        guard isAlarmActive else { return }
        scheduleNotificationBurst(reason: alarmReason)
    }

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        isContinuousHapticActive = false
        session = nil

        guard isAlarmActive else { return }

        if let error {
            print("[AlarmManager] 拡張ランタイムセッションが無効化: \(reason.rawValue) \(error.localizedDescription)")
        }

        // まだ鳴らすべきなら、前面にいる間だけでもフォールバックで鳴らす
        if WKApplication.shared().applicationState == .active {
            startForegroundTimer()
        }
        // 背景経路は通知の連投が担う
        scheduleNotificationBurst(reason: alarmReason)
    }
}
