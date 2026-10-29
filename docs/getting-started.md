# Getting started

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

## Requirements

- macOS 14 (Sonoma) or later.
- The `claude` CLI installed and logged in (`claude` should work from your
  Terminal). See the [Claude Code docs](https://docs.claude.com/claude-code)
  if you haven't set it up yet.
- Optionally, a PS5 DualSense controller, paired over Bluetooth (System
  Settings → Bluetooth → pair as usual — hold the PS button + Create button
  together to put the controller into pairing mode). The controller is the
  best way to drive PowerUp, but not a requirement — dictation and every
  other control also work from the
  [keyboard and mouse](controls.md#no-controller-keyboard-and-mouse-cover-everything).
- A full Xcode install (the Command Line Tools alone are not enough: the
  build uses `xcodebuild`).
- [Rust](https://rustup.rs), installed with rustup. Part of PowerUp's logic
  lives in a Rust core that every build compiles; rustup fetches the exact
  compiler version on first use.

## Building

From the repository root:

```sh
./scripts/build.sh
```

This builds the Rust core (`./scripts/build-core.sh`), runs
`swift build -c release`, assembles `build/PowerUp.app`, writes its
`Info.plist`, and ad-hoc code-signs the bundle. It also renders the app icon:
`scripts/IconGen.swift` is compiled with `swiftc` and produces
`build/AppIcon.icns`, which is copied into the bundle's `Resources`. The
generated icon is cached across builds — if you edit `scripts/IconGen.swift`,
force a re-render with:

```sh
REGEN_ICON=1 ./scripts/build.sh
```

Working on the code? `swift build` and `swift test` need the Rust core built
first: run `./scripts/build-core.sh debug` once, and again after any change
under `rust/`. Without it the build stops with a message saying so.

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

Once a project folder is chosen, PowerUp spawns a persistent `claude` session
for you automatically the moment your first message is sent — typed, dictated
and then sent with ⌘↩, spoken with ⇧⌘D, or fired from a mapped controller
button. (Merely starting a dictation doesn't spawn anything.)

## Next steps

- Learn the [buttons and controls](controls.md) — especially the three core
  controls that cover the whole conversational loop.
- Set up [voice and speech](voice.md) — including how to get a much
  nicer-sounding voice.
- Want to drive a Claude Code session that's already running in a terminal or
  cmux? See [Remote Control mode](remote-control.md).
