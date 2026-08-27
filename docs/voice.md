# Voice & speech

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

Voice settings live in **Settings → Voice**: text-to-speech on/off, voice
picker, speaking rate, max spoken characters, and the speech-to-text locale
and on-device options.

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
