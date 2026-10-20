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
   - アプリ内からワンタップで公式 GGUF モデルをダウンロード・検証（標準Q6_KはAudioSeal関連ファイル込み約1.13 GB）
   - 話し方指定（Caption）や話者シード値（Seed）のカスタマイズに対応

2. **VRM 3Dキャラクター & リアルタイム・クチパク (Lip Sync)**
   - Apple の **RealityKit** (iOS 18+) と **VRMKit** による3Dアバター描画（Unlit/PBR。MToon素材はUnlitで近似描画）
   - 音声再生の波形・音量（RMS）をリアルタイム解析し、自然で滑らかに口（`aa` ブレンドシェイプ）を開閉
   - アイドリング時の自然な自動まばたき（Blink）
    - `App/Resources/default_avatar.vrm`（モデル名: `vrm_sample`）をデフォルトアバターとして同梱。さらにファイルピッカーからユーザー好みの `.vrm` ファイルをインポート可能（各モデルの利用条件に従ってください）
    - **vrm_sample — taiyop** / [VRM Public License 1.0](https://vrm.dev/licenses/1.0/)。**個人の非営利利用のみ**。再配布・改変は許可、クレジットは任意です。本モデルは同ライセンスに基づき無保証で提供されます。埋め込みライセンス設定を変更せず保持しています。

3. **選べる LLM 対話エンジン**
   - ローカルLFM、ChatGPTサインイン、Gemini API、OpenAI互換APIを切り替え可能
   - GeminiのAPIキー・モデル・推論Effortを個別に設定でき、モデル一覧の取得にも対応
   - OpenAI (GPT-4o, GPT-4o-mini 等) はもちろん、Ollama、Groq、vLLM、OpenRouter など OpenAI 互換のあらゆる API エンドポイントに接続可能
   - アプリ内の設定画面で **API Endpoint**、**API Key**、**モデル名**、**システムプロンプト (キャラクター性格)** を自由に設定可能

---

## 📱 動作要件

- **開発環境**: macOS (Apple Silicon 推奨), Xcode 16.0 以上, XcodeGen
- **実行環境**: iOS 18.0 以上の iPhone 実機（※speech.cpp による Metal 音声合成推論は実機で動作します）

### 推奨環境：全ローカルと外部LLM API

**全ローカルはRAM 8 GB以上、LLMだけを外部APIにする場合はRAM 6 GB以上を推奨します。**
これはモデル構成からの推奨であり、実機で確認した最低動作条件ではありません。
両構成とも、音声合成・VRM描画・リップシンクはiPhone側で動作します。
「全ローカル」はローカルLLM＋TTS＋VRMを指し、すべての量子化モデルを同時にロードする意味ではありません。

| 項目 | 全ローカル構成 | LLMを外部APIで利用する構成 |
| --- | --- | --- |
| 推奨端末 | **RAM 8 GB以上・A17 Pro以降**。例：iPhone 15 Pro / Pro Max、iPhone 16シリーズ | **RAM 6 GB以上・A15 Bionic以降**。例：iPhone 13 Pro / Pro Max、iPhone 14。余裕を重視するならRAM 8 GB以上 |
| LLM | LFM2.5-1.2B-JP **Q4_K_M**（標準設定） | ChatGPT / Gemini / OpenAI互換API。ローカルLLMの取得・ロードは不要 |
| 音声合成 | Irodori TTS **Q6_K**（標準設定）、**文ごと** | 同左。メモリ優先なら **Q4_K** |
| アプリ全体のメモリ設計予算 | **3〜4 GB程度の余裕を見込む** | **2〜3 GB程度の余裕を見込む** |
| モデルの保存容量 | 約 **1.87 GB**（LLM＋TTS＋AudioSeal関連ファイル） | 約 **1.13 GB**（TTS＋AudioSeal関連ファイル）。TTS Q4_Kなら約 **0.96 GB** |
| 初回取得前の推奨空きストレージ | **5 GB以上** | **3 GB以上** |
| 通信 | モデルの初回取得に必要。音声認識のオフライン動作は下記参照 | 初回取得に加え、会話時に安定したWi-Fi / モバイル通信が必要。APIの利用権限・料金・送信データの扱いを確認 |

**設計予算はiPhone上の使用メモリ実測値でも、確保量・上限の保証でもありません。**
下記のモデル参考値に、VRM・テクスチャ・Metal/Core ML・音声処理・UI等の未計測分を見込んだ計画用の目安です。
大きなVRM、長文、透かし有効時などは上回る可能性があります。
端末の搭載RAM全量を1アプリが使えるわけではなく、iOSのメモリ制限や他アプリの状態により強制終了する場合もあります。
RAM 4 GB端末は推奨対象外です。試す場合は外部LLM API＋TTS Q4_K＋軽量VRMから始め、実機でピークを確認してください。
上記の空きストレージはアプリ本体・一時ファイル等の余裕込みの目安で、複数量子化版の保存には追加容量が必要です。

### 使用メモリの根拠と注意点

以下は**RAMの参考値**です。モデルファイルの保存容量とは異なります（GBは十進表記）。

| 部品 | 量子化 | モデルファイル容量 | メモリ参考値 | 数値の位置づけ |
| --- | --- | --- | --- | --- |
| ローカルLLM | Q4_0 | 約0.70 GB | 約0.85 GB | アプリ内の概算表示。実機計測の裏付けなし |
| ローカルLLM | **Q4_K_M** | 約0.73 GB | **約0.90 GB** | 同上 |
| ローカルLLM | Q6_K | 約0.96 GB | 約1.15 GB | 同上 |
| ローカルLLM | Q8_0 | 約1.25 GB | 約1.45 GB | 同上 |
| TTS | Q4_K | 約0.86 GB | 約0.99 GB | 上流のApple M5 / Metalでの単発CLIプロセスのピーク |
| TTS | **Q6_K** | 約1.04 GB | **約1.16〜1.17 GB** | 同上。上流1.16 GB、アプリ内表示1.17 GB |
| TTS | Q8_0 | 約1.21 GB | 約1.33 GB | 同上 |
| TTS | F16 | 約1.92 GB | 約2.04 GB | 同上 |

出典：実装の [LLMモデル定義](Packages/LlamaCpp/Sources/LlamaCpp/LFM2ModelBundle.swift)、
[TTSモデル定義](Packages/IrodoriSpeechCpp/Sources/IrodoriSpeechCpp/SpeechCppModelBundle.swift)、
[固定revisionのTTSベンチマーク](https://huggingface.co/sakasegawa/Irodori-TTS-v4.1-Small-MF-GGUF/blob/9db7da1bec3d1069ef8e29732e0497be60c7b047/README.md#accuracy)。
**TTS値はiPhoneアプリ全体の計測ではありません。LLMの概算値と単純加算してアプリの実測ピークとは扱えません。**

- **両モデルは同時にメモリへ残ります。** LLM推論と音声合成は順番でも、次の会話に備えたモデル保持があるため、必要RAMは大きい方のモデルだけでは済みません。
  各モデルは約120秒の未使用後に解放されますが、推論中・合成中にメモリ警告が来ても即座に解放できるとは限りません。
  ローカルLLMからAPIへ切り替えた直後もLLMが残る場合があるため、構成比較の計測はアプリを再起動して行ってください。
- **外部APIにしてもTTSの約1 GB級の負荷は残ります。** 外部モデルの重み・KVキャッシュはサーバー側へ移りますが、端末側のVRM・音声合成はなくなりません。
- **AudioSealは別枠です。** 関連ファイル約0.09 GBは透かしOFFでも取得します。透かしONで生成器をロードするとCore MLの追加メモリが必要ですが、その実機使用量は未計測です。上の推奨表は透かしOFFを基準としています。
- **VRMのファイル容量≠描画時のRAMです。** 標準VRMは約16 MBですが、展開後のテクスチャ・メッシュ等に追加メモリを使います。
  アプリはテクスチャを最大1024 pxへ縮小しますが、テクスチャ枚数・ポリゴン数の多いカスタムVRMは負荷を増やします。
- **長文も負荷を増やします。** ローカルLLMのコンテキストは4,096トークンで、履歴を自動で切り詰める実装はありません。長い会話では履歴リセットが必要になる場合があります。
  音声は「文ごと」を推奨します。「全文まとめて」は生成音声や作業バッファが大きくなり、モデルの入力上限にも達する場合があります。
- **完全オフラインの音声入力は保証しません。** iOS 26以降では対応する端末内音声認識アセットが利用可能なら使用しますが、フォールバック先のApple Speechは通信が必要な場合があります。
  全ローカルのLLM・TTSを選んでも、音声入力のオフライン可否は別に確認してください。

#### 実機でのメモリ確認

iPhone上の総ピークは未計測です。実機のReleaseビルドでXcodeのMemoryゲージとInstrumentsのAllocations / VM Trackerを使い、
起動直後・LLM推論中・TTS開始時・連続会話中のメモリを確認してください。
Metalの使用量も確認し、同じ領域を二重加算しないようにします。
端末・OS・量子化・VRM・透かし設定を記録し、透かしON、長めの返答、数分間の連続会話、モデル切り替えも試してください。
メモリ不足で終了する場合は、外部LLM APIへの切り替え → TTS Q4_K → 軽量VRMの順で負荷を下げるのが目安です。
処理速度・発熱・音声の文間待ちについては [実機計測手順](Tests/README.md#device-profiling) も参照してください。

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
     - 選択した量子化の「**モデルを取得**」ボタンからモデル一式をダウンロードします（Wi-Fi 推奨）。標準Q6_KはAudioSeal関連ファイル込み約1.13 GB、F16は約2.01 GBです。
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
未使用の旧Core ML版TTS、ReazonSpeech認識ラッパー、MToonシェーダー／metallib、
AuthenticationServicesの直接依存は除外済みです。Core MLはAudioSealの音声透かし用に残しています。

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
│   ├── IrodoriSpeechCpp/              # speech.cpp (Metal) TTS SDK & xcframework
│   ├── LlamaCpp/                      # ローカルLLM SDK & xcframework
│   └── VRMKit/                        # VRMKit & VRMRealityKit パッケージ
├── Sources/
│   └── IrodoriTTS/                    # 音声共通型・再生・モデル取得・AudioSeal
├── Package.swift                      # IrodoriTTS パッケージ定義
├── project.yml                        # XcodeGen 定義ファイル
└── CharaTalk.xcodeproj                # Xcode プロジェクト
```
