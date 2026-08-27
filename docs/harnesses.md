# Harnesses — using PowerUp beyond Claude Code

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

PowerUp's built-in session doesn't have to be Claude Code. **Settings →
General → Harness** picks what the controller and your voice actually drive:

| Choice | What runs | Notes |
|---|---|---|
| **Claude Code (built-in)** | The `claude` CLI over its streaming protocol | The default. Full feature set: live model switch, effort, cost display, session resume |
| **ACP agent → opencode** | [opencode](https://opencode.ai) natively | Needs `opencode` installed and logged in (`opencode auth login`) |
| **ACP agent → Claude Code (ACP bridge)** | Claude Code through the standard [Agent Client Protocol](https://agentclientprotocol.com) bridge | Same login as the CLI; useful as a fallback path |
| **ACP agent → Custom command** | Any ACP-speaking agent you point it at | e.g. a Codex or Gemini ACP bridge — paste the command line |

Switching takes effect with your **next message** (the old session is
stopped; nothing is sent anywhere until you speak or type again). Everything
else works the same regardless of harness: push-to-talk, dictate-to-draft,
TTS read-back, spoken summaries, light bar, haptics, transcript history.

## Approving what the agent does — from the controller

ACP agents ask before running tools (depending on their permission mode).
When that happens, PowerUp buzzes, says **"Approval needed"**, and the
transcript shows what the agent wants — e.g. *"The agent wants to: Edit
main.swift. Press ✕ to allow or ○ to deny."*

- **✕ (Approve)** allows it — always as *allow once*, never "always allow":
  a controller press must not silently grant standing permissions.
- **○ (Reject)** denies it (also *once*).
- A request left hanging when the turn ends or you interrupt is cancelled
  automatically — the agent never waits on a button you'll never press.

## Honest limitations of ACP harnesses (today)

- **Model names are the agent's own.** The Model setting and Model Cycle list
  must use ids the agent knows (opencode examples:
  `openai/gpt-5.3-chat-latest`) — or leave Model on **Default** and let the
  agent decide. Unknown ids are rejected by the agent and PowerUp rolls the
  setting back.
- **No effort setting** — Cycle Effort tells you so instead of pretending.
- **No cost display** — ACP doesn't report dollars; the cost readout stays
  at zero for ACP sessions.
- **No session resume** — an ACP session starts fresh each time (the
  transcript history in the window still restores as usual).
- **Codex / Gemini**: not preinstalled presets yet — install their ACP
  bridge and use *Custom command*. First-class presets land when we can
  verify them live (issue #9).

## Troubleshooting

**"Couldn't find the … command"** — the agent isn't installed where PowerUp
looks (`~/.opencode/bin`, `/opt/homebrew/bin`, `/usr/local/bin` for opencode;
`npx` for the bridge). Install it, or use *Custom command* with the full
path.

**"The ACP agent couldn't create a session. Is it logged in?"** — run the
agent's login once in a terminal (e.g. `opencode auth login`), then send
your message again.

**The reply chip shows a strange model name** — that's the agent's real
model id (e.g. `opencode/big-pickle` is opencode's default alias); pick a
specific one in Settings → General → Model if you prefer.
