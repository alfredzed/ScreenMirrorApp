# ScreenMirror Touch Display Server 1.03

Windows画面をiPadへ送り、iPadのタッチ操作をマウス入力として戻すサーバーです。USBケーブル直結と従来のWi-Fi/LAN接続に対応します。

画面キャプチャには現在のマウス位置を示す矢印ポインタも合成されます。iPadからのタップ、ドラッグ、2本指スクロールは、選択したモニターのWindows座標へ変換されます。

## USB直結

1. WindowsへApple Devices（またはiTunes）をインストールし、Apple Mobile Device Supportを有効にします。
2. iPadをUSBケーブルで接続し、iPadに表示される「このコンピュータを信頼」を許可します。
3. iPadアプリで「USB直結」を選び、「USB接続を待ち受ける」を押します。
4. WindowsでScreenMirrorServer.exeを起動します。既定の`auto`モードがUSBを優先し、iPadへ接続します。

USBモードは`iproxy`でWindowsの`127.0.0.1:27183`をiPadのTCP 27183へ転送します。映像もタッチ入力もこのUSB経路を通り、Wi-Fiは使いません。

## GPUエンコード

既定の`--encoder auto`は、実際に利用できる方式を次の順で試します。

1. NVIDIA NVENC (`h264_nvenc`)
2. Intel Quick Sync (`h264_qsv`)
3. AMD AMF (`h264_amf`)
4. CPU (`libx264`)

ドライバー未導入、非対応GPU、初期化失敗時は次の方式へ自動で切り替わります。コンソールの`encoder=...`が実際に選ばれた方式です。

## 仮想ディスプレイ／モニター選択

既定は`--monitor 1`です。仮想ディスプレイドライバーで追加した2画面目を送る場合は、ショートカットまたはコマンドプロンプトから次のように起動します。

```text
ScreenMirrorServer.exe --monitor 2
```

USBだけを使う場合:

```text
ScreenMirrorServer.exe --transport usb --monitor 2 --encoder auto
```

30fpsへ下げる場合は`--fps 30`、1080p未満へ抑える場合は`--max-width 1280`を追加します。

## Wi-Fi/LAN

従来どおりTCP 8765のWebSocketを使います。起動時にファイアウォール規則を追加した場合のみ、同じLANのiPadから接続できます。USB直結だけなら受信規則は不要です。

## 同梱する外部コンポーネント

USB転送用にlibimobiledevice/libusbmuxd系の`iproxy` Windowsバイナリを同梱します。ライセンス文は`licenses`フォルダにあります。配布元はlibimobiledevice-win32/imobiledevice-net v1.3.17です。
