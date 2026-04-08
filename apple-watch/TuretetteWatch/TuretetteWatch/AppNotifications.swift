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
    /// AlarmManager が受け取り、バックグラウンド中に発火したアラームのハプティクスを再開する
    static let appDidBecomeActive = Notification.Name(
        "com.turetette.watch.appDidBecomeActive"
    )
}
