import Foundation

/// アプリ全体で使用する NotificationCenter の通知名定義
/// AppDelegate ↔ Manager 間の疎結合な連携に使用する
extension Notification.Name {

    /// Background App Refresh タスクがトリガーされた時に AppDelegate が投げる
    /// BLEManager がこれを受け取り、RSSI を単発チェックする
    static let backgroundBLECheckRequested = Notification.Name(
        "com.turetette.watch.backgroundBLECheckRequested"
    )

    /// WKBluetoothAlertRefreshBackgroundTask (BLE Characteristic 変化アラート) が届いた時に AppDelegate が投げる
    /// BLEManager が受け取り、切断状態を評価してローカル通知を発火する
    /// watchOS 9+、Apple Watch Series 6 以降でのみトリガーされる
    static let backgroundBLEAlertReceived = Notification.Name(
        "com.turetette.watch.backgroundBLEAlertReceived"
    )

    /// アプリがフォアグラウンドに戻った時に AppDelegate が投げる
    /// AlarmManager が受け取り、拡張ランタイムセッション（§7 段階3）を張り直す
    static let appDidBecomeActive = Notification.Name(
        "com.turetette.watch.appDidBecomeActive"
    )

    /// 通知の「停止」アクションが押された時に AppDelegate が投げる
    /// AlarmManager が受け取り、鳴っている経路をすべて止める
    static let alarmStopRequested = Notification.Name(
        "com.turetette.watch.alarmStopRequested"
    )

    /// 背景更新のたびに AppDelegate が投げる
    /// AlarmManager が受け取り、尽きかけた通知の連投を積み直す
    static let alarmRefillRequested = Notification.Name(
        "com.turetette.watch.alarmRefillRequested"
    )
}
