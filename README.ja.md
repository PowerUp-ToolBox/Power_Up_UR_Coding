# PowerUp — DualSense で Claude Code を操るリモコン

[English](README.md) | [简体中文](README.zh-CN.md) | **日本語**

PowerUp は PS5 の DualSense コントローラーを
[Claude Code](https://www.anthropic.com/claude-code) の手元リモコンに変えます。
トリガーを押しながら指示を話せば、Claude の返答は読み上げで返ってきます。
変更の承認、ターンの中断、直前の返答の再読み上げ、定型プロンプトの送信など——
コントローラーのどのボタンにも、ワークフローに合わせて好きな操作を割り当て
られます。送信前に文面を確認したい？ もう一方のトリガーを押しながらプロンプト
欄へ音声入力し、編集して、納得できたら送信すればOK。コントローラーのライトバー
とハプティクスが Claude セッションの状態を映すので、いま待機中か、聞き取り中か、
思考中か、読み上げ中かはひと目で分かります。

SwiftUI 製のネイティブ macOS アプリです。ビルドに Xcode プロジェクトは
不要——Swift Package Manager だけで完結します。

> 注：以下のリンク先ドキュメントは現在すべて英語です。この翻訳と
> [英語版 README](README.md) に食い違いがある場合は英語版が正です。

## その先にあるもの

いまある姿——macOS、DualSense、Claude Code——は、ずっと大きなオープンソース
構想の **v1** にすぎません。ゲームパッド、ヘッドセットのボタン、フットペダル、
マクロパッド、音声だけ——**どんなデバイス**からでも、Claude Code、Codex CLI、
Gemini CLI、opencode などの**どの AI コーディングハーネス**でも、macOS・
Windows・Linux の**どの OS**でも、誰でもハンズフリーでバイブコーディング
できるようにする。しかもデバイス側のライト・ハプティクス・画面が、エージェント
のいまの動きをリアルタイムに知らせてくれる——それがゴールです。

全体計画は **[DEVELOPMENT.md](DEVELOPMENT.md)**、参加のしかたは
**[CONTRIBUTING.md](CONTRIBUTING.md)** へ。コントリビューション、対応デバイス
の提案、対応ハーネスのリクエスト、どれも歓迎です。issue か discussion を
立ててください。

## クイックスタート

```sh
./scripts/build.sh        # リリースビルド → build/PowerUp.app
open build/PowerUp.app    # 必ず .app バンドルとして起動する（macOS の権限は
                          # バンドルの同一性に紐づくため）
```

必要なもの：macOS 14 以上、ログイン済みの `claude` CLI、Bluetooth で
ペアリングした DualSense、Xcode Command Line Tools。初回起動時にマイクと
音声認識の許可を与え、プロジェクトフォルダを選んでください。詳しくは
**[はじめに](docs/getting-started.md)** をどうぞ。

## 基本の 3 ボタン

コントローラーをペアリングしたら、3 つのボタンだけで Claude との会話ループが
一通り回ります。

- **L2 — プロンプト欄へ音声入力。** 押しながら話して離すと、話した内容が
  プロンプト欄に入り、確認できます。この時点ではまだ送信されません。
- **L1 — プロンプト欄を送信。** 欄に入っているもの（手入力・音声入力・その
  両方）を、その場ですぐ Claude へ送ります。
- **R2 — Claude に直接話す。** 押しながら話して離すと、離した瞬間に文字起こし
  が送信されます。確認ステップはありません。

そのほかの操作——承認（✕）、中断（○）、十字キーのクイックプロンプト、
スティックとタッチパッドでのモデル／思考の深さ／権限モードの切り替え——は
すべてこのループの上に載っていて、どのボタンも **Settings → Buttons** で
割り当て直せます。デフォルト割り当ての全一覧は
**[ボタンと操作](docs/controls.md)** にあります。

## ドキュメント

| ガイド | 内容 |
|---|---|
| [はじめに](docs/getting-started.md) | 動作要件、ビルド、初回起動、権限 |
| [ボタンと操作](docs/controls.md) | デフォルト割り当ての全一覧、音声入力→確認→送信、モデル／思考の深さ／権限モードの切り替え、中断 |
| [音声と読み上げ](docs/voice.md) | 多言語読み上げ、より良い声への切り替え、読み上げ長の上限 |
| [ハーネス](docs/harnesses.md) | Claude Code 以外のエージェント（opencode ほか ACP エージェント）の操作、ボタンによるツール承認 |
| [リモートコントロールモード](docs/remote-control.md) | cmux やターミナルの既存セッションの操作、hooks の設定、アクセシビリティと安定した署名 |
| [設定とセッション](docs/configuration.md) | 設定、`config.json`、セッション再開、コスト表示 |
| [トラブルシューティング](docs/troubleshooting.md) | 権限のリセット、コントローラー、`claude` バイナリの問題 |
| [プライバシー](docs/privacy.md) | 音声とデータの行き先（ネタバレ：ほぼどこにも行きません） |
| [PowerUp プロトコル](docs/protocol.md) | ローカル WebSocket API を使った独自デバイスプラグイン／UI の開発 |

コントリビューター向け：[CONTRIBUTING.md](CONTRIBUTING.md)（ビルド/テスト/PR
のルール）、[DESIGN.md](DESIGN.md)（拘束力のある実装契約）、
[DEVELOPMENT.md](DEVELOPMENT.md)（ロードマップ、アーキテクチャ、
ワークストリーム）。
