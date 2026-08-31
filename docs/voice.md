# Voice & speech

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

Voice settings live in **Settings → Voice**: text-to-speech on/off, voice
picker, speaking rate, max spoken characters, and the speech-recognition
language and on-device options.

## The language you speak (speech recognition)

Push-to-talk transcribes what you say **in the language selected under
Settings → Voice → Speech Recognition** (default: English, United States).
This is the single most important voice setting: if it doesn't match the
language you're actually speaking, recognition doesn't get "a bit worse" — it
produces gibberish or the wrong script entirely. The listening banner shows a
reminder whenever a non-English recognition language is active.

Two related notes:

- **On-device recognition** keeps audio on your Mac and works offline, but is
  noticeably less accurate than Apple's server recognition. Leave it **off**
  for the best results unless privacy/offline matters more to you.
- The recognition language (what you *say*) is independent of the read-back
  voices (what you *hear*) — Claude's replies are read in whatever language
  they arrive in, automatically, regardless of this setting.

## Replies in other languages are spoken properly

If Claude answers in Chinese — or Japanese, Korean, Spanish, German, or
anything else — PowerUp detects the language of the reply and reads it
with a **matching installed voice** instead of trying (and failing) to force
it through an English one. A Chinese reply is spoken by a Chinese voice such
as **Tingting**; a Japanese reply by a Japanese voice, and so on.

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

## Spoken summaries — hear the conclusion, not the essay

Long replies can take minutes to read aloud. Turn on **Settings → Voice →
"Summarize long replies (uses a fast model)"** and PowerUp will instead have a
lightweight model (Haiku, through your existing `claude` login — no extra
setup) write a one-to-two-sentence conclusion of any long reply and speak
*that*: what was done, and anything you need to do next.

The details, honestly stated:

- **Off by default** — each summary is a real model call (a fraction of a
  cent, a few seconds of latency before speech starts).
- Short replies are spoken directly; only replies past a few hundred
  characters get summarized.
- **Nothing is lost**: the full reply is still in the transcript, the summary
  appears there too (as "Summary: …"), and **Replay Last Reply always reads
  the full reply**.
- If the summary can't be produced (offline, timeout, whatever), PowerUp
  falls back to speaking the full reply — the toggle can never silence you.
- Replies in other languages get summaries in their language, read by the
  matching voice.

## Getting a better voice

macOS ships a serviceable default voice, but it can sound noticeably
robotic. For much clearer text-to-speech, open **Settings → Voice** and
click **Open Voice Settings** — this jumps straight to **System Settings →
Accessibility → Spoken Content → System Voice → Manage Voices…**, where you
can download any **Enhanced** or **Premium** quality voice. Once it's
downloaded, pick it from the Voice picker in PowerUp's Voice tab. The picker
lists real voices in every installed language (no novelty voices like Zarvox,
no legacy "compact" voices), labelled with their language and quality — for
example `Tingting (zh-CN) · Default`.

## How much of a reply is read aloud

The "Max spoken characters" stepper in the Voice tab caps how much of a long
reply is spoken (the rest is truncated at a sentence boundary with a spoken
"reply truncated" note). It can be set all the way down to **0**, which means
*no limit* — Claude's full reply is read aloud instead of being truncated.

## Choosing your microphone and speaker

By default PowerUp listens on the system-default microphone and speaks
through the system-default output. **Settings → Voice → Audio Devices** lets
you pin either one — dictate through a USB mic while replies play through
your headphones, or the other way around.

Devices are remembered even when unplugged: if your chosen device disappears
mid-session, PowerUp announces it in the transcript, falls back to the system
default, and switches back automatically the moment the device returns. A
disconnected pick shows in the menu as "(Disconnected device)" so you always
see what's configured.
