# PowerUp — a DualSense remote for Claude Code

PowerUp turns a PS5 DualSense controller into a hands-on remote for
[Claude Code](https://www.anthropic.com/claude-code). Hold a trigger to speak
an instruction, hear Claude's replies read back to you, and map every button
on the controller to whatever action fits your workflow — approve a change,
interrupt a turn, replay the last reply, fire off a canned prompt, and more.
Prefer to check your words before they go out? Hold the other trigger and
dictate into the prompt box instead, then edit and send when you're happy.
The controller's light bar and haptics mirror what your Claude session is
doing, so you always know at a glance whether it's idle, listening, thinking,
or speaking.

This is a native macOS app built with SwiftUI. No Xcode project required to
build it — just Swift Package Manager.

## The bigger picture

What exists today — macOS, DualSense, Claude Code — is **v1 of a much larger
open-source ambition**: let anyone vibe code hands-free with **any device**
(game controller, headset buttons, foot pedal, macropad, voice alone) driving
**any AI coding harness** (Claude Code, Codex CLI, Gemini CLI, opencode, …) on
**any OS** (macOS, Windows, Linux) — with the device giving live feedback
(lights, haptics, screens) about what your agent is doing.

The full plan lives in **[DEVELOPMENT.md](DEVELOPMENT.md)**; how to get
involved is in **[CONTRIBUTING.md](CONTRIBUTING.md)**. Contributions, device
ideas, and harness requests are all welcome — open an issue or a discussion.

## Quick start

```sh
./scripts/build.sh        # release build → build/PowerUp.app
open build/PowerUp.app    # always launch as a bundle (macOS permissions
                          # track the bundle identity)
```

You'll need macOS 14+, the `claude` CLI logged in, a DualSense paired over
Bluetooth, and the Xcode Command Line Tools. On first use, approve the
microphone and speech-recognition prompts and pick a project folder — full
details in **[Getting started](docs/getting-started.md)**.

## The three core controls

Once your controller is paired, three buttons cover the whole conversational
loop with Claude:

- **L2 — dictate to the prompt box.** Hold, speak, release; your words land
  in the prompt box for review. Nothing is sent yet.
- **L1 — send the prompt box.** Whatever's sitting in the box (typed,
  dictated, or a mix) goes to Claude right now.
- **R2 — talk straight to Claude.** Hold, speak, release; the transcript is
  sent the instant you let go, no review step.

Everything else — approve (✕), interrupt (○), quick prompts on the D-pad,
cycling model/effort/permission mode on the sticks and touchpad — builds on
that loop, and every button is remappable in **Settings → Buttons**. The full
default mapping table is in **[Buttons & controls](docs/controls.md)**.

## Documentation

| Guide | What's in it |
|---|---|
| [Getting started](docs/getting-started.md) | Requirements, building, first run, permissions |
| [Buttons & controls](docs/controls.md) | Full default mapping, dictate→review→send, cycle model/effort/permission, interrupting |
| [Voice & speech](docs/voice.md) | Multilingual read-back, getting a better voice, spoken-length limit |
| [Remote Control mode](docs/remote-control.md) | Driving an existing session in cmux or a terminal, hooks setup, Accessibility & stable signing |
| [Configuration & sessions](docs/configuration.md) | Settings, `config.json`, session resume, cost display |
| [Troubleshooting](docs/troubleshooting.md) | Permission resets, controller, `claude` binary issues |
| [Privacy](docs/privacy.md) | Where your voice and data go (spoiler: mostly nowhere) |
| [The PowerUp protocol](docs/protocol.md) | Build your own device plugin or UI against the local WebSocket API |

For contributors: [CONTRIBUTING.md](CONTRIBUTING.md) (build/test/PR rules),
[DESIGN.md](DESIGN.md) (the binding implementation contract), and
[DEVELOPMENT.md](DEVELOPMENT.md) (roadmap, architecture, workstreams).
