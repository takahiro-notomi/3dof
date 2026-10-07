# AirUltrawide

XREAL Air 2 を **5120×1440 の仮想ウルトラワイド画面** として使える macOS アプリです。頭の向き（3DoF）に合わせて画面が空間に固定されて見えます。

- 5120×1440 の仮想ディスプレイを作り、グラスにはその一部をドット等倍で表示
- 首を振るとその方向が見える（yaw / pitch / roll に追従）
- 手ぶれ程度の小さな揺れは抑え、止まっているときはくっきり表示
- メニューバーに常駐。正面に戻すショートカット ⌃⌥R

## 動作環境

| | |
|---|---|
| Mac | Apple Silicon（M1 以降） |
| macOS | 15 Sequoia 以降 |
| グラス | XREAL Air 2（Air / Air 2 Pro も IMU は認識しますが未検証） |

> [!NOTE]
> XREAL 公式の Nebula for Mac とは同時に使えません（どちらもグラスのセンサーを使うため）。先に Nebula を終了してください。

## インストール

1. [Releases](https://github.com/takahiro-notomi/3dof/releases/latest) から `AirUltrawide-x.x.zip` をダウンロードして展開
2. `AirUltrawide.app` を「アプリケーション」フォルダに移動
3. 開く。Apple の公証を受けていないため、初回は「開けません」と表示されます。次のどちらかで許可してください
   - **システム設定 → プライバシーとセキュリティ** の下の方にある「このまま開く」を押す
   - または ターミナルで次を実行してから開く
     ```sh
     xattr -dr com.apple.quarantine /Applications/AirUltrawide.app
     ```
4. 「画面収録」の許可を求められたら許可し、**アプリを一度終了して開き直す**

## 使い方

1. グラスを Mac に USB-C でつなぐ
2. AirUltrawide を起動すると、グラスは自動で拡張表示（1920×1080 @120Hz）に切り替わります。終了すると元に戻ります
3. 起動直後の 2 秒ほどはジャイロの較正中です。**グラスを机に置くなどして動かさないで**ください
4. Mac 側には 5120×1440 のディスプレイが追加されます。そこにウィンドウを並べて使います

メニューバーのメガネアイコンからできること：

| 項目 | 内容 |
|---|---|
| 正面に戻す（⌃⌥R） | 今向いている方向を画面の中心にする |
| ジャイロを再キャリブレーション | 画面がじわじわ流れるときに。静止させて実行 |
| 表示倍率 | グラスに映す範囲の拡大率 |
| 追従の滑らかさ | 手ぶれをどれだけ抑えるか |
| 止まっているときはピクセル固定 | 静止中は補間なしでくっきり表示 |
| 首の傾き（ロール）にも追従 | 首をかしげたときに画面を回転させるか |
| ウルトラワイドをメインディスプレイにする | メニューバーや Dock を仮想画面側に出す |

## うまく動かないとき

- **画面が真っ黒**：システム設定 → プライバシーとセキュリティ → 画面収録 で AirUltrawide がオンになっているか確認し、アプリを開き直す
- **頭を動かしても画面が動かない**：Nebula for Mac が起動していないか確認。グラスを挿し直す
- **画面がゆっくり流れていく**：メニューから「ジャイロを再キャリブレーション」（グラスを静止させて）
- ログ：`~/Library/Logs/AirUltrawide.log`

## ソースからビルド

Xcode（または Command Line Tools）の Swift 6 が必要です。

```sh
git clone https://github.com/takahiro-notomi/3dof.git
cd 3dof
make cert   # 初回のみ：自己署名証明書を作る（再ビルドしても画面収録の許可が残る）
make run    # ビルドして起動
```

| コマンド | 内容 |
|---|---|
| `make app` | `AirUltrawide.app` を作る |
| `make run` | 作って起動 |
| `make dist` | 配布用 zip を `dist/` に作る（ad-hoc 署名） |
| `swift run AirUltrawide --imu-log` | IMU の値だけを表示して確認 |

### 仕組み

| ファイル | 役割 |
|---|---|
| `VirtualDisplay.swift` | 非公開 API `CGVirtualDisplay` で仮想ディスプレイを作成 |
| `ScreenCapture.swift` | ScreenCaptureKit で取り込み、IOSurface をゼロコピーで Metal テクスチャ化。変化があったときだけ届く |
| `AirHID.swift` / `IMUPacket.swift` | USB HID（interface 3）で IMU を ~1000Hz 受信（プロトコルは [ar-drivers-rs](https://github.com/badicsalex/ar-drivers-rs) を参照） |
| `OrientationFilter.swift` | Mahony 型相補フィルタ + 速度適応（微小な動きはゲイン 0、はっきりした首振りは 1:1）。静止中はジャイロのバイアスを追従 |
| `Renderer.swift` | 頭の yaw/pitch を平行移動、roll を回転として描画（ドット等倍）。止まっているときは整数ピクセル + 補間なし、変化がなければ描画しない |
| `GlassesDisplay.swift` | グラスのミラー解除・ネイティブ解像度・配置（`.forAppOnly`） |

Apple Developer Program なしで作っているため、App Store 配布・公証には対応していません。

## 免責

XREAL 社とは関係のない非公式アプリです。macOS の非公開 API を使っているため、macOS のアップデートで動かなくなる可能性があります。
