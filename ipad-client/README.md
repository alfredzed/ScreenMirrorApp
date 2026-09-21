# iPad クライアント セットアップ手順（クラウドMac / Xcode）

## 1.03 USB直結

`Sources/Networking/UsbStreamListener.swift`を追加し、iPad側がTCP 27183で待ち受ける方式に対応しました。Windows側の`iproxy`がこのポートへUSBMux経由で接続するため、映像とタッチ操作にWi-Fi/LANは使いません。USB使用中もアプリは前面で起動しておいてください。

既存プロジェクトへ更新する場合は`Sources`以下を上書きし、新規の`UsbStreamListener.swift`もXcodeターゲットへ追加してください。Apple Developer署名でiPad実機へインストール後、初回USB接続時に「このコンピュータを信頼」を許可します。

このディレクトリの `Sources/` 以下は、Xcodeの「iOS App」テンプレート（Interface: SwiftUI,
Language: Swift）に追加するソースファイル一式です。`.xcodeproj` 自体はXcode上での新規作成が
必要なため含まれていません。

## 1. Xcodeプロジェクトの作成
1. Xcode → File → New → Project → iOS → App
2. Interface: **SwiftUI** / Language: **Swift** を選択
3. Deployment Target: iOS 16 以降を推奨（`persistentSystemOverlays` 等を使用しているため）
4. 作成後、デフォルトで生成される `ContentView.swift` と `<プロジェクト名>App.swift` を削除し、
   本ディレクトリの `Sources/` 配下のファイル一式（フォルダ構成ごと）をプロジェクトへドラッグ＆
   ドロップして追加してください。

## 2. Info.plist の設定（重要）

### (a) ローカルネットワークアクセス許可（iOS 14+で必須）
同一LAN上のWindows PCへ接続するため、以下のキーを追加してください。

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>同じWi-Fi上のPCへ画面のサブモニター表示のために接続します</string>
```

### (b) App Transport Security（ws:// 非TLS通信の許可）
本アプリは `ws://`（非暗号化）でWindows PCと通信するため、ATSの例外設定が必要です。
接続先のPCがLAN内の固定IPである場合は、必要な範囲だけ緩和する以下の設定を推奨します
（`<IPアドレスまたはホスト名>` は実際の接続先に合わせて追加/変更してください。複数拠点で
IPが変わる場合は `NSAllowsArbitraryLoads` を `true` にする方が簡便です）。

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

## 3. 実行時の注意
- Windows側 `server.py` を先に起動し、`ws://<PCのIP>:8765/stream` で待ち受けていることを確認してください。
- アプリ初回起動時、「ローカルネットワーク上のデバイスを検索することを許可しますか？」という
  システムダイアログが表示されるので許可してください（拒否すると接続できません）。
- 同一LANのIPアドレスが動的に変わる環境の場合、接続フォームで都度IPを入力するか、
  Windows側で固定IP/ホスト名を設定することを推奨します。

## 4. 未検証事項（実機・Xcodeでの確認が必要）
このプロジェクトはサンドボックス環境で作成されたため、Swiftコンパイラによる構文チェックは
実施できていません（Xcode上でのビルドを最初に行ってください）。特に以下は実機確認を推奨します。

- `VTDecompressionSession` のコールバック型シグネチャ（Xcode/SDKバージョンにより微修正が必要な場合あり）
- 無印iPad/iPad mini等、ProMotion非搭載機種でのフレームレート上限の扱い
- Wi-Fi環境によっては `dxcam` 側のフレームレートとの同期（フレーム間引き/バッファリング）の調整
