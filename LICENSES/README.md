# ライセンス全文の取得元と各部品の用途

確認日: 2026-10-20。MIT各ファイルは著作権表示を含む原文です。
Apache-2.0全文はルートの [LICENSE](../LICENSE) を共用します。
コピーの改行コード・末尾改行は正規化しています。これらのコピーは、未確認の
同梱バイナリ・素材の由来を確定したり、新たな許諾を与えたりするものではありません。

| ファイル | 取得元 |
| --- | --- |
| `../LICENSE` | [Apache Software Foundation標準条文](https://www.apache.org/licenses/LICENSE-2.0.txt) |
| `MIT.txt` | [Irodori SDK / Aratakoの表示](https://github.com/Corvelis/irodori-tts-iphone/blob/e316752e21bcba8b28532c5050ac3a4cc1b5d130/LICENSES/MIT.txt) |
| `ModernBERT-MIT.txt` | [Irodori SDK / SB Intuitionsの表示](https://github.com/Corvelis/irodori-tts-iphone/blob/e316752e21bcba8b28532c5050ac3a4cc1b5d130/LICENSES/ModernBERT-MIT.txt) |
| `AudioSeal-MIT.txt` | [Irodori SDK / Metaの表示](https://github.com/Corvelis/irodori-tts-iphone/blob/e316752e21bcba8b28532c5050ac3a4cc1b5d130/LICENSES/AudioSeal-MIT.txt) |
| `Descript-MIT.txt` | [Irodori SDK / Descriptの表示](https://github.com/Corvelis/irodori-tts-iphone/blob/e316752e21bcba8b28532c5050ac3a4cc1b5d130/LICENSES/Descript-MIT.txt) |
| `speech.cpp-MIT.txt`、`ggml-MIT.txt`、`YaRN-MIT.txt` | [Irodori SDK内の同名条文](https://github.com/Corvelis/irodori-tts-iphone/tree/e316752e21bcba8b28532c5050ac3a4cc1b5d130/Packages/IrodoriSpeechCpp/LICENSES)。既存のパッケージ内コピーも保持 |
| `VRMKit-MIT.txt` | [VRMKit確認用snapshot](https://github.com/tattn/VRMKit/blob/6543973e6103d9cdea74a9323ed2d42c8bd03686/LICENSE)。同梱コードの取り込みrevisionではない |
| `MoreCodable-MIT.txt` | `Packages/VRMKit/Sources/VRMKit/Extensions/MoreCodable/LICENSE` の既存原文コピー |
| `llama.cpp-MIT.txt` | [llama.cpp確認用snapshot](https://github.com/ggml-org/llama.cpp/blob/7879491cf4c1cfb25acbd78fae34a9e7a8e3a062/LICENSE)。同梱バイナリの生成revisionではない |
| `LFM-Open-License-1.0.txt` | [使用モデルの固定revisionのLICENSE](https://huggingface.co/LiquidAI/LFM2.5-1.2B-JP-GGUF/blob/170ae1cecf0e74b0b25bd704047160fba9f613c6/LICENSE) |
| `CoreML-NOTICE.txt` | [AudioSeal取得元の固定revisionのNOTICE](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/blob/b02a670f0cb41c382844672fa8f0f03b3b9b8082/NOTICE) を原文保持 |

上流Irodori SDKのNOTICEは [ルートNOTICE](../NOTICE) の区切り以降に原文を保持しています。
VRMモデルのライセンスは全文またはURIの表示が認められるため、
[第三者表示のモデル・素材欄](../THIRD_PARTY_NOTICES.md#モデル素材) とアプリから [原文](https://vrm.dev/licenses/1.0/) へリンクします。

モデルや依存を更新するときは、使用するrevisionの条文・著作権表示・NOTICEを再確認し、
この一覧と配布物に同梱する条文・NOTICEを同時に更新してください。権利確認待ち項目は
[第三者表示の公開前チェック](../THIRD_PARTY_NOTICES.md#公開前チェック) で追跡します。

## 各ライブラリ・モデルの使用箇所と目的

`LICENSES/` の各条文・NOTICEに対応する部品を以下に示します。
独立したライブラリだけでなく、モデル内部の部品、間接依存、取得元の帰属表示も含みます。
「モデル内部」はSwiftからそのライブラリのAPIを直接呼ぶのではなく、
Irodoriなどの推論処理を通じて利用することを意味します。

| 部品（対応するファイル） | どこで使うか | 何のために使うか・利用条件 |
| --- | --- | --- |
| **Irodori-TTS**（[MIT.txt](MIT.txt)） | アプリの [SpeechTTSManager.swift](../App/Services/SpeechTTSManager.swift) → [SpeechCppEngine.swift](../Packages/IrodoriSpeechCpp/Sources/IrodoriSpeechCpp/SpeechCppEngine.swift)。モデル取得は [SpeechCppModelBundle.swift](../Packages/IrodoriSpeechCpp/Sources/IrodoriSpeechCpp/SpeechCppModelBundle.swift) | AIの返答テキストをキャラクターの音声に変換する。話し方指定・参照録音による話者指定を扱い、48 kHzのPCM音声を生成する。現行の会話ではIrodori v4.1 Small MFのGGUFモデルをspeech.cppで実行する。旧Core ML経路の [IrodoriEngine.swift](../Sources/IrodoriTTS/IrodoriEngine.swift) もリポジトリに残る。 |
| **ModernBERT Japanese**（[ModernBERT-MIT.txt](ModernBERT-MIT.txt)） | Irodoriのテキストエンコーダー由来部品。現行の呼び出し口は上記 `SpeechCppEngine.swift`。旧Core ML経路では [IrodoriLocalBridge.mm](../Sources/IrodoriNative/IrodoriLocalBridge.mm) の `text_encoder` 実行箇所 | 読み上げ本文や「落ち着いた話し方」などの指示を、音声生成に渡す特徴表現へ変換する。会話の返答を考えるLLMではなく、TTSモデル側の部品。独立したModernBERT用Swiftライブラリを呼んでいるわけではない。 |
| **AudioSeal**（[AudioSeal-MIT.txt](AudioSeal-MIT.txt)） | [AudioWatermark.swift](../Sources/IrodoriTTS/AudioWatermark.swift)、[SpeechCppEngine.swift](../Packages/IrodoriSpeechCpp/Sources/IrodoriSpeechCpp/SpeechCppEngine.swift)。設定は [SettingsView.swift](../App/Views/SettingsView.swift) の「音声透かし」 | 合成音声に識別用の電子透かしを付与する。アプリでは設定ON時に適用し、初期値はOFF。SDKには透かし検出処理もあるが、アプリの会話画面からは呼び出していない。生成・検出モデルのファイルは設定OFFでもモデル取得時にダウンロードする。 |
| **Descript Audio Codec由来部分**（[Descript-MIT.txt](Descript-MIT.txt)） | Irodoriの音声コーデック／DACVAE由来部品。現行は `SpeechCppEngine.swift` → [IrodoriSpeechBridge.mm](../Packages/IrodoriSpeechCpp/Sources/IrodoriSpeechNative/IrodoriSpeechBridge.mm) のTTS実行を通じて利用。旧Core ML経路のデコーダー実行は `IrodoriLocalBridge.mm` | 音声の圧縮された内部表現と波形を扱うための基盤。特に生成した音声潜在表現を、再生できるPCM波形に戻す処理に関係する。独立したDescriptアプリやSDKへの接続ではない。Meta DACVAE由来部分のApache-2.0とは区別する。 |
| **speech.cpp**（[speech.cpp-MIT.txt](speech.cpp-MIT.txt)） | [IrodoriSpeechCpp/Package.swift](../Packages/IrodoriSpeechCpp/Package.swift) の `SpeechCpp.xcframework.zip`、[IrodoriSpeechBridge.mm](../Packages/IrodoriSpeechCpp/Sources/IrodoriSpeechNative/IrodoriSpeechBridge.mm) | Irodori GGUFモデルを読み込み、iPhoneのMetal GPUで音声合成を実行するランタイム。SwiftとC/C++推論処理を橋渡しする。パッケージには [ReazonSpeechBridge.mm](../Packages/IrodoriSpeechCpp/Sources/IrodoriSpeechNative/ReazonSpeechBridge.mm) による音声認識機能もあるが、現在のアプリのマイク認識はAppleのSpeechフレームワークを使う。 |
| **ggml**（[ggml-MIT.txt](ggml-MIT.txt)） | speech.cpp内部の依存。組み込み設定は [build-runtime.sh](../Packages/IrodoriSpeechCpp/Scripts/build-runtime.sh)。ローカルLLMのllama.cppランタイムにもggml由来部品が含まれる | ニューラルネットワークのテンソル演算、量子化された重みの処理、Metalでの演算を支える。アプリから直接APIを呼ぶのではなく、speech.cpp／llama.cpp経由で使う。両ランタイムのggmlが同じrevisionであることは意味しない。 |
| **YaRN由来コード**（[YaRN-MIT.txt](YaRN-MIT.txt)） | speech.cppに組み込まれるggml由来コードの帰属表示。パッケージ内にも [同名条文](../Packages/IrodoriSpeechCpp/LICENSES/YaRN-MIT.txt) を保持 | Transformerの位置表現（RoPE）のスケーリング・長いコンテキストへの対応に関する由来コード。アプリ独立の機能や直接依存ではない。条文の保持は、現在のIrodori推論でYaRN方式を有効化していることを示すものではない。 |
| **llama.cpp**（[llama.cpp-MIT.txt](llama.cpp-MIT.txt)） | [LocalLLMManager.swift](../App/Services/LocalLLMManager.swift) → [LlamaCppEngine.swift](../Packages/LlamaCpp/Sources/LlamaCpp/LlamaCppEngine.swift) → [LlamaCppBridge.mm](../Packages/LlamaCpp/Sources/LlamaCppNative/LlamaCppBridge.mm)。バイナリは [LlamaCpp/Package.swift](../Packages/LlamaCpp/Package.swift) | LFM2.5のGGUFモデルを端末内で実行し、会話履歴・システムプロンプトから返答文を生成する。LLM設定でローカルLFMを選んだ場合に使う。ChatGPT・Gemini・OpenAI互換APIの通信には使用しない。同梱バイナリの生成revision・全構成は未確認。 |
| **VRMKit / VRMKitRuntime / VRMRealityKit**（[VRMKit-MIT.txt](VRMKit-MIT.txt)） | [Packages/VRMKit](../Packages/VRMKit)、アプリの [VRMCharacterController.swift](../App/Services/VRMCharacterController.swift) | VRM/glTFモデルの読み込み、ボーン・表情・視線などの実行時制御、RealityKit上の3Dキャラクター表示に使う。アプリの待機モーション、瞬き、音声連動の口の開閉をモデルへ反映する。ライブラリのMITはアバター素材そのものの利用許諾ではない。 |
| **MoreCodable**（[MoreCodable-MIT.txt](MoreCodable-MIT.txt)） | [AnyCodingKey.swift](../Packages/VRMKit/Sources/VRMKit/Extensions/MoreCodable/AnyCodingKey.swift)。呼び出し元は [VRM1.swift](../Packages/VRMKit/Sources/VRMKit/VRM/VRM1.swift) の `Humanoid.HumanBones` | 動的な文字列をSwiftの `CodingKey` として扱う小さな補助コード。VRM 1.0の `hips`、`head` など、ボーン名をキーにしたJSONを読み書きする。MoreCodable全体を外部パッケージとして導入しているわけではない。 |
| **LFM2.5-1.2B-JP**（[LFM-Open-License-1.0.txt](LFM-Open-License-1.0.txt)） | [LFM2ModelBundle.swift](../Packages/LlamaCpp/Sources/LlamaCpp/LFM2ModelBundle.swift) でモデル取得、[LocalLLMManager.swift](../App/Services/LocalLLMManager.swift) で実行。[LLMClient.swift](../App/Services/LLMClient.swift) の `.localLFM` 分岐から利用 | ローカル会話の日本語の返答文を生成するモデル重み。上記llama.cppは実行エンジン、こちらはそのエンジンで動かすモデル。実行時に別途ダウンロードし、ローカルLLM選択時に使用する。MITではなく商用利用制限を含むLFM Open Licenseが適用される。 |
| **Irodori Core ML変換・DACVAE等の帰属表示**（[CoreML-NOTICE.txt](CoreML-NOTICE.txt)） | 取得元の複合モデル一式に関するNOTICE。関連実装は [IrodoriEngine.swift](../Sources/IrodoriTTS/IrodoriEngine.swift)、[IrodoriLocalBridge.mm](../Sources/IrodoriNative/IrodoriLocalBridge.mm)、[AudioWatermark.swift](../Sources/IrodoriTTS/AudioWatermark.swift) | 単独のライブラリ名ではなく、Irodori・ModernBERT・DACVAE・Descript・AudioSealの帰属とCore ML変換の変更を記録したもの。DACVAEは参照音声の符号化や合成結果の波形復元に関係する。現行の会話はCore ML版TTS全体ではなくspeech.cpp版を使い、Core MLモデルはAudioSeal用に取得・使用する。 |

### 現在のアプリでの役割のまとめ

- **返答文の生成（ローカル選択時）**: LFM2.5モデルをllama.cppで実行する。
- **返答文の読み上げ**: Irodoriモデルをspeech.cppで実行する。ModernBERTや
  DACVAE／Descript由来部品は、その音声合成モデル側の構成要素。
- **合成音声への透かし（設定ON時）**: AudioSealをCore MLで実行する。
- **3Dキャラクターの表示・制御**: VRMKit系を使い、MoreCodableはそのJSON処理を補助する。
- **推論演算の下支え**: ggmlをランタイム経由で利用する。YaRNはその由来コードの表示であり、
  アプリが長文コンテキスト拡張を有効にしているという意味ではない。

この一覧は使用箇所の説明であり、バイナリの全構成・出所の確認完了や法的適合性を保証しません。
VRMRealityKitのMToonシェーダーなどの未確認事項は
[第三者表示の公開前チェック](../THIRD_PARTY_NOTICES.md#公開前チェック)、
モデル固有の条件は同文書の [モデル別の条件と固定revision](../THIRD_PARTY_NOTICES.md#モデル別の条件と固定revision) を参照してください。
