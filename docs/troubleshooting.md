# Troubleshooting

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

Remote Control problems (text not typing into the target app, no voice
read-back, testing the listener with curl) have their own section in
[Remote Control mode](remote-control.md#troubleshooting-remote-control).

**My dictation comes out as gibberish, the wrong words, or the wrong
script.** Almost always a recognition-language mismatch: **Settings → Voice →
Speech Recognition** must be set to the language you're actually speaking
(e.g. English (United States)). Also make sure **On-device recognition** is
off — the on-device engine is noticeably less accurate. And check **System
Settings → Sound → Input**: if a Bluetooth headset mic was auto-selected, its
telephone-quality audio hurts recognition badly — the Mac's built-in mic
usually transcribes better.

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

**Settings → Remote shows Accessibility red even though System Settings shows
PowerUp enabled.** The System Settings toggle is stale: macOS binds the grant
to the app's exact code signature, and an ad-hoc-signed build gets a *new*
signature on every rebuild — so the listed entry refers to a previous build
and no longer applies (PowerUp's red dot is telling the truth). The fix, once:

```sh
./scripts/setup-signing.sh                            # stable identity (one password dialog)
./scripts/build.sh                                    # rebuild, now stably signed
tccutil reset Accessibility com.powerup.claudepad     # clear the stale entries
open build/PowerUp.app                                # grant once — it now sticks forever
```

See [stable signing](remote-control.md#accessibility--stable-signing-persistent-permissions)
for the background. (cmux targets never need Accessibility at all.)
