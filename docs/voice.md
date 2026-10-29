# Voice & speech

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

Voice settings live in **Settings → Voice**: text-to-speech on/off, voice
picker, speaking rate, max spoken characters, and the speech-recognition
language and on-device options. The microphone and speaker themselves are
the Input and Output slots in **Settings → Devices**
([below](#input-and-output-your-microphone-and-speaker)).

You don't need a controller to use your voice: click the **mic button** next
to the prompt box (or press **⌘D**) to start and stop dictation, and **⇧⌘D**
to talk straight to Claude. Details in
[Buttons & controls](controls.md#no-controller-keyboard-and-mouse-cover-everything).

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

How the language is decided, honestly stated:

- **Code doesn't count.** A fenced code block is left out before the
  language is decided, so a Chinese reply full of English identifiers in
  code is still read by a Chinese voice. The block itself is read as "code
  omitted" (in a Chinese reply, "代码已省略").
- **Chinese, Japanese and Korean are recognized by their script**, even in
  short or mixed text: any kana means Japanese, hangul means Korean, and
  Chinese characters alone mean Chinese. So a Japanese phrase written only
  in kanji, with no kana at all, reads as Chinese; an ordinary Japanese
  reply has kana and reads as Japanese. Full-width punctuation, digits and
  letters (`！`, `１２３`, `ＯＫ`) don't count as any of these scripts. A
  Chinese or Korean reply that quotes a Japanese word in kana (「ログイン」)
  reads as Japanese, because the kana decide.
- **Other languages need more than a guess.** For a language written in
  Latin or Cyrillic letters (Spanish, German, Czech, Russian and the rest),
  the detector's guess is only used when the reply's letters belong to
  that language's alphabet and the reply's small common words ("und",
  "les", "jsem", "что") point to that language and no other. Short,
  terse technical English otherwise fooled the guess into French or
  Portuguese. For a language written in another script (Arabic, Hindi,
  Greek, Hebrew, Thai and the rest), the guess must be a confident one.
- **When PowerUp isn't sure, it reads in English.** Very short replies
  ("OK", "Done."), lists of names or paths, and sentences whose common
  words don't settle the language (Danish and Norwegian share most of
  theirs, as do Czech and Slovak), and a short Hindi or Arabic note that
  is mostly English identifiers are read by an English voice rather than
  risk a wrong one. So now and then a short reply in another
  language is read in English. A few languages macOS can name but
  PowerUp's detector can't (Icelandic, Kazakh, Lao, Tibetan and Cherokee
  among them) are always read in English.
- PowerUp's own spoken confirmations (such as "Model: Sonnet") are always
  English.

These text rules are the same on every operating system PowerUp runs on, so
a reply is read the same way and in the same language everywhere; the
voices themselves are each system's own.

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
The limit counts characters as you see them (an emoji or an accented letter
is one), after markdown is removed, and a cut is never made inside one. A
sentence may end with `.`, `!`, `?`, `…` or the full-width `。`, `！` and
`？`; with none in range the reply is cut at the limit. A Chinese reply ends
with "……回复已截断。" instead of the English note. Spoken summaries are never
cut.

## Input and Output: your microphone and speaker

PowerUp listens on one microphone, the **Input** slot, and speaks through
one speaker, the **Output** slot. Both sit in **Settings → Devices**, next to
the **Controller** slot (see
[Buttons & controls](controls.md#one-controller-one-microphone-one-speaker)).
By default Input is the system-default microphone and Output the
system-default output. Pin either one to a specific audio device — dictate
through a USB mic while replies play through your headphones, or the other
way around.

Your Input and Output picks are remembered even when unplugged: if a chosen
audio device disappears mid-session, PowerUp announces it in the transcript,
falls back to the system default, and switches back automatically the
moment the device returns. A disconnected pick shows in the menu as
"(Disconnected device)" so you always see what's configured.

If your chosen microphone disconnects *while you are recording*, the
recording stops right there with the error buzz, and nothing is sent or left
in the prompt box: a half sentence never reaches the agent. Just record
again; the new recording uses the system default until your microphone
returns.
