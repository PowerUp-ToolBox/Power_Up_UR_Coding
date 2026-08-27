# Privacy

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

PowerUp is a local app. It contains **no telemetry, no analytics, and no
accounts** — nothing about your usage is collected by the PowerUp project.
Here is exactly where your data goes:

## Your voice

- **Speech-to-text** uses Apple's speech recognition. With **Settings → Voice
  → On-device recognition** turned **on**, audio is processed entirely on your
  Mac and never leaves it. With it **off** (the default, which is usually more
  accurate), macOS may send audio to Apple's servers for recognition under
  [Apple's privacy terms](https://www.apple.com/legal/privacy/). PowerUp
  itself never stores or transmits your audio anywhere.
- **Text-to-speech** (`AVSpeechSynthesizer`) runs entirely on your Mac.

## Your conversations

- What you send to Claude — spoken or typed — goes to **Anthropic** through
  the `claude` CLI, exactly as if you had typed it into Claude Code yourself.
  PowerUp adds no other network destination for your prompts.
- The transcript shown in the window is stored **locally** per project (under
  `~/Library/Application Support/PowerUp/`) so a resumed session shows its
  history. Delete that folder at any time to erase it.

## The local listener

- Remote Control read-back runs a small HTTP listener bound to
  **127.0.0.1 only** (never a network interface), authenticated with a random
  token stored in your local config. Claude Code hooks on your own machine
  POST to it; nothing remote can reach it.

## Configuration

- All settings live in `~/Library/Application Support/PowerUp/config.json`
  on your Mac, including the listener token. Nothing is synced anywhere.

Any future feature that changes this — for example an optional cloud speech
backend — will be **opt-in and clearly labeled**, never a default.
