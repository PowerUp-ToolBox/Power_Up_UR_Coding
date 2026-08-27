# Configuration & sessions

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

## Where settings live

Most day-to-day settings live in the app itself: **Settings** has tabs for
General (project folder, model, permission mode, claude binary path), Voice
(text-to-speech and speech-to-text options), Buttons (the mapping editor),
Remote (Remote Control mode), and Feedback (haptics and light bar toggles).

Under the hood, configuration is stored as JSON at:

```
~/Library/Application Support/PowerUp/config.json
```

You normally never need to touch this file directly — it's just there for
backup/inspection. If it ever becomes corrupted, PowerUp automatically backs
it up to `config.json.bak` and starts fresh from defaults rather than
crashing.

## How sessions & resume work

PowerUp keeps a single long-lived `claude` subprocess running per project.
The session ID it's given is remembered (`lastSessionID` in the config) so
that relaunching PowerUp can resume the same conversation with `--resume`.
Use **New Session** (in the toolbar, Settings, or mapped to a controller
button) whenever you want to discard that history and start clean. If a
resumed session fails to start (for example because the session ID has gone
stale), PowerUp automatically retries once as a fresh session.

## Cost display

PowerUp accumulates the `total_cost_usd` reported after each turn and shows
a running total for the current session — useful for keeping an eye on spend
during a long pairing session. This is an estimate reported by the CLI, not a
billing-accurate figure.
