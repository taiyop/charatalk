# License documents and distribution packaging

These checks do not certify legal compliance or resolve the provenance items in
[the release checklist](../THIRD_PARTY_NOTICES.md#公開前チェック). They guard the verified wording, upstream attribution,
model revisions, avatar metadata, local document links and build resource lists.
Python uses only the standard library and makes no network calls:

```sh
python3 Tests/LicensePackagingTests.py
```

Legal documents stay in their current repository locations. `docs/` is ignored
by Git; neither these tests nor the app depend on it. The app has no
license-document screen. Root LICENSE, NOTICE,
THIRD_PARTY_NOTICES.md and LICENSES remain bundled for redistribution notices.
After building, verify those resources are byte-identical to their source,
the repository-only documents are not bundled, and the default VRM is unchanged:

```sh
python3 Tests/LicensePackagingTests.py --app-bundle "/path/to/CharaTalk.app"
```

Default avatar check: clean install with no custom avatar → `vrm_sample` loads;
import a custom VRM → it still takes priority; `デフォルトモデルに戻す` →
`vrm_sample` loads again. Check framing, blink and lip sync on a device.
`App/Resources/default_avatar.vrm` contains the renamed but otherwise unchanged
vrm_sample model; old Seed-san is not bundled.

## Device log / UI responsiveness check

- Open settings → voice settings repeatedly: the microphone label should render
  with `mic.fill`, without a missing-system-symbol warning (iOS 18 or later).
- During initial VRM loading, custom VRM import and resetting the default, check
  that the loading indicator animates and UI controls remain responsive. File
  reads, VRM parsing and atomic import writes run off MainActor; RealityKit
  entity creation remains on MainActor. Check large files on a real iPhone too.
- `Built scene ... cutout coverage ...` is an informational VRMKit timing log,
  not a load failure; its total duration is not the main-thread blocking time.
- `usermanagerd` XPC invalidation and LaunchServices `-54` originate in system
  services. These messages alone do not establish an app failure. If file
  selection or another operation actually fails, record the iOS version, exact
  operation and app-visible error. Do not suppress all OS logs or add private
  entitlements to hide them. A gesture-gate timeout still needs device profiling
  if it recurs after the blocking file work has been moved off MainActor.

# ChatGPTOAuth regression tests

Standalone test harness for `App/Services/ChatGPTOAuth.swift`. It has no
XCTest dependency, no test target, and makes no network or authentication
calls. Every check throws on failure, so the tests stay active in release
builds (unlike `assert`).

## Run

From the repository root:

```sh
(
set -eu
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-oauth-tests.XXXXXX")"
trap 'rm -f "$BIN_DIR/chatgpt-oauth-tests"; rmdir "$BIN_DIR"' EXIT
swiftc -swift-version 6 \
  App/Services/ChatGPTOAuth.swift \
  Tests/ChatGPTOAuthTests.swift \
  -o "$BIN_DIR/chatgpt-oauth-tests"

"$BIN_DIR/chatgpt-oauth-tests"
)
```

The executable prints one `PASS`/`FAIL` line per test and exits `0` when all
tests pass, `1` otherwise. A compilation failure also exits nonzero. The
subshell keeps the command from exiting your interactive shell.

`TMPDIR` is set to a per-user temporary directory on macOS; `${TMPDIR:-/tmp}`
keeps the command portable. Only the harness binary inside `BIN_DIR` is
removed, followed by `rmdir` on the now-empty directory — nothing else in the
temporary directory is touched.

## Coverage

Form encoding (`formEncodedBody`):

- keys are emitted in sorted order and spaces become `%20`, not `+`
- reserved characters (`& = % # ? / +`) and Unicode keys/values round-trip
  through a server-style decoder that treats `+` as a space
- a literal `+` in a value survives as `+` rather than being decoded as a space

Authorization request (`AuthorizationAttempt.tokenParameters`):

- `resource` is always `https://api.openai.com/v1`; the request also retains the
  exact redirect URI, original client ID, and code verifier
- the dynamic-registration bootstrap client ID requires a non-empty issued
  client ID and rejects the bootstrap ID being echoed back
- a non-bootstrap client ID is retained when the callback omits `client_id`,
  accepted when it matches, and rejected when it differs
- `state` must match exactly (case, prefix, suffix, whitespace), duplicate
  `state` is rejected, including on error callbacks
- callbacks with the wrong host, path, or port (including a missing port) are
  rejected
- missing or empty `code` is rejected
- duplicate `code`, `client_id`, `error`, or `error_description` is rejected
- an `error` callback never produces token parameters, and its raw values are
  not surfaced

Token exchange errors (`tokenExchangeError`):

- `invalid_grant` is actionable (expiry/retained-client/retry guidance)
- `invalid_client` points at the advanced-settings OAuth Client ID
- nested `error.code` objects are understood
- unknown codes and non-JSON bodies fall back to a generic HTTP-status message
  without leaking the raw response or `error_description`

# ChatGPT model catalog regression tests

Standalone harness for `App/Models/ChatGPTModel.swift`. Like the OAuth harness
it has no XCTest dependency, no test target, and makes no real authentication
or network calls: `URLProtocol` returns canned responses for the catalog
endpoint.

## Run

From the repository root:

```sh
(
set -eu
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-model-tests.XXXXXX")"
trap 'rm -f "$BIN_DIR/tests"; rmdir "$BIN_DIR"' EXIT
swiftc -swift-version 6 \
  App/Models/ChatGPTModel.swift \
  Tests/ChatGPTModelCatalogTests.swift \
  -o "$BIN_DIR/tests"

"$BIN_DIR/tests"
)
```

The executable prints one `PASS`/`FAIL` line per test and exits `0` when all
tests pass, `1` otherwise. A compilation failure also exits nonzero. Only the
harness binary inside `BIN_DIR` is removed, followed by `rmdir` on the
now-empty directory.

## Coverage

Catalog decoding (`ChatGPTModelCatalog.decode`):

- only `visibility == "list"` entries are kept, in server order
- `display_name` is displayed, with the slug used when it is absent, empty, or
  whitespace
- missing visibility, hidden models, empty/missing slugs, and duplicates
  (first occurrence wins) are skipped
- the official `{ "models": [...] }` envelope is required; the API-key
  `{ "object": "list", "data": [...] }` shape, invalid JSON, and wrong field
  types fail with `invalidResponse`
- empty catalogs return `[]`, and no model is invented locally

Model selection (`ChatGPTModelCatalog.selectedSlug`):

- an exact preferred slug present in the catalog is retained (surrounding
  whitespace is trimmed)
- a stale/invalid preference falls back to the first server-provided slug
- an empty catalog returns `nil`; there is no hardcoded fallback model

Catalog fetch (`ChatGPTModelCatalog.fetch`):

- sends `GET https://api.openai.com/v1/models` with
  `Authorization: Bearer <token>` and decodes the response
- empty catalogs are supported
- 401, 403, 429, 5xx, and other statuses map to actionable Japanese errors
  without exposing the response body
- success responses in the API-key shape or with malformed JSON fail with
  `invalidResponse`
- transport errors are propagated unchanged

OAuth token recovery also covers exact granted-scope matching, optional token
response fields, rotating refresh tokens, terminal refresh error classification,
and safe errors that preserve credentials on transient failures.

# ChatGPT inference transport regression tests

Standalone harness for `App/Services/ChatGPTInference.swift`. It has no XCTest
dependency and no test target. `MockURLProtocol` serves every request, including
chunked SSE streams, so the tests never touch the real network or authenticate.

## Run

From the repository root:

```sh
(
set -eu
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-inference-tests.XXXXXX")"
trap 'rm -f "$BIN_DIR/tests"; rmdir "$BIN_DIR"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
  App/Services/ChatGPTInference.swift \
  Tests/ChatGPTInferenceTests.swift \
  -o "$BIN_DIR/tests"

"$BIN_DIR/tests"
)
```

The executable prints one `PASS`/`FAIL` line per test and exits `0` when all
tests pass, `1` otherwise. A compilation failure also exits nonzero. Only the
harness binary inside `BIN_DIR` is removed, followed by `rmdir` on the now-empty
directory.

## Coverage

Reasoning effort (`ChatGPTReasoningEffort`):

- raw values are exactly `""`, `none`, `minimal`, `low`, `medium`, `high`,
  `xhigh`, `max`; IDs are non-empty and unique
- labels are Japanese but keep the API name recognizable; `.automatic` is
  described as automatic rather than as an empty value

Request construction (`ChatGPTInference.send`):

- sends `POST https://api.openai.com/v1/responses` with
  `Authorization: Bearer <token>`, JSON content type, and an SSE accept header
- body contains the selected model, `input` messages, `store: false`,
  `stream: true`, and `instructions` only when the system prompt is non-blank
- `temperature` is never present
- model names are trimmed, empty names fail before networking, and system-role
  history items are converted to developer-role items for this route
- every non-automatic effort is sent as `reasoning.effort`; `.automatic` omits
  the entire `reasoning` object

SSE success handling:

- CRLF/LF, comments, unknown events, multi-line `data:`, Unicode text, and a
  final event without a trailing blank line are handled
- bare CR delimiters and Unicode split across byte-sized chunks are supported;
  events are dispatched at SSE boundaries rather than as soon as JSON parses
- text is returned from the completed event's `output_text`/`output_text`
  content, with accumulated `response.output_text.delta` text as the fallback
- reasoning deltas and `reasoning` output items never reach the returned reply
- a completed event without any text fails instead of returning an empty reply

Terminal and interrupted streams:

- `response.failed` after deltas throws and never returns partial text
- `response.incomplete`, explicit `error` events (top-level and nested), and a
  completed event whose status is not `completed` throw
- a stream that ends after deltas, a bare `[DONE]`, or comments only throws
- a malformed terminal event fails with `invalidResponse`
- transport failures before or during the stream produce a typed transport error

HTTP failures and metadata:

- 401, 403, 429, 5xx, and other statuses map to actionable Japanese messages
- 401 mentions sign-in and ChatGPT plan permission, 403 policy/permission, 429
  links to `https://chatgpt.com/settings/usage`, and 5xx asks to retry later
- 400 with an effort/reasoning parameter suggests `.automatic` or another effort
- documented `subscription_sharing_*` and `chatpass_v2_*` codes are recognized
- status, request ID, `error.code`, and `error.param` are retained only after
  ASCII-identifier/size sanitization
- safe diagnostics are visible in the error text; stream failures retain the
  HTTP response's request ID when the event does not supply one
- standard `{ "error": ... }`, nonstandard `{ "detail": ... }`, and non-JSON
  bodies never expose raw message/detail/body text

401 refresh:

- a pre-stream 401 calls the supplied refresh hook once, forwards the rejected
  token, and retries with the replacement token and an identical payload
  (including the effort)
- a second 401 is final and does not refresh again
- 403, 429, 5xx, and failures after the stream starts do not refresh
- a refresh error propagates without a retry; a blank replacement token is
  rejected before a second request

# TTS synthesis mode regression tests

Standalone harness for `App/Models/TTSSynthesisMode.swift` and
`SentenceSplitter.chunks(text:mode:)` in `App/Services/SentenceSplitter.swift`.
It has no XCTest dependency and no test target.

`SentenceSplitter` imports `IrodoriTTS`, so the harness compiles the real
`Sources/IrodoriTTS/SpeechText.swift` (Foundation only) into a temporary
`IrodoriTTS` module and links against it. Markdown sanitizing is therefore
exercised through the production implementation rather than a mock.

## Run

From the repository root:

```sh
(
set -eu
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/speech-synthesis-tests.XXXXXX")"
trap 'rm -f "$BIN_DIR/tests" "$BIN_DIR/libIrodoriTTS.dylib" "$BIN_DIR/IrodoriTTS.swiftmodule" "$BIN_DIR/IrodoriTTS.swiftdoc" "$BIN_DIR/IrodoriTTS.swiftsourceinfo" "$BIN_DIR/IrodoriTTS.abi.json"; rmdir "$BIN_DIR"' EXIT
swiftc -swift-version 6 \
  -emit-module -emit-library -module-name IrodoriTTS \
  Sources/IrodoriTTS/SpeechText.swift \
  -emit-module-path "$BIN_DIR/IrodoriTTS.swiftmodule" \
  -o "$BIN_DIR/libIrodoriTTS.dylib"
swiftc -swift-version 6 -warnings-as-errors \
  -I "$BIN_DIR" -L "$BIN_DIR" -lIrodoriTTS \
  App/Models/TTSSynthesisMode.swift \
  App/Services/SentenceSplitter.swift \
  Tests/SpeechSynthesisTests.swift \
  -o "$BIN_DIR/tests"

DYLD_LIBRARY_PATH="$BIN_DIR" "$BIN_DIR/tests"
)
```

The executable prints one `PASS`/`FAIL` line per test and exits `0` when all
tests pass, `1` otherwise. A compilation failure also exits nonzero.
`DYLD_LIBRARY_PATH` is scoped to the test process so the temporary
`libIrodoriTTS.dylib` is found at runtime. `BIN_DIR` is created by `mktemp`;
the `trap` removes only the named temporary module/build artifacts, then removes
the empty directory.

## Coverage

Whole-response mode (`chunks(text:mode:)` with `.wholeResponse`):

- Japanese multi-sentence text returns exactly one chunk and keeps every
  `。`/`？`/`！`
- English multi-sentence text returns exactly one chunk and keeps
  `.`/`?`/`!`, including `.` which the per-sentence splitter does not split on
- internal newlines, including blank lines, are preserved; only leading and
  trailing whitespace is trimmed
- Markdown headings keep their text and drop `#`; links keep the label and
  drop the URL; fenced code blocks are removed while surrounding text remains;
  inline code keeps its content and drops the backticks; a combined fixture is
  handled in one chunk
- empty, whitespace-only, punctuation-only, symbol-only, emoji-only,
  heading-only, and code-block-only input returns `[]`
- emoji mixed with speakable text still produces one chunk
- a long response (>600 characters, 180 numbered sentences plus a comma-heavy
  sentence) stays one chunk with character-for-character equality: no split,
  no truncation, and no lost prefix/suffix/newlines
- single sentences (Japanese/English, with and without punctuation) stay one
  chunk

Per-sentence mode (`chunks(text:mode:)` with `.perSentence`):

- output is identical to the existing `SentenceSplitter.split(text:)` for
  Japanese, English, newline, Markdown, long, short, bold, comma-heavy, and
  unspeakable fixtures
- the existing 70-character fallback splitting behavior is retained

Synthesis mode (`TTSSynthesisMode`):

- `allCases` contains exactly `perSentence` and `wholeResponse` in declaration
  order
- `rawValue` round-trips through `init(rawValue:)`; unknown, empty,
  hyphenated, and wrong-case raw values return `nil`
- `id` and `displayName` are non-empty, unique across cases, stable, and free
  of leading/trailing whitespace
- `Sendable` is exercised through a generic constraint, and `Identifiable` /
  `CaseIterable` are exercised through `id` and `allCases`

`AppSettings` persistence is intentionally out of scope here because it depends
on SwiftUI.

# Speech playback buffering and PCM regression tests

Foundation-only standalone harnesses for `Sources/IrodoriTTS/SpeechPCM.swift`,
`Sources/IrodoriTTS/SpeechPlaybackPipeline.swift`, and
`Sources/IrodoriTTS/SpeechPlaybackSession.swift` / `SpeechPlaybackProgress.swift`.
No audio hardware, model download,
or XCTest target is needed.

```sh
(
set -eu
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/speech-playback-tests.XXXXXX")"
trap 'rm -f "$BIN_DIR/pcm-tests" "$BIN_DIR/pipeline-tests" "$BIN_DIR/session-tests" "$BIN_DIR/progress-tests"; rmdir "$BIN_DIR"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
  Sources/IrodoriTTS/SpeechPCM.swift Tests/SpeechPCMTests.swift \
  -o "$BIN_DIR/pcm-tests"
swiftc -swift-version 6 -warnings-as-errors \
  Sources/IrodoriTTS/SpeechPlaybackPipeline.swift Tests/SpeechPlaybackPipelineTests.swift \
  -o "$BIN_DIR/pipeline-tests"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  Sources/IrodoriTTS/SpeechPlaybackSession.swift Tests/SpeechPlaybackSessionTests.swift \
  -o "$BIN_DIR/session-tests"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  Sources/IrodoriTTS/SpeechPlaybackProgress.swift Tests/SpeechPlaybackProgressTests.swift \
  -o "$BIN_DIR/progress-tests"
"$BIN_DIR/pcm-tests"
"$BIN_DIR/pipeline-tests"
"$BIN_DIR/session-tests"
"$BIN_DIR/progress-tests"
)
```

Add `-O` to each `swiftc` command to check optimized builds too; checks throw
instead of using assertions that disappear in release builds.

PCM coverage: excess leading/trailing padding, bounded silence between two
segments, unchanged internal pauses and original speech samples, preserved soft
onsets/decays, quiet/noisy/silent input, malformed data, partial blocks, full
PCM16 range, and sliced `Data` with nonzero indices. The synthesis manager trims
during preparation, not at the playback boundary.

Buffering coverage: first completed chunk before first playback (the first chunk
plays while the second is still synthesizing), single/empty responses, serial
synthesis and playback, ordered bounded two-chunk lookahead, late synthesis at a
playback boundary, failure propagation, and cancellation of outstanding
preparation. Gates control timing without relying on device synthesis speed.
Real-device listening is still needed to assess voice quality and pauses under
load.

The optional pipeline timing observer also covers per-index event order,
nonnegative monotonic durations, zero waits for chunks already buffered,
measured waits for a chunk that is still synthesizing, and no successful
completion events on failure/cancellation.

Playback-session coverage uses a controllable fake backend: normal completion,
main-actor responsiveness while setup is pending, exact error propagation,
cancellation before/during setup and playback, request replacement, duplicate or
late completion callbacks, stale metering events, synchronous backend callbacks,
and delayed old cancellation handlers that must not stop a newer request.
The real AVAudioPlayer backend is typechecked by the iOS app build; audio quality,
route changes, hardware start latency, and queue timing still require an iPhone.
On device, confirm `audio_setup_on_main_thread` is `0` and compare
`reply_to_first_audio`, `playback_buffer_wait`, `Audio prepare to play`, and
`Audio player start` with the earlier logs.
Progress-fallback coverage includes premature stop vs natural completion,
`currentTime` resetting at the end, 0.5x/2x playback rates, invalid clock/settings,
and short audio that ends within one metering tick. Delegate failure verdicts
take priority over the fallback in the AV backend.

# Speech subtitle synchronization

Foundation-only tests for the production subtitle state and playback-session
events. No audio device, model, network, or XCTest target is required.

```sh
(
set -eu
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/speech-subtitle-tests.XXXXXX")"
trap 'rm -f "$BIN_DIR/subtitle-tests"; rmdir "$BIN_DIR"' EXIT
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  App/Models/ChatMessage.swift App/Models/SpeechSubtitleState.swift \
  Sources/IrodoriTTS/SpeechPlaybackSession.swift \
  Tests/SpeechSubtitleTests.swift -o "$BIN_DIR/subtitle-tests"
"$BIN_DIR/subtitle-tests"
)
```

Coverage: pending subtitles remain hidden while history retains the reply;
only playback `.started` reveals the subtitle (not enqueue or metering);
failure, completion, and stop reveal text even without speech; stale callbacks
and deferred cleanup cannot reveal a newer reply. The tests drive the real
state and playback session with a mock backend, not the full SwiftUI view model.

Manual device checks (both `文ごと` and `全文まとめて`):

- During thinking/synthesis, the subtitle stays hidden and the input area uses
  only a shimmer (text input) or spinner (voice session), with no status text or
  provider names. History still contains the complete reply.
- Microphone preparation uses a spinner, listening uses breathing dots/waveforms,
  and voice playback uses an animated waveform, without visible status labels.
  Live recognized speech, reply subtitles, and errors remain readable. VoiceOver
  still describes the current state and the switch-to-text action.
- The subtitle and speaking state appear together when playback begins.
- Stop during synthesis: the reply becomes visible immediately and no late
  callback changes the next reply's subtitle.
- Stop, enable the mic, or reset while the LLM is still thinking: a late reply
  must not join the history or start speech, and a late error must not change
  the next turn's UI.
- Missing model or synthesis/playback failure: the reply remains readable with
  an error, rather than staying hidden.
- A two-sentence reply in per-sentence mode starts after the first synthesis,
  without waiting for the second; slow synthesis may still cause a boundary gap.
- Whole-response mode still performs one synthesis and waits for it to finish.

The start event means the audio player accepted playback, not measured acoustic
output. Bluetooth/output latency and voice quality still need real-device checks.

# Conversation turn lifecycle

This harness compiles the **real `ConversationViewModel`**, subtitle state,
splitter, diagnostics, and playback pipeline. App services are replaced by
explicitly gated test doubles; no provider requests, audio, or microphone access
occurs. Run on macOS (SwiftUI/AVFoundation are required):

```sh
(
set -eu
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/conversation-turn-tests.XXXXXX")"
trap 'rm -f "$BIN_DIR/tests" "$BIN_DIR/libIrodoriTTS.dylib" "$BIN_DIR/IrodoriTTS.swiftmodule" "$BIN_DIR/IrodoriTTS.swiftdoc" "$BIN_DIR/IrodoriTTS.swiftsourceinfo" "$BIN_DIR/IrodoriTTS.abi.json"; rmdir "$BIN_DIR"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
  -emit-module -emit-library -module-name IrodoriTTS \
  Sources/IrodoriTTS/SpeechPlaybackPipeline.swift \
  Sources/IrodoriTTS/SpeechText.swift \
  -emit-module-path "$BIN_DIR/IrodoriTTS.swiftmodule" \
  -o "$BIN_DIR/libIrodoriTTS.dylib"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -I "$BIN_DIR" -L "$BIN_DIR" -lIrodoriTTS \
  App/ViewModels/ConversationViewModel.swift \
  App/Models/ChatMessage.swift App/Models/SpeechSubtitleState.swift \
  App/Models/TTSSynthesisMode.swift App/Services/SentenceSplitter.swift \
  App/Services/ConversationPerformance.swift \
  Tests/ConversationTurnTestDoubles.swift Tests/ConversationTurnTests.swift \
  -o "$BIN_DIR/tests"
DYLD_LIBRARY_PATH="$BIN_DIR" "$BIN_DIR/tests"
)
```

Add `-O` to both compiler invocations for optimized checks. Coverage includes
late LLM replies/errors after stop, reset or mic activation; stale replies and
audio callbacks during a newer turn; actual playback-start subtitle reveal
independent of the public busy flag; and callbacks after natural completion.
The test doubles replace App services only, not the view model's lifecycle logic.

# VRM update pacing and conversation diagnostics

Standalone production-helper tests (no GPU, network, or device required):

```sh
(
set -eu
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/conversation-performance-tests.XXXXXX")"
trap 'rm -f "$BIN_DIR/pacing-tests" "$BIN_DIR/performance-tests"; rmdir "$BIN_DIR"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
  Packages/VRMKit/Sources/VRMKitRuntime/VRMUpdatePacer.swift \
  Tests/VRMUpdatePacingTests.swift -o "$BIN_DIR/pacing-tests"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  App/Services/ConversationPerformance.swift \
  Sources/IrodoriTTS/SpeechPlaybackPipeline.swift \
  Tests/ConversationPerformanceTests.swift -o "$BIN_DIR/performance-tests"
"$BIN_DIR/pacing-tests"
"$BIN_DIR/performance-tests"
)
```

Add `-O` to both compiler commands for optimized checks. Pacing tests exercise
60/120 Hz displays, jitter, variable refresh rates, 30/60 Hz target switches,
elapsed-time conservation, disabled throttling, invalid deltas, and long hitches
without catch-up bursts. Diagnostics tests check task-local turn/chunk correlation
across actor hops and actual pipeline tasks, scope restoration, and unchanged
results/errors with instrumentation. Device-only profiling is described below.

## Device profiling

Use a Release build on a real iPhone. In Xcode's console, filter for
`ConversationPerformance` or `turn=`; in Console or Instruments, use subsystem
`com.aituber.charatalk`, category `ConversationPerformance`. A random `turn` ID
correlates each conversation, and zero-based `chunk` identifies each sentence
(`-1` means the whole turn). Prompts, replies and credentials are not logged.

Compare short one-sentence and five-sentence replies, both immediately and after
two minutes idle. Record model, Effort, TTS settings and playback speed. Compare
the built-in speaker with the usual output device. Use Time Profiler / Animation
Hitches and Points of Interest to correlate UI hitches with synthesis.

| Metric | Interpretation |
| --- | --- |
| `LLM response` | Full reply wait, including network, inference and token refresh |
| `turn_to_first_audio` / `reply_to_first_audio` | Wait from turn start / reply completion to accepted first playback |
| `chunk_synthesis` / `TTS native synthesis` | Entire chunk preparation / native synthesis only |
| `synthesis_rtf` | Native synthesis time divided by trimmed audio duration; above 1 means slower than real time |
| `playback_buffer_wait` | Waiting at a later sentence boundary for unfinished lookahead; excludes the first chunk |
| `Audio worker queue wait` / `Audio playback setup` | Playback queue delay / preparation cost |
| `audio_setup_on_main_thread` | Should be `0`, indicating preparation off the main thread |
| `inter_chunk_gap` | Previous completion observed by the backend to next accepted playback; excludes silence inside PCM |

Times are milliseconds. Playback acceptance is not a measurement of physical
speaker/Bluetooth output. Completion observations have timer and queue latency.
If gaps coincide with `playback_buffer_wait`, synthesis is falling behind; if
not, inspect setup, PCM silence and output routing. GPU contention and audible
quality still need real-device verification; helper tests alone cannot prove a fix.

# Gemini inference transport regression tests

Standalone harness for `App/Services/GeminiInference.swift`. It has no XCTest
dependency, no test target, and makes no real network calls or authentication.
`MockURLProtocol` serves every `generateContent` and `models.list` request with
canned JSON, so no live Gemini API key is required.

## Run

From the repository root:

```sh
(
set -eu
BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gemini-inference-tests.XXXXXX")"
trap 'rm -f "$BIN_DIR/charatalk-gemini-tests"; rmdir "$BIN_DIR"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
  App/Services/GeminiInference.swift \
  Tests/GeminiInferenceTests.swift \
  -o "$BIN_DIR/charatalk-gemini-tests"

"$BIN_DIR/charatalk-gemini-tests"
)
```

The executable prints one `PASS`/`FAIL` line per test and exits `0` when all
tests pass, `1` otherwise. A compilation failure also exits nonzero. Only the
harness binary inside `BIN_DIR` is removed, followed by `rmdir` on the
now-empty directory.

## Coverage

Thinking effort (`GeminiThinkingEffort`):

- raw values are exactly `""`, `minimal`, `low`, `medium`, `high`; IDs are
  non-empty and unique; labels are Japanese but keep the API name recognizable
- the per-model support matrix is checked for Gemini 2.5, 2.0/1.5, Gemini 3
  (`3-pro-preview`, `3.1-pro`, `3-flash-preview`, `3.6-flash`,
  `3.5-flash-lite`), Gemini 3.8/4-argon, `models/`-prefixed names, and unknown
  slugs

Request construction (`GeminiInference.send`):

- sends `POST https://generativelanguage.googleapis.com/v1beta/models/<slug>:generateContent`
  with the key only in `x-goog-api-key`; there is no query string, no
  `Authorization` header, and the key never appears in a URL or an error
- request has `application/json` content type/accept and no `model`, `stream`,
  or `safetySettings` fields
- the model slug is trimmed and one optional `models/` prefix is removed;
  empty names, path separators, spaces, colons, query characters, Unicode, and
  other invalid characters fail before networking
- whitespace-only/control-character API keys fail before networking; surrounding
  whitespace is trimmed from valid keys
- system prompts and system-role history items are merged into
  `systemInstruction` (separated by blank lines); blank system prompts omit the
  field entirely
- assistant/model history becomes `model`, user/unknown history becomes `user`,
  and blank messages are skipped; a request with no user/model content fails
  before networking
- `responseMimeType` is `text/plain`
- `temperature` is sent (clamped to 0...2) for known Gemini 2.x and omitted for
  Gemini 3+/unknown models; non-finite values fail before networking
- `.automatic` omits `thinkingConfig`
- Gemini 2.5 maps low/medium/high to `thinkingBudget` 1024/8192/24576; minimal
  and non-supported levels fail before networking
- Gemini 3+ sends `thinkingLevel` as a string; `3-pro-preview` rejects medium
  and minimal, `3.1-pro` rejects minimal, and the flash/lite families accept
  minimal
- Gemini 2.0/1.5 only accept automatic; unknown models accept
  automatic/low/medium/high and reject minimal with an actionable message

Response handling:

- visible `parts[].text` from the first candidate are concatenated in order;
  `thought: true` parts and later candidates never reach the returned text
- only `finishReason == "STOP"` (trimmed, case-insensitive) succeeds
- `promptFeedback.blockReason` and safety/recitation finish reasons map to a
  `blocked` error without exposing `blockReasonMessage`/`finishMessage`
- `MAX_TOKENS`, `OTHER`, and other non-STOP reasons map to `incomplete`
- missing finish reason, missing/empty content, empty or whitespace-only text,
  thought-only parts, non-string text, malformed JSON, empty candidate lists,
  and 2xx error envelopes map to `invalidResponse`
- no error message contains a raw fragment of the response body

HTTP, transport, and cancellation:

- 400/401/403/404/429/5xx and unexpected statuses map to actionable Japanese
  messages; `error.status`/`error.details[].reason` are retained only after
  ASCII-identifier/length sanitization
- response bodies, echoed API keys, and server messages are never surfaced
- connection failures and timeouts become a sanitized `transport` error
- `URLError.cancelled` from `URLSession` is surfaced as `CancellationError` for
  both send and model listing

Model catalog (`GeminiInference.fetchModels`):

- sends `GET https://generativelanguage.googleapis.com/v1beta/models` with
  `pageSize=1000`, the key header, and no key in the query string
- keeps models whose `supportedGenerationMethods` contains `generateContent`;
  excludes image/audio/TTS/live/robotics/embedding variants and invalid names
- `models/` prefixes are stripped; display names are trimmed with the slug as a
  fallback; duplicates keep the first server occurrence and order is preserved
- follows `nextPageToken`, forwards it on the next request, and stops on a
  repeated token cycle (including A → B → A) or after a bounded page count
- empty catalogs return `[]`; malformed envelopes fail with `invalidResponse`;
  401/403/429/5xx map to actionable Japanese model-list errors without exposing
  the body
