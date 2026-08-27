# Remote Control mode

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

By default, PowerUp runs its own persistent `claude` session for you. But you
can also use it to **drive an existing Claude Code session** running in another
window — either in a **cmux** workspace, a terminal, or any other app. Your
voice, buttons, and text input go *in*, and Claude's replies come *back* via
text-to-speech and the controller lights/haptics, exactly as if you were using
the built-in session.

## When to use Remote Control

You might prefer this if you're already running Claude Code in a terminal or
`cmux` workspace and want to keep all your context there — or if you're working
with someone else and want to share the session and controller-driven input
without spawning a second Claude process. The controller's full palette of
actions (approve, interrupt, cycle model/effort/permission mode, replay,
etc.) all work the same way.

## Setting up Remote Control

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

## How Remote Control works

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

## Troubleshooting Remote Control

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
