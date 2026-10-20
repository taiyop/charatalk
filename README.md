# CharaTalk (iOS)

独自コード: **[Apache License 2.0](LICENSE)** · [第三者ライセンス・モデル・素材の条件](THIRD_PARTY_NOTICES.md) · [各ライブラリの用途](LICENSES/README.md)

> 第三者コード・モデル・アバター・画像には、それぞれの条件が適用されます。
> LFM2.5には商用利用制限があります。出所・権利が未確認のバイナリ・シェーダー・画像もあるため、
> 公開・再配布前に [第三者ライセンス文書の公開前チェック](THIRD_PARTY_NOTICES.md#公開前チェック) を確認してください。

**CharaTalk** は、iPhone 上で動作する 3D AI キャラクター対話アプリです。
[Corvelis/irodori-tts-iphone](https://github.com/Corvelis/irodori-tts-iphone) を参考に、`speech.cpp` (Metal) による **Irodori TTS v4.1 Small MF** のオンデバイス音声合成、**RealityKit / VRMKit** による VRM 3D キャラクター描画と音声連動クチパク（リップシンク）、および **ローカルLLM / ChatGPT / Gemini / OpenAI互換API** によるテキスト対話を実現しています。

---

## ✨ 主な特徴

1. **オンデバイス音声合成 (Irodori TTS v4.1 Small MF)**
   - `speech.cpp` と Apple Metal を用いた高品質・低遅延なオンデバイス音声合成
   - アプリ内からワンタップで公式 GGUF モデル（約 1.9 GB）をダウンロード・検証
   - 話し方指定（Caption）や話者シード値（Seed）のカスタマイズに対応

2. **VRM 3Dキャラクター & リアルタイム・クチパク (Lip Sync)**
   - Apple の最新 **RealityKit** (iOS 18+) と **VRMKit** による高品位な 3D アバター描画 (MToon シェーダー対応)
   - 音声再生の波形・音量（RMS）をリアルタイム解析し、自然で滑らかに口（`aa` ブレンドシェイプ）を開閉
   - アイドリング時の自然な自動まばたき（Blink）
    - `App/Resources/default_avatar.vrm`（モデル名: `vrm_sample`）をデフォルトアバターとして同梱。さらにファイルピッカーからユーザー好みの `.vrm` ファイルをインポート可能（各モデルの利用条件に従ってください）
    - **vrm_sample — taiyop** / [VRM Public License 1.0](https://vrm.dev/licenses/1.0/)。**個人の非営利利用のみ**。再配布・改変は許可、クレジットは任意です。本モデルは同ライセンスに基づき無保証で提供されます。埋め込みライセンス設定を変更せず保持しています。
    - 旧モデル **Seed-san — VirtualCast, Inc.** はアプリへ同梱しません。履歴として[VRM Public License 1.0](https://vrm.dev/licenses/1.0/) に基づく帰属表示を保持します。

3. **選べる LLM 対話エンジン**
   - ローカルLFM、ChatGPTサインイン、Gemini API、OpenAI互換APIを切り替え可能
   - GeminiのAPIキー・モデル・推論Effortを個別に設定でき、モデル一覧の取得にも対応
   - OpenAI (GPT-4o, GPT-4o-mini 等) はもちろん、Ollama、Groq、vLLM、OpenRouter など OpenAI 互換のあらゆる API エンドポイントに接続可能
   - アプリ内の設定画面で **API Endpoint**、**API Key**、**モデル名**、**システムプロンプト (キャラクター性格)** を自由に設定可能

---

## 📱 動作要件

- **開発環境**: macOS (Apple Silicon 推奨), Xcode 16.0 以上, XcodeGen
- **実行環境**: iOS 18.0 以上の iPhone 実機（※speech.cpp による Metal 音声合成推論は実機で動作します）

---

## 🚀 クイックスタート

### 1. プロジェクトを開く
```bash
open CharaTalk.xcodeproj
```
※プロジェクトファイルを再生成したい場合は `xcodegen generate` を実行してください。

### 2. Signing の設定
1. Xcode でプロジェクト上部のターゲット **CharaTalk** を選択します。
2. **Signing & Capabilities** タブを開きます。
3. **Automatically manage signing** にチェックを入れ、自身の Apple Developer **Team** を選択し、一意の **Bundle Identifier** を設定します。

### 3. iPhone 実機で実行
1. iPhone を Mac に接続し、開発者モードを有効にします。
2. 実行先デバイスに対象の iPhone を選択し、**Run (⌘R)** を押してビルド・インストールします。

---

## 💬 アプリの使い方

1. **初期設定 (右上の歯車アイコン)**:
    - **LLM設定**:
      - `Sign in with ChatGPT` を選ぶ場合: サインイン後、アカウントで利用可能なモデル一覧を自動取得します。表示名からモデルを選択し、候補を再取得する場合は「一覧を更新」を押してください。
      - 保存済みの ChatGPT モデルが一覧にない場合は、サーバーが返した一覧の先頭を使用します。取得失敗時に古い固定候補へ切り替えることはありません。
      - 「自動」は一覧の先頭を使用します。保存済みの選択は、モデルを明示的に選び直した場合にだけ変更されます。
      - ChatGPTの `推論 Effort`: 自動（モデル既定）/ none / minimal / low / medium / high / xhigh / max を選択できます。高い値ほど時間・利用量が増える場合があります。対応する値はモデルごとに異なり、非対応エラー時は「自動」に戻してください。OpenAI互換APIには適用されません。
      - 会話は Responses API のストリームを完了まで受信してから表示・読み上げます。認証エラー時は一度だけトークンを更新し、別APIへの切り替えは行いません。401 が続く場合は「利用権限を再認証」で ChatGPT プランの利用を許可してください。
      - エラーには安全な HTTP ステータス・エラーコード・request ID を表示し、生のサーバー応答は表示しません。会話画面のエラー文は選択してコピーできます。
      - `Gemini (APIキー)` を選ぶ場合: [Google AI Studio](https://aistudio.google.com/apikey)で発行したAPIキーを入力し、取得したモデル一覧から使用モデルを選びます。「一覧を更新」で再取得でき、モデルIDの直接入力も可能です。APIキー・モデル・EffortはChatGPT/OpenAI互換APIとは別に保存されます。
      - Geminiの `推論 Effort`: 自動 / minimal / low / medium / high のうちモデルに対応した候補を表示します。Gemini 2.5ではlow / medium / highをそれぞれ推論トークン量1,024 / 8,192 / 24,576に変換し、Gemini 3以降ではThinking Levelとして指定します。モデル変更時に非対応のEffortは自動に戻します。会話内容はGoogleに送信され、API利用料金が発生する場合があります。
      - `API Endpoint`: 接続先 URL（例: `https://api.openai.com/v1/chat/completions`）
     - `API Key`: お手持ちの API キー
     - `モデル名`: 例 `gpt-4o-mini`
     - `システムプロンプト`: キャラクターの口調や性格
   - **Irodori TTS設定**:
     - 「**モデルを取得 (約1.9 GB)**」ボタンをタップすると、バックグラウンドでモデル一式がダウンロードされます（Wi-Fi 推奨）。
     - 話し方（例: 「落ち着いた、やさしい話し方。」）やシード値を変更可能。
     - 「声・話し方」の「音声合成方式」で「文ごと」（初期値）と「全文まとめて」を選択でき、設定は保存されます。どちらも `speech.cpp` を使用します。
      - 「文ごと」は最初の1文が合成できた時点で再生し、再生中に続く文を最大2文先読みします。次の文の合成が追いつかない場合だけ文間で待ちます。「全文まとめて」は複数文を含む応答全体を1回で合成・再生します。全文モードは再生開始まで時間がかかり、長文でモデル上限に達する場合は「文ごと」に切り替えてください。
       - 字幕は音声の再生開始に合わせて表示します。準備中も履歴では全文を確認でき、停止・音声エラー時には字幕にも本文を表示します。
       - AIの返答待ち中に停止・会話リセットした場合、その後に届いた古い返答やエラーは反映せず、読み上げも開始しません。
       - 再生準備・開始・停止・音量解析は専用キューで実行し、画面更新を妨げないようにしています。
      - 合成音声の前後にある余分な無音は、語頭・語尾の余韻と短い文間の間を残して短縮します。文の途中の間は変更しません。端末の処理が再生に追いつかない場合は、先読み中でも後続文の合成待ちが発生することがあります。
   - **VRMモデル**:
     - 好みの `.vrm` ファイルを取り込むか、デフォルトモデルを選択。
2. **会話を始める**:
   - 画面下部の入力欄にテキストを入力して送信ボタンを押します。
   - AI キャラクターが思考し、Irodori TTS で生成された音声とともに口をパクパク動かしてお話しします！

---

## ライセンスと再配布

CharaTalkの独自コード・独自ドキュメントはApache License 2.0で提供します。
第三者のコード・モデル重み・アバター・画像・録音は一括して再ライセンスしません。
[LICENSE](LICENSE)、[NOTICE](NOTICE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、
[LICENSES](LICENSES/README.md) を保持し、各部品の条件に従ってください。
アプリ内のライセンス画面は設けていません。`docs/` はGit管理・配布の対象外です。
必要な条件は上記の管理対象文書に記載し、再配布に必要なルートのLICENSE・NOTICE・第三者条文等を同梱します。

Apache-2.0に基づく独自コードの利用に、モデルの売上制限を追加するものではありません。
モデルを利用・配布する場合の条件、声の使用許諾、外部APIの契約条件は別途確認が必要です。
未確認の権利について許諾済みとは主張しません。

## 📂 プロジェクト構成

会話中のカクつき・読み上げの間・返答待ちの計測方法は
[テスト文書の実機計測](Tests/README.md#device-profiling)を参照してください。

```
charatalk/
├── App/
│   ├── CharaTalkApp.swift             # アプリ起動エントリーポイント
│   ├── Resources/
│   │   └── default_avatar.vrm         # デフォルトVRMアバター（vrm_sample）
│   ├── Models/
│   │   ├── ChatMessage.swift          # チャットメッセージモデル
│   │   ├── SpeechSubtitleState.swift  # 発話開始に合わせる字幕の表示状態
│   │   └── AppSettings.swift          # LLM・TTS・VRMの永続化設定
│   ├── Services/
│   │   ├── LLMClient.swift            # OpenAI互換APIクライアント
│   │   ├── SpeechTTSManager.swift     # IrodoriSpeechCpp (speech.cpp) 管理マネージャー
│   │   ├── AudioSpeechPlayer.swift    # 音声再生 & リアルタイム音量解析 (クチパク連動)
│   │   └── VRMCharacterController.swift # RealityKit VRM描画・表情・まばたき制御
│   ├── Views/
│   │   ├── ContentView.swift          # メイン統合ビュー
│   │   ├── VRMRealityView.swift       # 3Dアバター描画ビュー
│   │   ├── ChatOverlayView.swift      # チャット字幕 & テキスト入力オーバーレイ
│   │   └── SettingsView.swift         # 設定画面 (LLM, TTS, VRM)
│   ├── ViewModels/
│   │   └── ConversationViewModel.swift # 対話フロー全体の状態管理
│   └── Info.plist                     # iOSアプリ設定
├── Packages/
│   ├── IrodoriSpeechCpp/              # speech.cpp (Metal) Swift SDK & xcframework
│   └── VRMKit/                        # VRMKit & VRMRealityKit パッケージ
├── Sources/
│   ├── IrodoriTTS/                    # Irodori TTS 共通コンポーネント
│   └── IrodoriNative/                 # C++ / Objective-C++ ブリッジ
├── Package.swift                      # IrodoriTTS パッケージ定義
├── project.yml                        # XcodeGen 定義ファイル
└── CharaTalk.xcodeproj                # Xcode プロジェクト
```
