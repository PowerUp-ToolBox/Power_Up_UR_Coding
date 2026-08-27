# Getting started

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

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

When it finishes, launch the app **as a bundle**, not as a raw binary — this
matters because macOS ties microphone and speech-recognition permissions to
the app bundle's identity:

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

## Next steps

- Learn the [buttons and controls](controls.md) — especially the three core
  controls that cover the whole conversational loop.
- Set up [voice and speech](voice.md) — including how to get a much
  nicer-sounding voice.
- Want to drive a Claude Code session that's already running in a terminal or
  cmux? See [Remote Control mode](remote-control.md).
