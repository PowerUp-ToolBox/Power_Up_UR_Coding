# Configuration & sessions

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

## Where settings live

Most day-to-day settings live in the app itself: **Settings** has tabs for
General (project folder, model, permission mode, claude binary path), Devices
(the Controller, Input and Output slots), Voice (text-to-speech and
speech-to-text options), Buttons (the mapping editor), Feedback (haptics and
light bar toggles), and Remote (Remote Control mode).

Under the hood, configuration is stored as JSON at:

```
~/Library/Application Support/PowerUp/config.json
```

You normally never need to touch this file directly — it's just there for
backup/inspection. If it ever becomes corrupted, PowerUp automatically backs
it up to `config.json.bak` and starts fresh from defaults rather than
crashing. Separately, the first time an app update needs to rewrite the file
in a newer shape (for example the button-mapping format change), PowerUp
keeps a one-time copy of the old file as `config.pre-profiles.json`, so your
bindings are always recoverable.

### Device slots in `config.json`

The three [device slots](controls.md#one-controller-one-microphone-one-speaker)
are three keys. Each is absent (or `null`) by default, which means "pick for
me"; **Settings → Devices** writes them for you.

| Key | Slot | Absent / `null` means | Otherwise |
|---|---|---|---|
| `controllerDeviceID` | Controller | **Automatic**: the most recently connected controller | the pinned controller's id, e.g. `"DualSense/DualSense Wireless Controller"` |
| `audioInputUID` | Input | the system-default microphone | the chosen microphone's Core Audio UID |
| `audioOutputUID` | Output | the system-default output | the chosen speaker's Core Audio UID |

A controller id is the controller's kind and name, with `#2`, `#3`, … added
when an identical controller was already connected (macOS gives PowerUp no
serial number, so two identical controllers are told apart by the order they
connected in). An id that matches no connected controller leaves the
Controller slot empty until that controller connects; delete the key, or
pick **Automatic**, to go back to the default. An empty string is read as absent.

## How sessions & resume work

PowerUp keeps a single long-lived `claude` subprocess running per project,
and **every project folder is its own conversation**: each folder's session
id is remembered separately (`sessionIDsByProject`), so switching folders —
via the folder picker, the Settings → General recents list, or a button
mapped to **Cycle Project** — swaps in that folder's transcript history and
resumes *its* conversation with `--resume`. The recent-folders list keeps the
last 8 you've chosen.
Use **New Session** (in the toolbar, Settings, or mapped to a controller
button) whenever you want to discard that history and start clean. If a
resumed session fails to start (for example because the session ID has gone
stale), PowerUp automatically retries once as a fresh session.

## Transcript history

The transcript survives relaunch: entries are saved per project (as JSON Lines
under `~/Library/Application Support/PowerUp/transcripts/`), and when PowerUp
starts — or you switch project folders — the recent history of that project is
restored into the window, marked with "Earlier conversation restored". Since
sessions resume via `--resume`, that means you see the conversation you're
resuming, not an empty window.

History is a local convenience: about the last 200 entries are restored, files
are trimmed to the newest 2,000 entries automatically, and deleting the
`transcripts` folder (or any file in it) simply clears the scrollback — see
[Privacy](privacy.md) for the full data story.

## Cost display

PowerUp accumulates the `total_cost_usd` reported after each turn and shows
a running total for the current session — useful for keeping an eye on spend
during a long pairing session. This is an estimate reported by the CLI, not a
billing-accurate figure.
