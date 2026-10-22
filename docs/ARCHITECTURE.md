# LocalClicky architecture

LocalClicky keeps the original Clicky's menu‑bar UX and blue‑cursor overlay, and
replaces every cloud call with an on‑device equivalent. The only network traffic
is HTTP to a local Ollama server on `127.0.0.1:11434`.

## Packages / targets

| Target | Kind | Role |
|---|---|---|
| `LocalBrainKit` | library | The no‑UI "brain": Ollama client (installed‑model listing, capability detection, streaming model `pull`), format‑robust `[POINT]` parser, prompts, model config + roles, conversation router, spoken‑text segmenter, browser‑ and app‑command planners, `HardwareAdvisor` + `AutotuneBridge` (hardware‑aware model recommendation), and `WebReachTool` (the opt‑in web lookup). Pure logic, unit‑testable, no AppKit. |
| `LocalClickyActions` | library | The action layer for computer use: reads a web page through Accessibility and presses one element in the background. `ActionBackend` is the protocol, `AXBackend` the one backend. Depends on `LocalBrainKit`; links `ApplicationServices`. See [Computer use](#computer-use-play-a-video). |
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
- **Pointing routing** (`ConversationRouter.wantsPointing`): besides the "where is the"
  phrases, `wantsWhereObjectIs` catches "where the X is/are" (object before the verb)
  and "find out / find / tell me / show where the ...". It leaves alone questions about
  places in the world ("nearest", "closest", "nearby", "near me", ...) and live-data
  questions (`wantsWebReach`). A pointing hit skips the web, timer, app and browser
  routes like every pointing question, and acts only with vision mode and the screen on.
  `Context.previousTurnWasPointing` lets a bare follow-up (`PointingFollowUp.isBareFollowUp`:
  "again", "that one", "show me again") be a pointing turn.
- **Window pointing** (`PointingTarget`): a pointing or click request that names a
  window or app (the article is optional) and no control gets
  `LocalPrompts.windowTargetLine` after the user's words; the point system prompt is
  unchanged. The control nouns include bar, box, input, composer, text field, search
  bar and sidebar (so "the chat window bar" and "menu bar" are control requests).
  "Title bar" is the exception: it is a window cue, so "point at the title bar of the
  chat window" gets the window line and the window snap. Grounding turns (point, click, draw) send no history.
- **Follow-up object** (`PointingFollowUp`): the app keeps the noun phrase of the last
  pointing or click request. A pointing turn with no object of its own gets it put into
  the words sent to the model ("point out to me again" becomes "point out the chat
  window"), and into the window-line decision. History is still not restored on a
  grounding turn. A new object replaces the stored one.
- **Snap** (`PointSnap` in `LocalBrainKit`, `PointSnapper` in the app): after the model's
  point, and before the cursor flies, the point is moved onto the real window or control.
  Every point and frame is in Core Graphics global points (top-left of the primary
  display, y down), the space of Accessibility frames and window bounds. The chain is
  model norm1000 point, rescaled by the gateway to screenshot pixels, then
  `ScreenMapping.displayLocalPoint(forImagePoint:)`, then `cgGlobalPoint(...)`; the
  snapped point returns through `imagePoint(forCGGlobalPoint:)`. A window request goes
  to the title bar centre (top edge plus 14 pt, never inside the 30 pt menu bar strip)
  of the window picked in this order, from the window server's layer-0 windows with
  our own, the menu bar and the Dock left out: (a) one whose title or app name matches
  the requested object (the substituted or the words' own, "window", "app" and "title
  bar" dropped) or the model's label, by `labelScore`, even when it does not contain
  the point; (b) for a point in the top 30 pt of the display, the frontmost window;
  (c) the topmost window that contains the point; (d) the nearest window, within
  60 pt; (e) else the model's point stays (a Dock icon of an app with no window).
  A control request keeps the Accessibility
  element under the point when its label matches the model's label (token overlap
  at least 0.5, `PointSnap.labelScore`), else the best match within
  `PointSnap.searchRadius` (120 pt), else the model's point. A label is an element's
  title or description, never its value (what a text field holds is typed content, so
  it is never matched or logged). Containers (AXWindow, AXSheet, AXGroup, AXScrollArea,
  AXSplitGroup, AXWebArea, AXToolbar, AXLayoutArea, AXApplication) and elements larger
  than 400 x 300 pt are never candidates; among those holding the point the smallest
  frame wins, then the best score. The Accessibility reads
  share `PointSnap.budgetSeconds` (0.15 s). Early and final cursor dispatch both snap
  (the timing marks `tag_parsed` before the snap; a stream that ends during the early
  snap reuses its result); a click turn clicks where the cursor went. The primary
  screen height is read on the main actor and passed in. Temperature and screenshot size are unchanged.
- **Sketches** (`DrawingRouting` → `.screenSketch`, only with drawing on):
  `SketchIntent.parse` returns a `SketchRequest` (figure, `SketchAnchor`, `SketchSize`,
  board) for words that ask for a figure that marks nothing; it is tested before the
  mark patterns and returns nil when the words name a target ("around the error",
  "it"). draw, sketch, doodle, diagram and illustrate also reach a freeform figure (diagram and
  illustrate only where a command starts, so "the diagram of the heart shows" is not one; a
  leading "out", "how to" and "how do i" are dropped from the phrase after a drawing verb, so
  "sketch out how to do parallel parking" is "parallel parking", and the same words after
  "show me" or with no drawing word are untouched); put, place, make, show me,
  give me, add and create reach a figure only when the whole object is a `named` figure
  (the name, then at most a board word, a placement, a size or a tic tac toe move), so
  "show me the star wars trailer" and "show me the box score" are not sketches.
  Tic tac toe moves ("x in the center", "an o top left") are read first, before the
  placement patterns strip their region words; "empty", "blank", "nothing in it" force an
  empty board, and only "game in progress" or "some moves" bring back
  `SketchTemplate.demoBoard`. The placement is one of nine regions (a region word needs
  a preposition, a corner or side word, or the two-word form, so "a right arrow" is not a
  placement) plus a size (small 0.6, large 1.5).
  `SketchTemplate.plan` composes tic tac toe, box, line, arrow, circle, triangle, star,
  smiley, cross and check in screenshot pixels with no model call, inside that region with
  an edge margin, and the one sentence it speaks names the figure, the real place
  ("in the bottom left of your screen") and every tic tac toe move (or "empty") for
  anyone who cannot see the overlay. Freeform keeps the middle and the usual size: the
  prompt has no placement. Any other figure is a freeform step sketch: the grounding model
  writes up to `SketchLimits.maxSteps` (6) steps with `SketchPrompts.stepSketch` (0 to 1000
  frame, rescaled by the gateway; `LocalPrompts.screenSketchResponse` stays pinned and
  unused). A step is `[STEP]`, one short sentence, then its SHAPE tags; a label rides in the
  tag's own label field (`[SHAPE:polygon:...:car in front]`), so the gateway, which rescales
  SHAPE tags only, needs no change. The reply is read as it streams by
  `SketchStepStream` (`SketchStepParser.parse` is that stream fed the whole reply, so the two
  cannot differ): a step is handed over once the next `[STEP]` marker has fully arrived, or
  at the end of the stream for the last one, so a tag or marker cut off at a chunk boundary is
  never read early and step 1 is spoken and drawn while step 2 is still being written. At most `maxStepTags` (24) tags over all steps, labels
  cut to `maxLabelWords` (4) words, a tag that does not validate, a HIGHLIGHT, and anything
  past a limit dropped and counted, never guessed. A reply with no marker is one step. With
  no valid tag the turn says `failureSentence`; tags with no sentence get `drawnSentence`.
  Step marks bind to their sentence: the app closes a step's marks, then queues its
  sentence (`SpeechMarkScheduler` binds every mark closed since the last sentence), step
  by step as each completes (in `onText`; the canvas record is written when the stream
  ends, and the previous kept layer is cleared when the first step starts), and the scheduler runs in hold mode (`holdsBoundMarks`): a bound mark has no
  1.5 s timeout, because step 3 closes while step 1's clip is still playing and would
  otherwise appear during step 1. It shows when its clip starts (or any later clip
  starts); once every sentence has gone to the speech client and nothing has played for
  `SketchTiming.flushGraceSeconds`, the mark driver flushes what is left. A step with no
  sentence binds its marks to the next step's. A shape's label is drawn by
  `AssistantMarksLayer` (`SketchLabelPlacement`: above the top edge of a closed shape or
  curve, at the centre of a line or arrow, kept on screen) as white 15 pt text on a 0.85 black
  backing (worst-case contrast about 15:1, tested against 4.5:1); only a sketch carries
  labels, a circle drawn at a button has none. `SketchLimits.freeformEnabled` turns the
  model path off with one line. `freeformAnswerMaxTokens` (1600) is derived in its comment. An unkept sketch holds `SketchTiming.holdSeconds` (20 s, so there is time to say
  "keep it") after its speech instead of the 1.5 s of a mark; a key press or "clear that"
  (`.clearMarks`) ends it.
- **The sketch record and keeping** (`SketchCanvas`, pure; `CompanionManager.sketchCanvas`): every
  sketch, template or freeform, is recorded when it is drawn: groups of (step sentences, SHAPE tags
  on the 0 to 1000 grid, converted from screenshot pixels with the screenshot size), a `kept` flag,
  and the pixel size it was drawn at. The marks are a drawing of the record. States: empty, showing
  (unkept), kept, extending (a kept sketch with an extend turn in flight). A key press takes an
  unkept sketch off the screen (`assistantMarks.clearNow`) but leaves the record, so "keep it" redraws
  it from the record; any turn that is not about the sketch (`sketchRoutes`) forgets an unkept record,
  and so does the end of its fade. `DrawingRouting.route` takes the canvas status (none, showing,
  kept) and returns `.keepSketch` ("keep it", the whole utterance, so "keep it short" is not it; with
  nothing drawn it says "nothing is drawn right now."), `.describeSketch` (any sketch), `.undoSketch` and
  `.extendSketch` (kept only); without a kept sketch "undo that" and "add ..." route as before. These
  checks come after the action routes and the click guard and before the sketch and mark patterns.
  "and keep" inside a sketch request is `SketchRequest.keep` (taken out of the words first, since
  its "it" would be a target cue). A new sketch replaces a kept one. Undo pops the last group and
  redraws (the only group: clears). Describe reads "step 1: ... step 2: ..." from the record, no model.
- **Extend** (`.extendSketch`, `SketchPrompts.extend`): a freeform sketch turn with the kept tags quoted
  in the user turn between `<<<SKETCH ON SCREEN` and `SKETCH ON SCREEN>>>` as data, not instructions
  (the `DraftPrompts` convention: a delimiter inside a label is broken, a label is one line), then the
  request. The reply has the sketch format and limits; it is recorded as a new group and drawn over the
  kept marks in the pixels the sketch was first drawn at (the grid makes the screenshot size of the
  extend irrelevant). Extend words (`SketchCanvasIntent.wantsExtend`): add or label (not a number, a
  reminder, a note... or "to my list"), "the next step", "... too", "also draw ...", "extend the
  sketch". They route only with a kept sketch, so a kept sketch does take "add a star" from the
  template route, and "add milk to my shopping list" is the kind of phrase the exclusions are for.
- **The kept layer** (`KeptSketchWindows.swift`): kept marks live in their own click-through window per
  screen (`ignoresMouseEvents`, `sharingType = .none`, one level below the cursor overlay), driven by
  a second `AssistantMarksModel`. It is not on `OverlayWindow` because `.none` there would hide the
  blue cursor from the user's screen sharing and the overlay is torn down with the transient cursor.
  The model's screenshots exclude it twice: `CompanionScreenCaptureUtility` already removes every window
  of this app from its capture filter, and `sharingType = .none`. Not yet verified live. The window
  also holds the "Kept. Say clear to remove." pill (`KeptBadge`: centred under the sketch's bounds,
  kept on screen, white on 0.85 black like the labels, contrast about 15:1 against the 4.5:1 required);
  it is removed with the marks, hidden from accessibility, and says nothing (the spoken
  "kept. say clear to remove it." is the VoiceOver path).
- **Clear** (`ClearMarksIntent`): "clear/erase/wipe/remove/get rid of/undo" plus a drawing
  word, a tic tac toe name (any speech-to-text spelling), "the board", "the grid", or
  "the/that/your" plus any template figure name. A bare "that" counts only after clear,
  erase or wipe, so "undo that" after a click turn undoes nothing that was drawn. Clear
  is routed before the base route. The key press clears the marks before the words are
  heard, so `CompanionManager` remembers whether marks were showing at the press
  (`marksShownAtPress`); with none it speaks "nothing is drawn right now." and the turn
  ends there, never falling through to chat. With a sketch on the record (kept or not) "clear"
  also drops the record and the kept window.
- **History note** (`SketchHistory.note`): a sketch turn records "(drew a tic tac toe
  board)" in the conversation history instead of its sentence, for template and freeform
  turns alike, so a later chat turn has nothing to recite. `lastSpokenAnswer` keeps the
  real sentence for "copy your answer".

## Computer use: play a video

"Go to youtube and play lucid dreams" runs one fixed plan. No model reads the page and
nothing is sent to the Studio or Ollama. The one network call is a plain GET of youtube's search
page for the spoken query (below). Each decision
is a pure function in `LocalBrainKit`, tested with a fake world; the app only
supplies the real one.

A run is in the **background by default** (`MediaRequest.foreground` is false): the
planner sets it only when the words ask ("in the foreground", "bring it up", "so i can
see it", "show me" at the start or end next to a play verb, and a few more), and strips
those words from the query. Background means Chrome opens with `activates = false`
(`BrowserActionExecutor.execute(_, activates:)`), nothing activates LocalClicky, and the
interlock is off.

- **Trigger** (`AgentTaskPlanner.mediaIntent`): a play verb (play, start playing, put
  on, watch) plus the word youtube ("you tube" is joined). A verb right after I, we,
  they, he or she is skipped ("i watch youtube a lot"); "you" is not, so "can you play
  X on youtube" works. Without the word youtube, "play" counts only inside a request frame
  ("can you play X", "could you play X", "please play X", "i want you to play X", "i'd like you
  to play X", "play X for me"); a bare "play X" does not, and neither do "watch" or "put on".
  Another service in the words (spotify, netflix, apple music and a few more) keeps it out.
  The query loses a leading "the" and a trailing "song", "the song" or "video". `ConversationRouter` returns `.playMedia` after Spotify and
  before openApp and the browser routes. A play verb with no video name ("play a
  video on youtube") gives `.needsQuery`: the app speaks `AgentNarration.needsQueryLine`
  and starts no run. A bare "watch" without a name is no request at all.
- **The run**: `CompanionManager.handlePlayMedia` makes a `MediaAgentRun` (the
  `MediaRunWorld`) on its own task, so the key press that cancels the response task
  cannot end it. `MediaRunDriver` drives `MediaRunMachine`, which owns every
  transition and every stop. States: `opening` (Chrome opens the results page),
  `locating` (read the links), `asking` (the consent card), `pressing`, `verifying`,
  then `playing`, or a final `handoff`, `stopped` or `capped`. **Direct results come first:** a run
  starts in `searching`, fetches youtube's search page (`YouTubeDirectSearch` in the app,
  `YouTubeSearchResults.parse` in `LocalBrainKit`) while the "looking up X on youtube" line is
  spoken, and nothing is opened in Chrome. With a result it goes `askingDirect` (the card and
  the spoken question name the exact video), and only after the yes `openingVideo` opens
  `https://www.youtube.com/watch?v=<id>` through `BrowserActionExecutor` (background unless the request
  is foreground), then `verifying` as below. If the page can be read, a Pause button on that
  video's page (the `v` must match) gives `playing`; if it cannot be read within `verifySeconds` the run
  ends `opened`, spoken as "i opened the video for X in chrome, but i can't tell whether it started"
  (step effect `unverifiable`). Without a result (fetch failed, timed out, consent page, nothing
  parsed) it falls back to the page path in the next sentence. Decline, silence, a stop or an interrupt
  before the yes open nothing. The page path: `opening` (Chrome opens the results page), `locating`, `asking`, `pressing`, `verifying`. Verifying needs a
  `/watch` page with a Pause button; if the page is open but not playing, the driver
  presses Play once. The caps are `AgentCaps`: 45 s wall clock, 20 s for the consent
  (silence is no), 6 s for the page load (15 s, `pageLoadColdSeconds`, when Chrome was not running before the open; `MediaRunWorld.browserIsRunning` says which), 6 s to verify (the 15 s cold window instead when the browser was not running before the run opened anything, still inside the wall clock), one Play retry, 8 steps. A page
  off youtube.com ends the run. The run adds one history entry when it ends.
- **Action layer** (`LocalClickyActions`): `ActionBackend` reads the page state, walks
  elements by role, presses one and reads it back. `ActionBackends.current()` returns
  `AXBackend`, the only backend. A press is `AXPress`, delivered to the element, so
  Chrome stays in the background and the real cursor never moves. The page is read from
  the focused window, or, when that has no http(s) web area (a page opened in the
  background may be in another window), from the first of the app's other windows (at most
  8, same limits and deadline) that has one, a youtube.com page preferred
  (`WebPageReading.preferredWindowIndex`). Chromium browsers
  (`WebPageReading.isChromiumBrowser`) and Fastmail's Electron app
  (`WebPageReading.needsAssistiveClientNudge`) are told an assistive client is reading, decided by
  `WebContentAccess` and made once per run, before the page opens, by `AXBackend.beginWebContentAccess(pid:)`
  (on its own app element with a 2 s messaging timeout, and `endWebContentAccess` restores on its own app element
  with the same 2 s, so the write-back does not fail spuriously; the 0.1 s per-element timeout stays for the
  tree walk, and `pageState` and `walk` never set anything). A cold-launched Chrome has no process at the
  open, so `MediaAgentRun` makes the call at the first read after it started.
  `AXManualAccessibility` first; when Chrome answers "attribute unsupported" (-25205, as Chrome 155 does)
  or fails twice with any other error, `AXEnhancedUserInterface` for the rest of the run. That is
  what VoiceOver sets, so it is run-scoped: its previous value is read and remembered before it
  is set, it is left alone when already true, an unreadable value counts as true while VoiceOver is on, it is
  never set back to false if VoiceOver was on at the start or is on at the end (VoiceOver owns it), and `endWebContentAccess(pid:)` writes the old value
  back when the run reaches any final state (idempotent; `MediaAgentRun` calls it from `show` and
  again when the driver returns) and reports the write-back's AXError and the value read after it. The cost: Chrome can slow down and window managers or window
  animation can be disturbed while it is on. The mode used (manual, enhanced, none) is logged. A secure text
  field is neither read nor descended into. Every read runs off the main thread under
  a budget, and without the Accessibility permission each call returns at once with
  nothing.
- **SendGuard** (`LocalBrainKit`, used by `AXBackend.press`): a control whose
  normalised label (lowercase letters and digits, single spaces, bidirectional and other format marks removed)
  is, or starts with, send, send now, schedule send, send later, send and archive, discard, discard draft,
  delete, archive, report spam or move to trash is never pressed (`press` returns `.noop`). A prefix match means a
  YouTube link titled "Send ..." is refused too. The action layer posts no key or mouse event; a test scans
  `Sources/LocalClickyActions` for `CGEvent` and the like and fails if one appears.
- **Email drafts and Bear notes** (route `.draftEmail`, `.bearNote`; no page is read). `ConversationRouter.route`
  checks `EmailDraftPlanner.request` and `BearNotePlanner.request` first, before the keyword routes, so words inside
  a message ("play", "youtube", "weather") cannot take the turn. Both are command-form grammars (a leading verb after
  address words, plus draft, email or a service as evidence), so "open up, my gmail in the browser" stays
  `.browserCommand` and the fragment "john in the email" stays chat. `DraftRunDriver` drives a `DraftRunWorld`
  (the app's is `DraftAgentRun`): understanding, finding, writing, opening, ready. `DraftWriter` asks the draft model
  (`ModelPreferences.draftModel`, default `studio:clicky`, the chat gateway; the email is written as `ModelPreferences.userDisplayName`, empty by default, then "the user") for the body; HTTP 503, the gateway's
  "studio connection is off" text, an empty answer or the 30 s window fall back to the gist as the body with one
  short spoken notice. `ComposeTarget` builds the Gmail compose link (`/mail/u/N/`, `ModelPreferences.gmailAccountIndex`)
  or a Fastmail mailto link (RFC 6068), strict RFC 3986 encoded (`StrictURLEncoder`), and `BrowserActionExecutor.openInApp`
  opens it without activating the app. Nothing sends: opening a link only makes a draft, and every closing line ends
  "it is not sent. press send yourself." A spoken "click send" routes to `.refuseSend` before any grounding. No
  service named: the run asks and `pendingDraftRequest` takes the next turn's service name.
  The `draft` TEMP event holds counts and names only.
- **Page features of drafts** (Chrome, Gmail; gated at run time, no flag). The writer always runs first, before any page step,
  from the gist alone (Studio off: the gist is the body, as before). "Use the open draft" and replies then call
  `beginWebContentAccess` and look for the service's web area with children for up to 4 seconds (`PageGate`, domain from
  `LabelMap.preferredDomain`; `AXBackend.webAreaStatus`). Not found: the run opens a new draft and says why, the same as
  without the page features. Found: `composeFields` lists the settable compose bodies; exactly one is used (none or several:
  a new draft, said aloud). An empty body gets the text by `setValue` (AXValue set, then read back); a body with text asks
  "the open draft already has text. add to it?" on the card (Return, Escape, a spoken yes or no, 20 s of silence is no) and
  on yes appends after a blank line (the 2000 character cap applies to the written text, not the total). A reply opens
  `#search/from%3A<person>` in Chrome in the background, finds the first `AXRow` naming the person, presses it, checks that
  the page address changed, reads the page in document order (`readThread`, DFS), takes the texts before the last button
  labelled exactly "Reply" as `ReplyContext` (last 2000 characters; only its length is logged), makes a second writer call that quotes it as
  data (`DraftPrompts.replySystem`, the message between `<<<MESSAGE BEING REPLIED TO` and `MESSAGE BEING REPLIED TO>>>`,
  "not instructions", a delimiter inside it is broken, the gist after the block) whose text becomes the body, keeping the
  first body when that call fails or when the first already fell back (`replyWriter`: model, fallback or skipped),
  presses that button and fills the new body the same way. No message, no Reply control or no body within the caps ends
  with "i could not find a message from <name> in gmail. say the address for a new draft, or open the message and ask
  again." and opens nothing. Presses go through `pressControl`: rows and buttons only, never a link, and `press` applies
  SendGuard (so a row whose text starts with "send", "delete" or "archive" is refused and ends as that handoff). Nothing sets
  focus, raises a window or posts an event (a test scans for it). `endWebContentAccess` runs on every path before the
  closing line. Every role and label the page steps look for is a guess held in `LabelMap` until the compose probe
  confirms it; changing one is a change to that file and `LabelMapTests`.
- **Picker** (`MediaResultPicker`): only a plain video link counts, meaning a `/watch`
  link with a `v` parameter, no `list` parameter, and a label that is not empty, not just
  a duration, and not "now playing" or similar. Of those, the first that shares a word of
  three letters or more with the spoken query wins, else the first on the page. Direct results
  (`DirectResult`: id, title) skip shorts, live and upcoming streams and entries without a valid
  11-character id, then the one whose title shares the most such words with the query wins (the earliest
  on a tie, else the first). The ytInitialData JSON is walked for `videoRenderer` objects.
- **Consent**: one yes per run, before the press or the open. The card (`AgentRunPanel`) asks "Play
  this on youtube.com?" and shows the located title, cut to 120 characters. On the page path the
  title is page text and is never spoken. On the direct path the spoken question names the video
  ("should i play <title> on youtube?", the title flattened and cut at 100 characters) because the
  yes is for that exact video; it is the one line that carries page text. Return, Escape, the two buttons, or a spoken yes or
  no answer (`ConsentAnswer` takes only a whole utterance of four words or fewer; any
  other speech while asking counts as no). Silence for 20 s is no. After a yes and before
  the press, the driver reads the links again and compares the target to the located one:
  same address and label, each frame edge within 8 pt (`frameToleranceInPoints`). A
  mismatch is a handoff with nothing pressed.
- **Step card**: one row per step with a word for its state (Done, Doing, Next, Stopped,
  Skipped), so state never rests on colour, and a Stop button. Normally it takes no
  focus. While asking, the card (a nonactivating panel) becomes the key window without
  activating the app, so Return and Escape reach it and VoiceOver focus moves to the
  question while the user's app stays in front; after the answer it resigns key. The
  panel's `keyDown` and `cancelOperation` answer too, beside the SwiftUI shortcuts, and
  the run takes only the first answer. If the card is not the key window once the question is up (checked twice, 100 ms apart), the buttons drop "(Return)" and "(Escape)" and the asking line says "press the yes button" instead of "press return", so no key hint is given that would reach another app. Captures skip the card (`sharingType = .none`).
- **Ghost pointer** (`GhostPointerWindow`): a faint arrow (alpha 0.45) at the link the
  run is about to press, shown only when Chrome is the frontmost app at that moment (in
  the background it usually is not, and the arrow would point into another app). It is
  click-through, out of screen captures, and hidden from Accessibility; with Reduce Motion
  on it jumps instead of gliding. It is only a picture. The real cursor never moves.
- **Narration** (`AgentNarration`): fixed templates; the only variable parts are the
  user's own query and, in the direct question, the title. Other page text never reaches the voice. With VoiceOver on, each line is
  an `announcementRequested` post instead of speech. The locating and verifying states
  only update the card. The first line is "looking up X on youtube." (nothing opens yet). On the page path
  the opening line takes the mode: "opening youtube for X in the background." or, in the foreground,
  "opening youtube for X."; after a direct yes it is "opening the video in the background." The card lists
  the direct steps (look up, ask, open, check) and switches to the page steps on a fallback.
- **Interlock** (`InputInterlock`): in the foreground only (the mouse timer and the key
  subscription are not started in the background), the run stops when the real mouse
  travels 12 pt (polled every 50 ms) or any key goes down that was not posted by the agent. Agent
  key events carry `InputInterlock.agentEventTag` in their event user data;
  `GlobalPushToTalkShortcutMonitor.keyDownPublisher` reports it, and `ClickActionExecutor`
  tags its clicks. Neither stops a run while it is asking, because Return and Escape are
  the answer. A talk-key press stops a running run, but while asking the press starts a
  spoken answer, and `CompanionManager` routes the words to `ConsentAnswer` instead of
  a new turn. The Stop button stops a run, and while asking it means no.
- **TEMP debug lines**: the run writes `agent` (one line per step record, no page
  text), `agent-links` (the first 40 links of the results page) and `agent-buttons` (the
  button labels of the page being verified) to `TempAppDebugLog`. The last two are page
  text. `agent-direct` (once per run: fetch milliseconds, result count, chosen video id and title, whether it fell back, `stoppedDuringLookup` when a stop ended it instead, the error; the title is page text) and `agent-end` (once, at
  the final state: the state, `axMode`, whether AXEnhancedUserInterface was `restored`, `lastPageURL`, `firstWebAreaMs`, `restoreAXError` and `readBackAfterRestore`) are also written. A page-load timeout also writes `agent-open` (`axMode` too; Accessibility trusted, Chrome running
  before and after, its pid, the last page address read, the last AXManualAccessibility
  result, seconds waited, foreground; no page text). `agent-ax` is one line per attribute set
  (attribute, `axError`, `uptimeMs`, `timeoutSeconds`, `readBack`, `voiceOverOn`, `appBundleId`, `appVersion`,
  `attributeListed`, `settable`). `agent-walk` is a look at the front window's tree at most every 0.5 s for 10 s after the
  access began, 20 a run (`windowIndex`, `windowTitle`, `nodesVisited`, `maxDepth`, `stopReason`: found, maxNodes, maxDepth,
  deadline or exhausted, `elapsedMs`, `webAreaFound`, `webAreaURL`, `webAreaChildCount`, `windowOnScreen`, `windowBounds`, `omnibox`,
  the address bar's value; the title and addresses are page text). README, "Temporary app debug log", says how to remove them.
- **TEMP page probe** (`PageProbeRunner`, `AXPageProbe`, `AXBackend.walkTelemetry`; pure parts in
  `PageProbe.swift`): decides without voice whether a Chromium or Electron page can be read. While
  `~/.clicky-gateway/debug.on` exists, a 2 s timer looks for `~/.clicky-gateway/probe.request`; its first word
  is read, the file deleted and the probe run. `chrome` and `fastmail` begin access, walk the front window for
  10 s (no page is opened) and restore. `mailto` opens a safe mailto in Fastmail.app with
  `activates = false` and logs the frontmost app and Fastmail's window titles before and 2 s after (`probe-mailto`).
  `compose` finds Gmail's "Message Body" in Chrome's front window, and if it is settable and empty writes a
  marker, reads it back and looks 3 s later for the "Saved" text (`probe-compose`); it also writes roles,
  descriptions and titles (never values) of up to 300 nodes of the compose region to `probe-compose-tree.jsonl`.
  The result is `probe-result.json` (`word`, `ts`, `axMode`, `codes`, `webAreaFound`, `webAreaChildCount`,
  `firstWebAreaMs`, `omnibox`, `notes`). Nothing is pressed, focused or raised, no key or mouse event is posted, and no mail is sent.
  The address-bar label ("Address and search bar" and near variants), "Message Body", and
  Fastmail's bundle id `com.fastmail.mac.Fastmail` are guesses until a probe run shows the real ones.

### Deviations from the approved plan

The plans live in `docs/plans/`, which stays in the local checkout and is not published.

- **Cua Driver is not built.** It is not installed, and it needs the owner's grant and
  the P0 probes first. `AXBackend` is the backend; switching is the one line in
  `ActionBackends.current()`.
- **The harvester and the click executor stay where they are.** Moving them into
  `LocalClickyActions` was churn with no behaviour change, so the AX read helpers are
  copied (the file says so).
- **Not built yet:** the Holo35 click fallback for an empty Accessibility tree, forms
  (P3), and the injection and TEST eval (P4).
- **AXEnhancedUserInterface is touched, run-scoped.** The plan said never to touch it, because VoiceOver
  owns it. Changed on 2026-10-20 by the owner's decision: "ok try results directly. and then use voiceover
  switch if it. fails i guess. i want a generic solution i deally cause i also use gmail, fastmail though
  both on a browsr so as long as it can read browser renderings/results, we are good". It is used only
  when AXManualAccessibility is unsupported, with its old value remembered and restored at the end of
  the run (see "Action layer").
- **One network call, to youtube.com.** The direct search is a GET of the same address Chrome would open
  for the query (`MediaRequest.searchURL`), from an ephemeral `URLSession` (no cookies, no cache, a
  desktop Chrome user agent, `Accept-Language: en-US`, a 5 s limit), only for a play request the user
  made. Only the spoken query leaves the Mac; no screen, voice or page data does. Decided by the owner on
  2026-10-20 (quote above). It joins the web tool as a named exception to "no cloud".
- **A consent card is shown on the YouTube path** although the plan's RiskGate would allow
  an on-domain press. The done criterion asked for it.

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
