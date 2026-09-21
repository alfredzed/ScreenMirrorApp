# ScreenMirrorApp USB/GPU 1.03

この版では次を追加しました。

- iPadとWindowsをApple USBMux (`iproxy`) で直結するTCPトランスポート
- NVIDIA NVENC、Intel Quick Sync、AMD AMF、CPU x264の自動選択と実行時フォールバック
- `mss`による安定キャプチャと`--monitor`による仮想ディスプレイ選択
- iPad側の最新フレーム優先表示（描画待ちフレームをためず遅延増加を抑制）

Windows側の導入方法は`windows-server/README.md`、iPad側のソースは`ipad-client/Sources`にあります。
