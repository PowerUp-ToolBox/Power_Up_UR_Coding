# Troubleshooting

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

Remote Control problems (text not typing into the target app, no voice
read-back, testing the listener with curl) have their own section in
[Remote Control mode](remote-control.md#troubleshooting-remote-control).

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

**My Accessibility grant disappears every time I rebuild.** That's the
ad-hoc signature changing on each build — see
[stable signing](remote-control.md#accessibility--stable-signing-persistent-permissions)
for the one-time fix.
