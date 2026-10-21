# Bonzai Buddy for Mac

A purple gorilla desktop pal in the spirit of 1999's BonziBuddy (minus the spyware), powered by the AI of your choice: Claude, OpenAI, Gemini, OpenRouter, a local Ollama model, or any OpenAI-compatible endpoint.

Bonzai lives on your screen as a physical little creature:

- **Sits on your windows.** He lands on title bars and rides along when you move a window.
- **Gets flung.** Yank a window fast and he's launched across the screen.
- **Gets shoved.** Drag a window sideways into him and he's pushed out of the way.
- **Falls.** Close or minimize the window he's on and down he goes, onto the next window, the Dock, or the display below.
- **Skedaddles.** Zoom your cursor at him and he scampers off.
- **Wanders.** He walks, sits, and hops between windows on his own.
- **Throwable.** Grab him with the mouse, drag, and let go to toss him.

## Chatting

- **Click Bonzai** to ask him anything. Replies stream into a classic yellow speech bubble and are spoken aloud (macOS "Fred" voice by default).
- **Right-click** him, or use the paw icon in the menu bar, for jokes, fun facts, Shush, and Settings.
- When you've been idle for a while he pipes up on his own (configurable).

## AI providers

Pick a provider in Settings. Each provider's key is stored in its own Keychain item, and the model is editable.

| Provider | Default model | Key |
|---|---|---|
| Claude (Anthropic) | `claude-opus-5-5` | [console.anthropic.com](https://console.anthropic.com) |
| OpenAI | `chat-latest` | [platform.openai.com](https://platform.openai.com) |
| Google Gemini | `gemini-flash-latest` | [aistudio.google.com](https://aistudio.google.com) |
| OpenRouter | `openrouter/auto` | [openrouter.ai/keys](https://openrouter.ai/keys) |
| Ollama (local) | `llama3.2` | none; just run Ollama |
| Custom | you choose | optional; any OpenAI-compatible `/chat/completions` URL (Groq, xAI, LM Studio, …) |

Claude goes through the native Messages API (low effort for snappy replies, server-side refusal fallback enabled). Everything else uses the OpenAI-compatible Chat Completions protocol.

## Setup

Requires macOS 14+ and Xcode / Swift 5.10+.

```bash
./scripts/build-app.sh
open "build/Bonzai Buddy.app"
```

Then right-click Bonzai → **Settings…**, pick a provider, and paste its API key. For development, `swift run` also picks up `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, or `OPENROUTER_API_KEY` from the environment.

No special permissions are needed. Window positions are read with `CGWindowListCopyWindowInfo`, which exposes window frames without Screen Recording access.

## Layout

| File | What it does |
|---|---|
| `PhysicsEngine.swift` | Gravity, window riding, flings, shoves, wandering, cursor-dodging, click-through |
| `WindowTracker.swift` | Snapshots on-screen window frames |
| `GorillaView.swift` | Procedurally drawn and animated Bonzai (original art) |
| `BuddyView.swift` | Speech bubble, ask box, gestures |
| `Brain.swift` | Conversation, streaming-to-speech, quips |
| `Providers.swift` | Provider list, OpenAI-compatible streaming client |
| `ClaudeClient.swift` | Streaming Claude Messages API client |
| `Speaker.swift` | Text-to-speech |
| `Prefs.swift` | Defaults, per-provider Keychain storage, Settings window |

Not affiliated with BonziBuddy or Bonzi Software. All artwork is original.
