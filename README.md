# Turetette（連れてって）

BLEデバイスとの距離を監視し、一定距離以上離れた時にアラームを鳴らすアプリ群。

## 概要

Apple Watch を装着したユーザーが、BLE接続したデバイス（例：スマートフォン、タグ）から離れた際に、手動で停止するまで鳴り続けるアラームを提供します。

## フォルダ構成

```
turetette/
├── apple-watch/          # Apple Watch アプリ (watchOS / Swift)
│   └── TuretetteWatch/
│       ├── TuretetteWatch.xcodeproj/
│       └── TuretetteWatch/
│           ├── TuretetteWatchApp.swift   # アプリエントリポイント
│           ├── ContentView.swift         # メイン画面
│           ├── Managers/
│           │   ├── BLEManager.swift      # BLE管理・距離計算
│           │   ├── MotionManager.swift   # モーション検出
│           │   └── AlarmManager.swift    # アラーム管理
│           ├── Views/
│           │   ├── DeviceScanView.swift  # デバイスリスト画面
│           │   └── AlarmView.swift       # アラーム画面
│           ├── Assets.xcassets/
│           └── Info.plist
├── ios/                  # (予定) iPhone アプリ (iOS / Swift)
└── android/              # (予定) Android アプリ (Kotlin / Java)
```

## Apple Watch アプリ機能

### BLE距離監視
- 周辺のBLEデバイスをスキャン・接続
- 1秒ごとに電波強度(RSSI)を取得
- RSSI → 距離変換: `distance = 10 ^ ((txPower - RSSI) / (10 × n))`
  (txPower = -59 dBm @ 1m、n = 2.0)
- 2m以上離れると `isOutOfRange = true`

### モーション検知トリガー
- `CMMotionActivityManager` で静止→歩行/走行の状態変化を検知
- 立ち上がり・歩き出しのタイミングでBLE距離チェックを実行

### アラーム
- BLE距離超過 × モーション検知で発動
- `WKInterfaceDevice.play()` によるハプティクス(2秒おきに繰り返し)
- 手動で「停止」ボタンを押すまで継続
- 全画面アラーム表示(赤背景 + 停止ボタン)

## 開発環境

| 項目 | 内容 |
|------|------|
| 言語 | Swift 5.0 |
| プラットフォーム | watchOS 9.0+ |
| フレームワーク | SwiftUI, CoreBluetooth, CoreMotion, WatchKit |
| IDE | Xcode 14+ |

## セットアップ

1. `apple-watch/TuretetteWatch/TuretetteWatch.xcodeproj` を Xcode で開く
2. Team / Bundle ID を設定（Signing & Capabilities）
3. Apple Watch 実機またはシミュレータで実行
4. 「デバイスをスキャン」からBLEデバイスを選択・接続

## 注意事項

- BLEスキャンは実機でのみ動作（シミュレータは制限あり）
- CoreMotionはシミュレータでも一部動作可
- BLE距離推定はあくまで目安（環境・デバイスにより誤差あり）

## ライセンス

[LICENSE](LICENSE) を参照してください。
