# AirUltrawide

XREAL Air 2 用の 5120×1440 仮想ウルトラワイド画面 + 3DoF（macOS / Apple Silicon）。

## 使い方
```sh
make cert   # 初回のみ：自己署名のコード署名証明書を作る（再ビルドしても画面収録の許可が残る）
make run    # ビルドして起動
```
- 初回起動時に「画面収録」を許可し、アプリを再起動する
- グラスは自動でミラー解除・1920×1080 @120Hz に設定され、終了すると元に戻る
- メニューバーのメガネアイコンから設定。⌃⌥R で正面に戻す
- Nebula for Mac とは同時に使えない（IMU を取り合う）
- ログ: `~/Library/Logs/AirUltrawide.log`
- IMU 単体の確認: `swift run AirUltrawide --imu-log`

## 仕組み
| ファイル | 役割 |
|---|---|
| `VirtualDisplay.swift` | 非公開 API `CGVirtualDisplay` で仮想ディスプレイを作成 |
| `ScreenCapture.swift` | ScreenCaptureKit で取り込み、IOSurface をゼロコピーで Metal テクスチャ化。変化があったときだけ届く |
| `AirHID.swift` / `IMUPacket.swift` | USB HID（interface 3）で IMU を ~1000Hz 受信（プロトコルは ar-drivers-rs を参照） |
| `OrientationFilter.swift` | Mahony 型相補フィルタ + 速度適応（微小な動きはゲイン 0、はっきりした首振りは 1:1） |
| `Renderer.swift` | 頭の yaw/pitch を平行移動、roll を回転として描画（ドット等倍）。止まっているときは整数ピクセル + 補間なし、変化がなければ描画しない |
| `GlassesDisplay.swift` | グラスのミラー解除・ネイティブ解像度・配置（`.forAppOnly`） |

Apple Developer Program なしで動かすため、App Store / 公証には対応しない。
