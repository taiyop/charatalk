# 第三者コード・モデル・素材のライセンス

確認日: 2026-10-20。この一覧は法的適合性の保証ではありません。

## 適用範囲

CharaTalkの独自コード・独自ドキュメントは [Apache-2.0](LICENSE) です。
第三者由来コードは元の条件を保持します。モデル重み、アバター、画像、
ユーザーの録音、外部サービスの規約は、このApache-2.0の適用対象ではありません。
以下の記載やライセンス文の同梱は、出所未確認の成果物の権利を補完しません。

## ソースコードと同梱ランタイム

| 部品・配置 | 条件・著作権 | 条文・確認状態 |
| --- | --- | --- |
| `Sources/IrodoriTTS`、`Packages/IrodoriSpeechCpp` の上流由来部分 | Corvelis/irodori-tts-iphone。Apache-2.0、Copyright 2026 StackChan Pet Talk contributors。部品別条件は下記 | [LICENSE](LICENSE)、上流表示を保持した [NOTICE](NOTICE) |
| Irodori由来実装 | MIT、Copyright (c) 2026 Aratako | [MIT.txt](LICENSES/MIT.txt) |
| ModernBERT Japanese関連 | MIT、Copyright (c) 2025 SB Intuitions | [ModernBERT-MIT.txt](LICENSES/ModernBERT-MIT.txt) |
| AudioSeal関連 | MIT、Copyright (c) Meta Platforms, Inc. and affiliates. | [AudioSeal-MIT.txt](LICENSES/AudioSeal-MIT.txt) |
| DACVAE由来部分 | Apache-2.0、Copyright (c) Meta Platforms, Inc. and affiliates. All Rights Reserved. | [LICENSE](LICENSE)、[NOTICE](NOTICE) |
| Descript Audio Codec由来部分 | MIT、Copyright (c) 2023-present, Descript | [Descript-MIT.txt](LICENSES/Descript-MIT.txt) |
| speech.cpp 0.8.10 | MIT、Copyright (c) 2026 Sakasegawa | [speech.cpp-MIT.txt](LICENSES/speech.cpp-MIT.txt)。revision `a72f1bbedd50e293d5b3f4c2bf0fb44ec003227d` |
| speech.cpp内ggml | MIT、Copyright (c) 2023-2026 The ggml authors | [ggml-MIT.txt](LICENSES/ggml-MIT.txt)。revision `a655cf6910770404213bc338e622cd82b08ca277` |
| ggml内YaRN由来コード | MIT、Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng | [YaRN-MIT.txt](LICENSES/YaRN-MIT.txt)。上流NOTICEに基づき保持 |
| llama.cpp / ggml / mtmdランタイム | 上流はMIT、Copyright (c) 2023-2026 The ggml authors | [llama.cpp-MIT.txt](LICENSES/llama.cpp-MIT.txt)。**同梱バイナリのrevision・全構成は未確認** |
| VRMKit / VRMKitRuntime / VRMRealityKit | 上流はMIT、Copyright (c) 2018 Tatsuya Tanaka | [VRMKit-MIT.txt](LICENSES/VRMKit-MIT.txt)。**同梱ソースの取り込みrevision・改変全体は未確認** |
| VRMKit内MoreCodable | MIT、Copyright (c) 2018 Tatsuya Tanaka | [MoreCodable-MIT.txt](LICENSES/MoreCodable-MIT.txt)。既存の原文も保持 |

ライセンス文の取得元・確認用snapshotは [LICENSES/README.md](LICENSES/README.md) に記載。
Irodori SDKは確認用revision `e316752e21bcba8b28532c5050ac3a4cc1b5d130` と比較しました。
これは実際の取り込みrevisionを確定したものではありません。変更した上流由来の
ソースには変更表示を追加しています。残る確認事項は本書の「公開前チェック」を参照してください。

未使用のCore ML版TTSエンジン／ネイティブターゲット、ReazonSpeechの認識ラッパー・モデル取得コード、
MToonシェーダー実装・metallib、AuthenticationServicesの直接依存は除外しました。
VRM/glTF内のMToon素材情報の読み取りとUnlit近似描画は保持します。
speech.cppの共有ランタイム自体はTTSに必要なため維持し、バイナリは変更していません。
ModernBERT・DACVAE・Descript由来部品は現行TTSにも関係し、AudioSealは音声透かしに使うため、
それらの条文と取得元のNOTICEは引き続き保持します。

## モデル・素材

- モデルは実行時に別途取得します。Irodori等のMIT／Apache-2.0と、LFM2.5の
  **商用利用制限を含むLFM Open License v1.0** は区別してください。
  本書の「モデル別の条件と固定revision」を参照してください。
- 同梱の標準モデルは `App/Resources/default_avatar.vrm`（**vrm_sample — taiyop**）です。
  [VRM Public License 1.0](https://vrm.dev/licenses/1.0/) と埋め込み設定が適用されます。
  **個人の非営利利用のみ**。再配布・改変は許可、クレジットは任意です。
  ライセンス上無保証です。元ファイルのメタデータを変更せず同梱します。
  商用利用等には別途許諾または別モデルが必要で、コードのApache-2.0はモデル条件を置き換えません。
- 標準モデルの埋め込み設定では、過度な暴力・性的表現、反社会／憎悪表現、政治・宗教用途は禁止です。
  使用した素材の権利確認まで完了したという意味ではありません。
- アイコン `App/Assets.xcassets/AppIcon.appiconset/AppIcon.png` の出所・権利は未確認です。
  Apache-2.0として扱わず、作成者・取得経路・適用条件を確認してください。
- 参照録音・インポートしたアバターの権利は提供者に帰属します。
  コードの許諾は、他人の声の模倣や録音の再配布を許諾しません。

### モデル別の条件と固定revision

モデル重みは通常、実行時に取得します。コードのライセンスと区別し、モデルだけを
再配布する場合にも元のLICENSE・NOTICE・変換／量子化の表示を添付してください。

| モデル・取得元 | 固定revision | 条件・用途 |
| --- | --- | --- |
| [Irodori TTS GGUF](https://huggingface.co/sakasegawa/Irodori-TTS-v4.1-Small-MF-GGUF) | `9db7da1bec3d1069ef8e29732e0497be60c7b047` | 音声合成。Irodoriと日本語Semantic-DACVAE追加部分はMIT、Meta DACVAE由来部分はApache-2.0 |
| [Core ML / AudioSeal](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML) | 標準版 `b02a670f0cb41c382844672fa8f0f03b3b9b8082`。INT8版は可変タグ `v0.2.0-int8` | 部品別にMIT／Apache-2.0。現行speech.cpp経路はTTS重み全体ではなくAudioSeal関連ファイルを取得。透かしOFFでも取得対象 |
| [LFM2.5-1.2B-JP GGUF](https://huggingface.co/LiquidAI/LFM2.5-1.2B-JP-GGUF) | `170ae1cecf0e74b0b25bd704047160fba9f613c6` | ローカル返答生成。[LFM Open License v1.0](LICENSES/LFM-Open-License-1.0.txt)。MIT／Apache-2.0ではない |

- Irodori元モデル: `Aratako/Irodori-TTS-v4.1-Small-MF` revision
  `ccc78f5d480b6e51b69b2d5042a14c4da04fea6e`、`Aratako/Semantic-DACVAE-Japanese-32dim`
  revision `47376ee24834d7a05a48ebabfe3cde29b3c5e214`。
- Core ML関連の元モデル: `sbintuitions/modernbert-ja-310m` revision
  `77675fc96a7e445e982e2ba90246b816efc74ec6`、`facebook/audioseal` revision
  `3c19eba53390776cf2cc9ed5f6c9ac67ce72ecba`。
- LFMには年間売上 **1,000万米ドル** を基準とする商用利用制限があります。
  対象はアプリ単独の売上とは限りません。原文の `Legal Entity`、`Threshold`、第5条を確認し、
  必要ならLiquid AIとの別契約または別モデルを選択してください。
- Irodori元モデルの使用条件も確認してください。同意のない声のクローン・なりすまし、
  人を欺くディープフェイクや誤情報目的の利用は避け、生成物の責任は利用者が負います。
  これらの上流条件はMIT条文そのものとは区別します。
- AudioSeal取得元の帰属・変換表示は [CoreML-NOTICE.txt](LICENSES/CoreML-NOTICE.txt) に保持しています。

## サービス・開発環境

OpenAI API、ChatGPTサインイン、Gemini、Hugging Face、任意のOpenAI互換APIには
各サービスの規約が別途適用されます。OSS化してもAPI利用やプラン利用の権限は増えません。

- OpenAI: [Services Agreement](https://openai.com/policies/services-agreement/)、
  [ChatGPTサインインのOSS向け資料](https://developers.openai.com/siwc/token-sharing-open-source)、
  [UI/UXガイドライン](https://developers.openai.com/siwc/ui-ux-guidelines) を確認してください。
  有料・リモート提供アプリは別途問い合わせ対象です。認証情報を共有・公開しないでください。
- Gemini: [追加利用規約](https://ai.google.dev/gemini-api/terms) を確認してください。
  年齢・地域・提供形態の制限や、課金の有無によるデータ取扱いの違いに注意し、
  無料サービスに機密・個人情報を送信しないでください。
- [Hugging Face規約](https://huggingface.co/terms-of-service) はホスティングの条件であり、
  各モデルの許諾とは別です。OpenAI互換APIには接続先事業者の規約も適用されます。

AppleのSDK／OSフレームワークはAppleの契約条件に従います。SDK自体をこの
リポジトリで再配布するものではありません。Core ML変換に使われるPython、
PyTorch、ONNX、coremltools等の環境も同梱していません。変換環境を別途配布する場合は
その時点の依存ライセンスを改めて確認してください。

`SileroVADDetector` は現状RMS等を使う独自実装です。Sileroのモデル／重みは同梱していません。
新たにSilero本体を導入する場合は、そのライセンス確認を追加してください。

## 再配布する方へ

この一覧・LICENSE・NOTICE・該当するLICENSESの条文を配布物と一緒に保持してください。
MITの著作権表示・許諾文、Apache-2.0の再配布・変更表示・NOTICEの条件を守ってください。
リンクだけでは、条文のコピーが必要な場合の代わりになりません。
アプリ内のライセンス画面はありません。ルートのLICENSE・NOTICE・本一覧・LICENSESの条文等を
配布リソースとして保持します。`docs/` はGit管理・配布の対象外であり、本書はそれに依存しません。
パッケージやxcframeworkのみを切り出して配る場合も、該当する条文・帰属表示を添付してください。
未確認項目は出所を特定して条件を満たすか、許諾済みのものに差し替えてから公開・配布してください。

## 公開前チェック

- [ ] llama同梱バイナリの生成commit・構成・追加依存・パッチを特定し、条文と照合する。
- [ ] 残るVRMKitソースの取り込みrevision・改変履歴・条件を確認する（MToonシェーダー／metallibは除外済み）。
- [ ] vrm_sampleの使用素材・権利を作者に確認する。商用等は別途許諾または別モデルを用意する。
- [ ] アイコン等の作成者・取得経路・権利を確認し、許諾を記録するか差し替える。
- [ ] 上流取り込み・改変履歴・変更表示を最終確認する。比較snapshotは取り込み履歴の確定ではない。
- [ ] Core ML INT8版を使う場合はタグをcommitに固定し、部品別の条件を再確認する。
- [ ] モデルの原本LICENSE・NOTICE・変換／量子化表示と、LFMの売上条件を配布形態ごとに確認する。
- [ ] 各配布物の帰属表示、秘密情報・個人情報、外部サービス規約、Appleの配布条件を確認する。

未確認の成果物は、表示の追加だけで許諾済みにはなりません。
