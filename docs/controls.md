# Buttons & controls

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

## Default button mapping

| Button | Action |
|---|---|
| R2 (trigger) | Push to Talk (hold to record, release to send) |
| Cross (✕) | Approve (sends "Yes") |
| Circle (○) | Interrupt (stops Claude's current turn) |
| Square (□) | Send prompt: "Continue" |
| Triangle (△) | Stop Speaking |
| L1 | Send Prompt Box |
| R1 | Toggle Speech (TTS on/off) |
| D-Pad Up | Send prompt: "Run the tests and report the results" |
| D-Pad Down | Send prompt: "Explain what you just did, briefly" |
| D-Pad Left | Send prompt: "Undo the last change you made" |
| D-Pad Right | Send prompt: "Commit the current changes with a good message" |
| Options | New Session |
| Create | Show Window |
| L3 (Left Stick Click) | Cycle Model |
| R3 (Right Stick Click) | Cycle Effort |
| Touchpad | Cycle Permission Mode |
| L2 (trigger) | Dictate to Prompt Box (hold to dictate; nothing is sent) |
| PS | None (unmapped by default — free for you to use) |

Every mapping is fully customizable from **Settings → Buttons**, including
retargeting the built-in actions or attaching your own custom prompts.
"Reset to Defaults" restores the table above at any time. The **All
Buttons…** button under the Controls card (left sidebar) opens a full
cheat-sheet sheet listing all 18 controller buttons and whatever each one is
currently mapped to — handy when you've customized things and forgotten
what's where.

> **A note on the PS button.** It ships unmapped by default, so this mostly
> doesn't come up — but if you do map something to it, depending on your macOS
> version and setup the PS/home button can be grabbed by the system (it may
> open the Game Overlay or do nothing at all) before PowerUp ever sees it. If
> your mapping doesn't fire, that's why — just remap the action to any other
> free button in **Settings → Buttons**.

> **Upgrading from an older PowerUp?** Your saved `config.json` keeps
> whatever mapping you already had — L1/L2/L3/R3/Touchpad/PS will stay
> wherever you left them until you press **Reset to Defaults** in
> **Settings → Buttons**. Nothing changes underfoot automatically.

## The three core controls

Once your controller is paired, three buttons cover the whole conversational
loop with Claude:

- **L2 — dictate to the prompt box.** Hold, speak, release; your words land
  in the prompt box for review. Nothing is sent yet.
- **L1 — send the prompt box.** Whatever's sitting in the box (typed,
  dictated, or a mix) goes to Claude right now.
- **R2 — talk straight to Claude.** Hold, speak, release; the transcript is
  sent the instant you let go, no review step.

Everything else on the pad — approve/interrupt/quick prompts/session
controls — builds on top of that core loop.

## Two ways to talk to Claude

There are two voice actions, and the difference is *when* your words leave the
building:

- **Push to Talk** (R2 by default) — hold, speak, release. The transcript goes
  straight to Claude the moment you let go. Fast, hands-free, no safety net.
- **Dictate to Prompt Box** (L2 by default) — hold, speak, release, and the
  words land in the prompt box at the bottom of the window instead. **Nothing
  is sent.** You get to read it first.

### Dictate → review → send

This is the flow to use when the instruction matters and you'd rather not
discover a misheard filename halfway through a refactor:

1. **Hold L2** and say what you want. The words stream into the prompt box
   live, as you speak — you can watch the sentence build up.
2. **Release L2.** The final transcript stays in the box. Claude hasn't seen
   anything yet.
3. **Edit it** if the recognizer got a name or a path wrong — click into the
   box and fix it like any other text field.
4. **Send it** with **L1** (Send Prompt Box), the send arrow in the
   window, or by pressing **Return** in the box. Typed text and dictated text
   go out through exactly the same door.

A few details worth knowing:

- If the box already has text in it, dictation is **appended** after it (with a
  space), so you can dictate a sentence, type a correction, and dictate some
  more.
- If nothing usable was heard, PowerUp puts the box back exactly as it was and
  buzzes the controller twice — your typed text is never eaten by a failed
  dictation.
- Holding a second voice button while one is already recording does nothing;
  only the button that started the recording can end it.
- **In [Remote Control mode](remote-control.md)** the review happens where
  your session lives: releasing L2 **types the words into the remote input
  box** (cmux or the terminal) without pressing Enter — edit them there if
  needed, then send with **L1** (with PowerUp's own box empty, Send Prompt Box
  presses Enter in the target), the Approve button (✕), or Enter in that app.
  The L2 → L1 flow works the same in both modes.

## Session control actions

Three actions step through a value instead of sending a fixed message —
handy for changing how Claude behaves mid-session without touching a
keyboard:

- **Cycle Model** — advances `Model Cycle` (Settings → General, default
  `sonnet, opus, haiku, fable`) to the next alias and applies it to the
  *running* session immediately, no restart needed.
- **Cycle Effort** — advances through `low → medium → high → xhigh →
  ultra → low…`. **Ultra** is more than a level: it runs Claude Code at
  maximum effort *and* asks it to orchestrate dynamic multi-agent workflows
  on substantial tasks (your prompts carry the `ultracode` keyword) — expect
  deeper, slower, costlier turns. Built-in Claude Code only; ACP harnesses
  have no effort setting. The `default` setting (which simply omits the `--effort` flag) is
  not part of the cycle — it's only reachable from **Settings → General →
  Effort**. Unlike model and permission mode, effort has no live
  switch: PowerUp restarts the `claude` process with `--effort` and
  `--resume <sessionID>`, so **the conversation is preserved** — you just
  get a brief pause while the session comes back up. If Claude is mid-turn
  when you cycle effort, PowerUp waits for the turn to finish first, then
  restarts.
- **Cycle Project** *(unmapped by default — assign it in Settings → Buttons)*
  — steps through your recent project folders. **Each folder is its own
  conversation**: its transcript history swaps in and its own session resumes,
  so you can bounce between several pieces of work from the pad. Folders join
  the recent list whenever you pick them with the folder picker (kept in
  Settings → General → Project, up to 8).
- **Cycle Session Focus** *(unmapped by default; Remote Control mode)* — when
  several Claude sessions are running (cmux workspaces, background agents),
  every reply is spoken by default. Focus steps through **All → each active
  session → All**; with a focus set, only that session is read aloud, buzzes,
  and drives the amber light — everything else still logs (folder-prefixed)
  in the transcript. The focused folder shows as an amber chip in the top bar.
- **Cycle Permission Mode** — advances through `acceptEdits → plan →
  default → acceptEdits…` and applies live. `bypassPermissions` is
  deliberately left out of this cycle — a stray button press should never
  silently escalate to auto-approving everything; switch to it explicitly
  in Settings → General if you want it.

Each cycle announces what changed as a spoken phrase (e.g. "Effort: high")
when TTS is on, and always logs a note in the transcript. The current
model, effort, and permission mode are also shown live as capsule chips in
the **top info bar** — the strip across the top of the window, above the
transcript, that also shows the controller's name/battery and the session
status pill — so a controller-driven change is visible at a glance and
updates the instant it happens. If the CLI rejects a change, PowerUp reverts
the setting and shows an error in the transcript rather than leaving the app
and the session out of sync.

## Interrupting Claude

Pressing **Interrupt** (Circle by default, or mapped to any other button)
sends a stop request to the running `claude` process using its documented
control-request protocol, which safely halts the current turn without
ending the session or losing conversation history — you can keep talking
right away. If nothing is running yet, Interrupt is a no-op and PowerUp
tells you there's nothing to interrupt rather than pretending it worked.
