# ASRs-R-US

A macOS menu-bar app for voice dictation with live LLM cleanup.

Press **F7** anywhere. A small window appears with two boxes: your raw speech
on top, a rewritten version below. Edit the bottom box if you want, then hit
**Use** and the text is pasted wherever your cursor was.

## How it works

```
F7 ──► CGEventTap (swallows the key so Music never sees it)
        │
        ▼
   capture frontmost app  ──────────────────────────┐  (paste target)
        │                                           │
        ▼                                           │
   SpeechAnalyzer + SpeechTranscriber               │
   (on-device, streaming, macOS 26)                 │
        │                                           │
        │ every transcript update                   │
        ▼                                           │
   debounce ──► local LLM (streaming) ─► bottom box │
        ▲                                           │
        │ "the user changed X to Y"                 │
   EditTracker ◄── your manual edits                │
                                                     │
   "Use" ──► clipboard ──► activate target ──► ⌘V ──┘ ──► restore clipboard
```

## Requirements

- macOS 26+ (uses the new `SpeechAnalyzer` API)
- Xcode 26+
- `brew install llama.cpp` for the local rewrite engine (default). No API key
  and no network needed.

An Anthropic API key is optional, for the alternative cloud engine.

## Build and run

```sh
make run          # regenerate project, build, relaunch
make build        # build only
make path         # print the built .app path
```

The Xcode project is **generated** from `project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
Edit `project.yml`, not `ASRs-R-US.xcodeproj` — the latter is gitignored and
regenerated on every build.

To work in the IDE: `make project && open ASRs-R-US.xcodeproj`.

## First-run setup

1. **Accessibility** — the app prompts on first launch. Required for two
   things: capturing F7 before macOS routes it to media controls, and pasting
   into other apps. Without it, nothing works.
2. **Microphone** and **Speech Recognition** — prompted the first time you
   dictate.
3. **API key** — menu bar icon → Settings → paste your key. It goes into your
   login keychain (`$ANTHROPIC_API_KEY` is a fallback). The key is tested with
   a real hello-world call as soon as you paste it; a green check confirms
   "API key is stored and working properly", and a red row shows the actual
   API error otherwise (bad key, no credits, unknown model).

   Editing shortcuts (⌘V/⌘C/⌘A/⌘Z) work because the app installs a hidden main
   menu — an `.accessory` app has no menu bar, and AppKit routes those key
   equivalents *through* the main menu, so without one they silently do nothing
   in every text field in the app.

The first dictation in a given language may pause to download the on-device
speech model. After that it's instant and fully offline (only the rewrite step
touches the network).

## Keys

| Key | Action |
|---|---|
| `F7` | Open the window and start recording; press again to stop |
| `⌘↩` | Use — paste the bottom box at the cursor |
| `esc` | Close and go back to what you were doing |

## Settings

| Setting | Default | Notes |
|---|---|---|
| Engine | Local | Qwen2.5-1.5B-Instruct on llama.cpp, or the Anthropic API. |
| Model repo | `bartowski/Qwen2.5-1.5B-Instruct-GGUF:Q4_K_M` | Any GGUF repo `llama-server -hf` accepts. |
| Debounce | 350 ms | Quiet time before a rewrite fires. Lower = snappier, more tokens. |
| Insertion method | Paste | `Paste` (fast, universal) or `Type` (synthesizes keystrokes, never touches the clipboard). |
| Restore clipboard | on | Puts your previous clipboard back ~0.7 s after pasting. |
| Rewrite instructions | see Settings → Prompt | The system prompt. Replace with your tuned version. |

## Why a local model, and which one

Rewrites fire on *every* ASR update while you are still speaking, so
**short-transcript latency dominates** — raw tokens/sec is the wrong metric.
Measured on an M5 Pro / 48 GB, median of 3 runs after a warm-up, on the real
prompt and real dictation samples:

| Engine | short | medium | long | Notes |
|---|---:|---:|---:|---|
| **Qwen2.5-1.5B Q4_K_M, llama.cpp** | **67 ms** | **331 ms** | 678 ms | Chosen. Fastest, and the most faithful output. |
| Qwen2.5-1.5B 4-bit, MLX | 152 ms | 436 ms | **580 ms** | Apple-native and embeddable in-process, but 2.3× slower on the case that matters. |
| Qwen2.5-3B Q4_K_M, llama.cpp | 136 ms | 569 ms | 1151 ms | 2× slower *and* kept the filler "you know" that the prompt says to remove. |
| Llama-3.2-3B Q4_K_M, llama.cpp | 82 ms | 584 ms | 1137 ms | Dropped the speaker's hedging ("I was thinking maybe we could" → "We could"). |
| Qwen3-1.7B Q4_K_M, llama.cpp | 1806 ms | 1806 ms | 2274 ms | A reasoning model: burned 288 thinking tokens for a 13-token answer. |
| LitGPT (Qwen2.5-1.5B, PyTorch/MPS) | ~4 s | — | — | See below. |

Two results worth keeping in mind: **bigger was not better**. Both 3B models
were slower *and* less faithful to the source than the 1.5B — the task is
mechanical cleanup, not reasoning, so parameters buy little and cost latency.
And a *reasoning* model is actively harmful here; thinking tokens are pure
latency for a task with nothing to reason about.

**LitGPT** was evaluated and rejected. It is a training and fine-tuning
framework, not an inference server: PyTorch/MPS rather than Metal-optimised
kernels, ~4 s for a single short rewrite, 5.8 GB on disk for the same 1.5B
model that llama.cpp serves from 0.9 GB, and its current release does not
install cleanly against today's `huggingface_hub` (needed a `<1.0` pin). It is
the right tool for adapting a model, and the wrong one for a latency-critical
inference loop.

**Apple's `FoundationModels`** (the on-device model built into macOS 26) is the
most attractive option on paper — zero install, zero download, Swift-native, no
subprocess. It is unavailable on this machine only because Apple Intelligence
is switched off. Worth revisiting: enable it in System Settings, and the
framework is already present in the SDK.

## Design notes

**Clipboard managers.** The pasted item is flagged with the
[nspasteboard.org](http://nspasteboard.org) marker types
(`org.nspasteboard.TransientType`, `AutoGeneratedType`, and the legacy
`de.petermaurer.TransientPasteboardType`), so managers that follow the
convention keep it out of your history — and the *restore* is flagged too, so
putting your clipboard back doesn't create a duplicate entry either. Verified
empirically against Jumpcut 0.84: a transient probe left zero entries in
`JCEngine.save` while a plain control probe left one. Maccy, Flycut, Clipy,
Copied, and Pastebot follow the same convention. For a manager that ignores it,
switch Insertion Method to `Type`, which bypasses the clipboard entirely.

The restore is also guarded on `changeCount`: if anything else wrote to the
clipboard during the paste, that write is newer than ours and we leave it alone
rather than stomping it.

**Managing the model server.** The app spawns and supervises `llama-server`
itself, so there is no terminal step. If a healthy server is already listening
on the port it is adopted rather than duplicated, and a server the app did not
start is left running on quit. The client speaks plain OpenAI
`/v1/chat/completions`, so pointing the app at Ollama, LM Studio, or
`mlx_lm.server` instead works without code changes.

**Why paste instead of the Accessibility API.** Setting a focused element's
value via `AXUIElement` fails silently or mangles text in Electron apps,
browser rich-text editors, and terminals. Clipboard + synthetic ⌘V works
everywhere, at the cost of briefly borrowing the clipboard.

**Why the app is not sandboxed.** A global `CGEventTap`, the Accessibility API,
and posting synthetic keystrokes into other processes are all incompatible with
the App Sandbox. This is inherent to what the app does, not an oversight — it
does mean the app can't ship on the Mac App Store as-is. Direct distribution
would need Developer ID signing + notarization (`ENABLE_HARDENED_RUNTIME` is
already on).

**Edit tracking.** `EditTracker` diffs your typed text against the model's last
output using a common-prefix/suffix trim widened to word boundaries, so the
prompt says `changed "teh" to "the"` rather than `changed "e" to "he"`.
Consecutive edits to the same span collapse into one entry, and the list is
capped at 12 so the prompt can't grow without bound.

**Not clobbering your typing.** While a rewrite streams in, the output box is
only updated if you haven't typed in the last 1.5 s. Once recording stops, no
further rewrites fire at all, so the bottom box is yours.

## Debugging

`VOICEEDIT_AUTOSHOW=1` opens the panel at launch, so the UI path can be
exercised without a keypress:

```sh
open --env VOICEEDIT_AUTOSHOW=1 "$(make path)"
```

Crashes land in `~/Library/Logs/DiagnosticReports/ASRs-R-US-*.ips`. Logs:

```sh
log stream --predicate 'subsystem == "com.brianellis.ASRs-R-US"' --level debug
```

The hotkey tap logs every key it sees at debug level, which is the fastest way
to find out what F7 actually emits on a given keyboard.

## Layout

```
project.yml                  XcodeGen spec — the source of truth for the project
Sources/
  App/         main.swift, AppDelegate (status item), SessionController
  Hotkey/      HotKeyMonitor — the F7 CGEventTap
  Dictation/   DictationEngine (SpeechAnalyzer), AudioFeeder (audio thread)
  LLM/         AnthropicClient (SSE), RewriteService (debounce + prompt)
  Editing/     EditTracker — diffs manual corrections
  Insertion/   TextInserter — clipboard + ⌘V into the target app
  UI/          DictationPanel (NSPanel), DictationView, SettingsView
  Support/     AppSettings, Keychain
```
