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

## Requirements

- macOS 14 (Sonoma) or later.
- The `claude` CLI installed and logged in (`claude` should work from your
  Terminal). See the [Claude Code docs](https://docs.claude.com/claude-code)
  if you haven't set it up yet.
- A PS5 DualSense controller, paired over Bluetooth (System Settings →
  Bluetooth → pair as usual — hold the PS button + Create button together to
  put the controller into pairing mode).
- Xcode Command Line Tools (for `swift build`), or a full Xcode install.

## Building

From the repository root:

```sh
./scripts/build.sh
```

This runs `swift build -c release`, assembles `build/PowerUp.app`, writes its
`Info.plist`, and ad-hoc code-signs the bundle. It also renders the app icon:
`scripts/IconGen.swift` is compiled with `swiftc` and produces
`build/AppIcon.icns`, which is copied into the bundle's `Resources`. The
generated icon is cached across builds — if you edit `scripts/IconGen.swift`,
force a re-render with:

```sh
REGEN_ICON=1 ./scripts/build.sh
```

When it finishes, launch the
app **as a bundle**, not as a raw binary — this matters because macOS ties
microphone and speech-recognition permissions to the app bundle's identity:

```sh
open build/PowerUp.app
```

## First run

The first time you use push-to-talk, macOS will prompt you for microphone and
speech-recognition permission — approve both, or push-to-talk won't work.
You'll also be asked to choose a project folder on first launch (the
directory PowerUp runs `claude` in); use the folder picker in the toolbar.

Once a project folder is chosen and your controller is connected, PowerUp
spawns a persistent `claude` session for you automatically the moment you
send your first message or press a mapped button.

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

> **A note on the PS button.** It now ships unmapped by default (see below),
> so this mostly doesn't come up — but if you do map something to it,
> depending on your macOS version and setup the PS/home button can be grabbed
> by the system (it may open the Game Overlay or do nothing at all) before
> PowerUp ever sees it. If your mapping doesn't fire, that's why — just remap
> the action to any other free button in **Settings → Buttons**.

> **Upgrading from an older PowerUp?** Your saved `config.json` keeps
> whatever mapping you already had — L1/L2/L3/R3/Touchpad/PS will stay
> wherever you left them until you press **Reset to Defaults** in
> **Settings → Buttons**. Nothing changes underfoot automatically.

### The three core controls

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

### Two ways to talk to Claude

There are two voice actions, and the difference is *when* your words leave the
building:

- **Push to Talk** (R2 by default) — hold, speak, release. The transcript goes
  straight to Claude the moment you let go. Fast, hands-free, no safety net.
- **Dictate to Prompt Box** (L2 by default) — hold, speak, release, and the
  words land in the prompt box at the bottom of the window instead. **Nothing
  is sent.** You get to read it first.

#### Dictate → review → send

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

## Remote Control mode

By default, PowerUp runs its own persistent `claude` session for you. But you
can also use it to **drive an existing Claude Code session** running in another
window — either in a **cmux** workspace, a terminal, or any other app. Your
voice, buttons, and text input go *in*, and Claude's replies come *back* via
text-to-speech and the controller lights/haptics, exactly as if you were using
the built-in session.

### When to use Remote Control

You might prefer this if you're already running Claude Code in a terminal or
`cmux` workspace and want to keep all your context there — or if you're working
with someone else and want to share the session and controller-driven input
without spawning a second Claude process. The controller's full palette of
actions (approve, interrupt, cycle model/effort/permission mode, replay,
etc.) all work the same way.

### Setting up Remote Control

1. **Choose a target:** Open **Settings → Remote** and pick where PowerUp
   should send input. There are three target kinds, and the top of the tab
   always reminds you which two need a permission:

   - **cmux (no permission needed)** — the default, and the easiest option.
     PowerUp drives cmux over its own local control socket (the `cmux` CLI),
     typing text and sending keys straight into a workspace/surface. Because
     this never goes through the OS's keyboard, macOS doesn't ask for
     Accessibility at all. Pick a workspace from the list, or leave it on
     **Auto (selected workspace)** to always target whichever workspace cmux
     currently shows as `[selected]`.
   - **Terminal / specific app** — PowerUp types into a chosen *running* app
     using **keystroke injection** (simulated key presses), which is why this
     kind **requires Accessibility permission**. To save you hunting through a
     list of every running app, a row of one-click presets for common terminal
     apps — **Terminal, iTerm2, Ghostty, WezTerm, Warp, Alacritty** — sits
     above the running-apps picker; click one to set the target bundle
     directly. (cmux is deliberately *not* one of these presets: injecting
     keystrokes into the cmux window would work, but the dedicated **cmux**
     target kind above reaches it over the socket with no permission needed,
     so the UI steers you there instead.)
   - **Frontmost app** — PowerUp types into whatever app happens to be in
     front at the moment you press a mapped button or finish dictating. This
     is also keystroke injection, so it likewise **requires Accessibility
     permission**.
   - **Auto-submit**: if toggled on (default), PowerUp presses Enter after
     typed text to send it immediately; if off, text lands in the input box and
     waits for you to press Enter yourself.

   If you pick an injection target (Terminal/specific app or Frontmost) and
   Accessibility isn't granted yet, PowerUp doesn't wait for a failed send to
   tell you: the **Accessibility** section in Settings → Remote shows an
   "Access needed" state with a one-click **Switch to cmux** button (flips the
   target back to cmux, no permission required), and the same warning appears
   right in the **main window's top info bar** the moment you're in Remote mode
   on an injection target without access — *"Remote typing needs Accessibility
   — use cmux or grant access in Settings → Remote."* Grant access with the
   **Grant Access** button, or open **System Settings → Privacy & Security →
   Accessibility** and add PowerUp to the list manually.

2. **Install Claude Code hooks** (required for voice read-back): PowerUp needs
   to hear when Claude replies, so it installs a small hook into your
   `~/.claude/settings.json` that sends replies to a local listener. Click
   **Install Claude Code hooks** in the **Read-back** section of **Settings →
   Remote**. This will:
   - Create a numbered backup of your `settings.json` (e.g.
     `settings.json.powerup-backup-1`) in case you need to undo it.
   - Add hook definitions for the `Stop`, `UserPromptSubmit`, and
     `Notification` events — these fire for **every Claude Code session** you
     run (including sessions in cmux, Terminal, VS Code, or anything else),
     not just PowerUp.
   - **Automatically start a local listener** on your machine (port 48738 by
     default, token-authenticated) that receives those hooks and feeds replies
     back to PowerUp for text-to-speech and transcript display.
   - The listener is only accessible from your machine (`127.0.0.1`), and all
     requests are validated with an auth token generated and stored in your
     config.
   - You can **uninstall the hooks** from the same tab at any time — it will
     remove only entries it added and preserve your other hook definitions
     verbatim.

3. **Toggle mode**: Use the **Control Mode** picker in **Settings → Remote**
   (Built-in / Remote), or map the **Toggle Built-in / Remote** action to a
   controller button in **Settings → Buttons**. A mode chip in the top info bar
   shows you which mode is active: "Built-in" or "Remote · cmux ws 11" (or app
   name / frontmost).

### How Remote Control works

- **Your input** (voice via push-to-talk, buttons, typed text, etc.) is
  delivered one of two ways depending on the target kind:
  - **cmux target** — shelled out to the `cmux` CLI over its local control
    socket (`cmux send` for text, `cmux send-key` for Enter/Escape/Shift+Tab).
    No macOS permission involved.
  - **Terminal/specific app or Frontmost app** — simulated keystrokes
    (keystroke injection) posted directly to that app, which is why these two
    kinds require Accessibility permission.
- **Claude's replies** stream back via the listener hooks and appear in
  PowerUp's transcript, are read aloud by text-to-speech (if enabled), and
  trigger light/haptic feedback as usual.
- **Session controls** (cycle model, cycle effort, cycle permission mode)
  translate to typed commands (e.g. `/model sonnet`, `/effort high`,
  Shift+Tab for permission mode).
- PowerUp does **not** run a separate `claude` process in remote mode — it's
  purely a remote control for whatever session is already there.
- If the listener detects a reply from a session PowerUp is also running
  locally (unlikely, but possible), it filters it out to avoid echo.

### Troubleshooting Remote Control

**Text isn't appearing in the target app (keystroke injection).** This requires
Accessibility permission — open **Settings → Remote → Accessibility** and make
sure "Grant Access" worked. Or check **System Settings → Privacy & Security →
Accessibility** manually; PowerUp should be in the list. After you add it,
switch back to PowerUp and try again.

**You're sending text but not hearing voice replies.** Check:
1. Look at the status dot in **Settings → Remote → Read-back** — does it say
   "Listener running"? If not, the listener isn't bound; click **Install
   Claude Code Hooks** again to restart it.
2. Are the hooks actually installed? The status line next to the buttons
   should say "Hooks installed". If it says "Hooks not installed", click
   **Install Claude Code Hooks**; if it says "out of date — reinstall", the
   installed script no longer matches your port/token — reinstalling fixes it.
3. Is the Claude Code session actually running in the target app/workspace?
   PowerUp can only read back what exists.
4. Check your firewall — the listener binds to `127.0.0.1:48738` locally; no
   remote traffic should interfere, but a strict localhost firewall could.

**Test the listener directly** (for debugging): the **Token** row in
**Settings → Remote → Read-back** shows the token (with a Copy button), and
**Copy curl Test** puts a ready-made test command on the clipboard. It looks
like this:

```sh
curl -s -X POST \
  -H "X-PowerUp-Token: <token from Settings → Remote → Read-back>" \
  --data '{"hook_event_name":"Stop","last_assistant_message":"hello"}' \
  http://127.0.0.1:48738/event
```

If this returns a 204 response (or no visible output), the listener is running
and authenticating correctly. If you see a 403 or timeout, check the token
matches what's shown in Settings and the listener status dot is green.

---

### Session control actions

Three actions step through a value instead of sending a fixed message —
handy for changing how Claude behaves mid-session without touching a
keyboard:

- **Cycle Model** — advances `Model Cycle` (Settings → General, default
  `sonnet, opus, haiku, fable`) to the next alias and applies it to the
  *running* session immediately, no restart needed.
- **Cycle Effort** — advances through `low → medium → high → xhigh →
  low…`. The `default` setting (which simply omits the `--effort` flag) is
  not part of the cycle — it's only reachable from **Settings → General →
  Effort**. Unlike model and permission mode, effort has no live
  switch: PowerUp restarts the `claude` process with `--effort` and
  `--resume <sessionID>`, so **the conversation is preserved** — you just
  get a brief pause while the session comes back up. If Claude is mid-turn
  when you cycle effort, PowerUp waits for the turn to finish first, then
  restarts.
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

## Configuration

Most day-to-day settings live in the app itself: **Settings** has tabs for
General (project folder, model, permission mode, claude binary path), Voice
(text-to-speech and speech-to-text options), Buttons (the mapping editor),
and Feedback (haptics and light bar toggles).

Under the hood, configuration is stored as JSON at:

```
~/Library/Application Support/PowerUp/config.json
```

You normally never need to touch this file directly — it's just there for
backup/inspection. If it ever becomes corrupted, PowerUp automatically backs
it up to `config.json.bak` and starts fresh from defaults rather than
crashing.

### Replies in other languages are spoken properly

If Claude answers in Chinese — or Japanese, Korean, Spanish, German, or
anything else — PowerUp now detects the language of the reply and reads it
with a **matching installed voice** instead of trying (and failing) to force
it through an English one. A Chinese reply is spoken by a Chinese voice such
as **Tingting**; a Japanese reply by a Japanese voice, and so on. Previously
non-English replies came out silent or garbled; that's fixed.

This happens automatically, per reply — you don't switch anything, and a
conversation that mixes languages is read correctly turn by turn. The voice
you pick in **Settings → Voice** is used whenever the reply is in *that*
voice's language; when the reply is in a different language, PowerUp routes
around your pick rather than staying silent.

If a language sounds robotic (or a reply is still silent), it usually just
means no good voice for that language is installed yet. You can download one
per language: **Settings → Voice → Open Voice Settings** jumps to **System
Settings → Accessibility → Spoken Content → System Voice → Manage Voices…**,
which lists every language macOS offers — expand the one you want and grab an
**Enhanced** or **Premium** voice. It'll be picked up the next time Claude
replies in that language, with no restart needed.

### Getting a better voice

macOS ships a serviceable default voice, but it can sound noticeably
robotic. For much clearer text-to-speech, open **Settings → Voice** and
click **Open Voice Settings** — this jumps straight to **System Settings →
Accessibility → Spoken Content → System Voice → Manage Voices…**, where you
can download any **Enhanced** or **Premium** quality voice. Once it's
downloaded, pick it from the Voice picker in PowerUp's Voice tab. The picker
lists real voices in every installed language (no novelty voices like Zarvox,
no legacy "compact" voices), labelled with their language and quality — for
example `Tingting (zh-CN) · Default`.

The "Max spoken characters" stepper in the same tab can be set all the way
down to **0**, which means *no limit* — Claude's full reply is read aloud
instead of being truncated.

## How sessions & resume work

PowerUp keeps a single long-lived `claude` subprocess running per project.
The session ID it's given is remembered (`lastSessionID` in the config) so
that relaunching PowerUp can resume the same conversation with `--resume`.
Use **New Session** (in the toolbar, Settings, or mapped to a controller
button) whenever you want to discard that history and start clean. If a
resumed session fails to start (for example because the session ID has gone
stale), PowerUp automatically retries once as a fresh session.

## Interrupting Claude

Pressing **Interrupt** (Circle by default, or mapped to any other button)
sends a stop request to the running `claude` process using its documented
control-request protocol, which safely halts the current turn without
ending the session or losing conversation history — you can keep talking
right away. If nothing is running yet, Interrupt is a no-op and PowerUp
tells you there's nothing to interrupt rather than pretending it worked.

## Cost display

PowerUp accumulates the `total_cost_usd` reported after each turn and shows
a running total for the current session — useful for keeping an eye on spend
during a long pairing session. This is an estimate reported by the CLI, not a
billing-accurate figure.

## Troubleshooting

**Microphone or speech recognition isn't working / I denied the permission
prompt by mistake.** Reset the permissions and relaunch the app so macOS
asks again:

```sh
tccutil reset Microphone com.powerup.claudepad
tccutil reset SpeechRecognition com.powerup.claudepad
```

**The controller doesn't respond when PowerUp isn't the frontmost app.**
PowerUp explicitly enables background controller monitoring on launch, so
this should work out of the box. If it doesn't, try re-pairing the
controller: forget it in System Settings → Bluetooth, then hold PS + Create
to re-enter pairing mode and pair again.

**PowerUp says it can't find the `claude` binary.** Open **Settings →
General** and set the "Claude binary path" override to the output of
`which claude` (or `command -v claude`) run in the same shell you normally
use it from.

**Nothing happens when I launch the app / permissions seem broken.** Make
sure you launched the built `.app` bundle with `open build/PowerUp.app`
rather than running the executable inside it directly — TCC (permissions)
tracks the bundle identity, and running the raw binary will misattribute or
silently deny permission requests.

## Accessibility & stable signing (persistent permissions)

**If you only use cmux remote targets, you can ignore Accessibility entirely** —
cmux drives the session over its own socket, so PowerUp never needs it. The
"Access needed" note in Settings → Remote only applies to the *Frontmost App* and
*Specific App* injection targets.

If you *do* want those app-injection targets, macOS needs an Accessibility grant —
but there's a catch for a locally-built app: the default build is **ad-hoc signed**,
and every rebuild gets a new signature, so macOS treats it as a new app and drops
your grant. To make the grant **persist across rebuilds**, create a stable
self-signed identity once:

```bash
./scripts/setup-signing.sh     # asks for your macOS password once (trust step)
./scripts/build.sh             # now signs with the stable identity automatically
tccutil reset Accessibility com.powerup.claudepad   # clear any stale grant
open build/PowerUp.app          # grant Accessibility once — it now sticks
```

`build.sh` uses the stable identity automatically whenever it exists, and falls
back to ad-hoc signing otherwise (so a fresh clone still builds with no setup).

## cmux remote target — enabling automation access (one-time)

cmux ships with its automation socket locked to `cmuxOnly`, so it rejects control
from any app it didn't launch — including PowerUp (you'll see "cmux refused the
connection"). To let PowerUp drive a cmux session:

1. In cmux: **Settings → Automation → Socket control mode** → choose **Password**
   (recommended) or **Automation**. For Password mode, set a password.
2. **Quit and reopen cmux** — this setting only takes effect on restart.
3. In PowerUp: **Settings → Remote**, Target = **cmux**, and (Password mode) type
   the same password into "cmux socket password". Click **Test connection** — it
   should flip to "cmux is available" and list your workspaces.

No Accessibility permission is needed for the cmux target. (The Terminal / Frontmost
targets use keystroke injection instead and require Accessibility.)
