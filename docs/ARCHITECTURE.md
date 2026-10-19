# LocalClicky architecture

LocalClicky keeps the original Clicky's menu‑bar UX and blue‑cursor overlay, and
replaces every cloud call with an on‑device equivalent. The only network traffic
is HTTP to a local Ollama server on `127.0.0.1:11434`.

## Packages / targets

| Target | Kind | Role |
|---|---|---|
| `LocalBrainKit` | library | The no‑UI "brain": Ollama client (installed‑model listing, capability detection, streaming model `pull`), format‑robust `[POINT]` parser, prompts, model config + roles, conversation router, spoken‑text segmenter, browser‑ and app‑command planners, `HardwareAdvisor` + `AutotuneBridge` (hardware‑aware model recommendation), and `WebReachTool` (the opt‑in web lookup). Pure logic, unit‑testable, no AppKit. |
| `CSherpaOnnx` | C target | Thin module exposing the sherpa‑onnx C API (neural TTS) to Swift. Implementations come from the vendored dylib the app links. |
| `LocalClicky` | executable (app) | The menu‑bar SwiftUI/AppKit app: overlay, panel, capture, push‑to‑talk, neural voice, browser executor, `CompanionManager`. |
| `localbrain-harness` | executable (CLI) | Runs the full local pipeline against the real models, headless, for verification. |
| `LocalBrainKitTests` | tests | Pointing‑parser unit tests (XCTest; needs Xcode to run, or use `--selftest`). |

## The answer pipeline

1. **Push‑to‑talk** — a listen‑only `CGEvent` tap detects Control+Option globally
   (`GlobalPushToTalkShortcutMonitor`), unchanged from the original.
2. **Speech‑to‑text** — `BuddyDictationManager` captures mic audio via
   `AVAudioEngine` and streams it to `AppleSpeechTranscriptionProvider`, which uses
   `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. No cloud STT.
3. **Screenshot** — on release, `CompanionScreenCaptureUtility` captures the cursor
   screen with ScreenCaptureKit (≤1152 px JPEG), excluding LocalClicky's own
   windows. The screenshot's pixel size defines the model's coordinate space.
4. **Routing** — `ConversationRouter` decides per turn whether this is a
   deterministic **action** (copy the last answer / launch an app / a browser
   command), needs the **screen**, or is a self‑contained/follow‑up **text**
   question. This is what makes follow‑ups work: "what's 3×5" → "15", then "add 2 to
   that" routes to the text model with history (no screenshot) and answers "17",
   instead of the screenshot hijacking the answer. It's a fast heuristic — no extra
   model call — so it also saves latency by skipping the VLM when the screen isn't
   needed. Action turns skip inference entirely (see [Actions](#actions)).
   The router has five non‑action question routes: **`.screen`** (describe what's
   on screen), **`.screenPoint`** (point at a UI element — "where do I click"),
   **`.text`** (self‑contained / follow‑up), **`.showText`** ("give me X in text"
   → a concise answer in the blue side‑text), and **`.webReach`** (the opt‑in
   internet lookup). A "where do I click to open settings" question is detected as
   pointing *first*, so the app/browser launcher never hijacks it.
5. **Inference** — `CompanionManager` builds an Ollama chat request per route:
   - **`.screen`** (describe): screenshot + the `screenDescribe` prompt, sent to the
     **vision model** (default `moondream` — strong at description, doesn't ground).
   - **`.screenPoint`** (point): screenshot + the directive `screenPointResponse`
     prompt, sent to the **grounding model** (default `qwen2.5vl:3b`), which returns
     a `[POINT:x,y]` ~9/10 of the time (measured; up from ~1/2).
   - **`.text` / `.showText` / `.webReach`**: no image, sent to the **text model**
     (default `llama3.2:3b`).
   `OllamaClient.streamChat` streams the reply and reports first‑token latency and
   decode tok/s. Each **model** gets a consistent, **per‑role** `num_ctx` — a snug
   4096 for the text model, a roomy 8192 for vision/grounding (a screenshot +
   history is token‑heavy). Because text and vision are different models, this never
   triggers a reload; when one VLM fills both roles it gets the roomy window in
   both (`CompanionManager.contextWindow(forModel:)`). The smaller text KV cache is
   what lets the `HardwareAdvisor` keep **two models resident** on 16 GB.
6. **Pointing** — `PointingTagParser` pulls the pointing tag out of the reply. It
   accepts the classic `[POINT:x,y:label]`, qwen2.5‑vl's attribute form
   `[POINT x="x" y="y"]`, and a bare `[x1,y1,x2,y2:label]` box (collapsed to its
   center). The remaining text is what gets spoken.
7. **Cursor** — the image‑pixel point is mapped to a global AppKit coordinate on
   the captured display (`CompanionManager.globalScreenLocation(forImagePoint:in:)`)
   and published as `detectedElementScreenLocation` /
   `detectedElementDisplayFrame`. `BlueCursorView` observes those and flies the blue
   triangle along a bezier arc to the element — the original overlay, untouched.
8. **Voice** — the answer is spoken **as it streams**: `SpokenTextSegmenter` peels
   off complete sentences (never the `[POINT]` tag) so the companion starts talking
   after the first sentence instead of waiting for the whole answer.
   `SpeechSynthesisCoordinator` prefers the neural Piper voice and falls back to
   Apple's synthesizer.

For an **action** (step 4), the turn skips inference entirely and is resolved by
deterministic rules — see [Actions](#actions).

### Ink, window pointing and sketches

Three refinements ride on the routes above; each decision is a pure function in
`LocalBrainKit` so it is unit‑tested without the app.

- **Marked area, naming vs explain** (`InkTurnPolicy`, `InkQuestion`): a describe
  turn with ink is *naming* when the words are only "what is this?" and its narrow
  variants, otherwise *explain*. Naming is the measured request (`inkDescribe`, the
  `X-Clicky-Turn: ink-describe` header, no Accessibility block, no history).
  Explain answers the question from inside the marked area (`inkExplain`,
  `X-Clicky-Turn: ink-explain`, with the Accessibility block and history), so
  "go into detail" quotes the numbers instead of repeating the name.
- **Window pointing** (`PointingTarget`): a pointing or click request that names a
  window or app and no control gets `LocalPrompts.windowTargetLine` after the user's
  words; the point system prompt is unchanged. Grounding turns (point, click, draw)
  send no history.
- **Sketches** (`DrawingRouting` → `.screenSketch`, only with drawing on):
  `SketchIntent` finds a figure to draw that marks nothing; it is tested before the
  mark patterns and returns nil when the words name a target ("around the error",
  "it"). `SketchTemplate` composes tic tac toe, box, line, arrow, circle, triangle,
  star, smiley, cross and check in screenshot pixels with no model call, and the one
  sentence it speaks names the figure (and every tic tac toe move) for anyone who
  cannot see the overlay. Any other figure is a freeform sketch: the grounding model
  writes up to `SketchLimits.maxTags` tags with `screenSketchResponse` (0 to 1000
  frame, rescaled by the gateway), and `SketchLimits.freeformEnabled` turns that path
  off with one line. A sketch holds `SketchTiming.holdSeconds` (10 s) after its
  speech instead of the 1.5 s of a mark; a key press or "clear that" (`.clearMarks`)
  ends it.

## Choosing your models

The defaults (`llama3.2:3b` text, `qwen2.5vl:3b` vision) are tuned for a 16 GB Mac,
but each role can be pointed at any installed Ollama model from the panel's
**Models** picker (persisted by `ModelPreferences`). The picker is hardware‑aware
and safe:

- `OllamaClient.listInstalledModels()` enumerates `/api/tags`; `capabilities(of:)`
  reads `/api/show`. The **vision** menu lists only models whose capabilities
  include `vision`; the **text** menu lists only models with `completion` (so an
  embedding‑only model can't be chosen). A text‑only model can never be wired to the
  screen role.
- Changing a model re‑warms it (`warmUpLocalModels`) and re‑checks install status.
  `OllamaClient.modelInstalled(_:among:)` normalizes tags (`llama3.2` ≡
  `llama3.2:latest`) so the "models missing" nudge is accurate.
- More RAM → pick `qwen3-vl:8b` for sharper grounding; less → a smaller text model.
  `swift run localbrain-harness --models` prints what's installed and each model's
  eligible role(s).

## Actions

Three kinds of spoken command are handled **deterministically** (no pixel‑clicking,
no model JSON), each structurally incapable of anything destructive:

- **Browser** — `BrowserCommandPlanner` (pure, in `LocalBrainKit`) maps "open a new
  tab, go to my gmail, and open up a draft" to concrete URLs via a known‑site table
  (a draft → Gmail's real compose URL); `BrowserActionExecutor` opens them with
  `NSWorkspace.open`. The only thing it can do is navigate to a URL — it cannot
  click, submit, send, or run page scripts.
- **App launch** — `AppCommandPlanner` extracts the app name from "launch spotify" /
  "open the notes app" (pure + unit‑tested); `LocalAppLauncher` resolves it to an
  app that's actually installed (Launch Services by name, which even finds system
  apps like Safari behind the read‑only firmlink, plus a fuzzy scan of the
  Applications folders) and opens it — as safe as double‑clicking in Finder. If no
  app matches, it falls back to a web search for the same words, then to saying it
  couldn't find it. Matching is conservative on purpose (e.g. "photoshop" never
  resolves to "Photos").
- **Clipboard** — "copy your answer" / "copy that to my clipboard" writes the
  companion's last real spoken answer to `NSPasteboard`. Useful right after asking
  it to write, translate, or summarize something.

## Why a local VLM for coordinates (and not just a small model guessing pixels)

Small VLMs are unreliable at free‑form pixel grounding on dense UIs — the upstream
PR's `TAKEOVER.md` documents exactly this failure mode. `qwen2.5vl:3b` turned out
to be a sweet spot: it returns accurate **bounding boxes** for named UI elements,
and the parser collapses those to a center point. On a synthetic UI it grounded
targets to within ~15–20 px at sub‑second warm latency. The parser is intentionally
tolerant (accepts `[POINT:x,y]`, `[POINT:x1,y1,x2,y2]`, and bare boxes) so changing
the model later doesn't break pointing.

> Headroom: because pointing is just "name an element → resolve to a screen
> coordinate," a future version can snap the VLM's box to the nearest
> Vision‑framework OCR word box or Accessibility element for pixel‑perfect targets,
> fully locally. The architecture already isolates this in `PointingTagParser` +
> the coordinate mapping.

## Voice (neural, on‑device)

The robotic option (Apple's compact `AVSpeechSynthesizer` voices) is the fallback,
not the default. The default is a **Piper** neural voice (`en_US-ryan-medium`) run
through the **sherpa‑onnx** runtime, linked **in‑process** via its C API
(`CSherpaOnnx` + `PiperSpeechSynthesisClient`). In‑process matters: shelling out to
a TTS binary reloads the ~60 MB model every call (~3 s); holding it resident makes
synthesis ~0.05–0.1 s per sentence (≈20× real‑time) at a negligible battery cost.
The runtime + voice are vendored in `vendor/sherpa/` (fetch with
`scripts/fetch-tts.sh`) and copied into `LocalClicky.app/Contents/Resources/sherpa/`
by `build-app.sh`. If they're missing, the coordinator silently uses the Apple voice.

## Measured on this dev machine (M2, 16 GB)

Verified with `localbrain-harness` against the real models:

| path | cold (first call) | warm |
|---|---|---|
| text chat (`llama3.2:3b`) | ~4.5 s (model load) | first token ~0.5 s, ~45 tok/s |
| screen vision + pointing (`qwen2.5vl:3b`, 1280 px) | model load once | first token ~0.17 s, full answer ~1.4 s |
| neural TTS (`en_US-ryan-medium`) | ~0.4 s load (once) | ~0.05–0.1 s / sentence |

Latency work (verified before/after):
- **Warm‑up on launch** (`CompanionManager.warmUpLocalModels` + the voice graph)
  turns a ~4.5 s cold first query into ~0.17 s.
- **Sentence‑streaming TTS** starts speech ~0.8 s sooner than waiting for the whole
  answer.
- **Routing** skips the slower VLM for text turns (and skips inference entirely for
  action turns).
- **Consistent `num_ctx`** across text/vision/warm‑up means a model is never
  reloaded for a different context size — important when one model fills both roles.
- Screenshot stays at **≤1152 px**: the harness sweep showed shrinking it gives ~0
  latency benefit (first token already ~0.17 s) while hurting pointing accuracy.

Ollama keeps models warm (`keep_alive`), so the cold load is a one‑time cost per
model per session.

## Public‑release subsystems

- **Hardware advisor + autotune (hybrid).** `HardwareAdvisor` (native, always
  works) detects RAM/cores, holds a curated model catalog with resident‑RAM
  footprints, and recommends the best models per role + which to keep resident.
  `AutotuneBridge` detects the optional [`autotune`](https://autotunellm.com) CLI
  and layers its recommendation on top. Drives the warm‑up set, the per‑role
  `num_ctx`, `keep_alive`, and a non‑invasive blue‑text suggestion when a better
  model fits. See `localbrain-harness --advise`.
- **In‑app model + Ollama setup.** `OllamaClient.pullModel` streams `/api/pull`
  (dedicated long‑timeout session); `OllamaInstaller` detects/downloads Ollama.
  The panel offers a **Download Ollama** button and a fit‑gated **Add a model**
  dropdown → download with progress → warm into RAM.
- **First‑run + blue side‑text.** No onboarding video/music. `companionSideText`
  drives a streamed first‑run intro, a two‑step screen‑aware joke (Moondream
  describes → text model jokes), "give me X in text" answers, and model tips.
- **Web reach (opt‑in, the one cloud exception).** `WebReachTool` does keyless web
  read + search via Jina Reader (`r.jina.ai`); the local text model summarizes.
  Only the `.webReach` route triggers it, and the UI shows "checking the web…".

Pointing accuracy on the synthetic test UI: ~14–20 px error; tag‑return rate ~9/10
(see `docs/benchmarks/`).

## What's verified vs. what needs a human at the GUI

Verified here (headless / build): the local brain end‑to‑end (chat + vision +
pointing coordinates), all parser unit checks, a clean compile of the whole app
(16 files, no warnings, no cloud references), and that `LocalClicky.app` launches
as a registered menu‑bar GUI app and runs without crashing.

Needs you at the Mac (can't be automated): granting the four TCC permissions,
speaking into the mic, and visually confirming the blue cursor flies to the right
spot. The pipeline that produces those coordinates is verified; the on‑screen
animation is the original Clicky overlay driven by the same published properties.
