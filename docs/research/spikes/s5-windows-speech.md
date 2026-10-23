# S5: Windows speech engine comparison

- **Spike:** S5 of `PLAN-any-device-any-os.md` stage 1, step 8; ticket #135, epic #95.
- **Status:** PENDING (needs a Windows 11 machine, a microphone and the maintainer's voice).
- **Time box:** 1 day.
- **Feeds:** the Windows row of ADR 0011 (per-OS speech defaults).
- **Kit:** [`s5-windows-speech/`](s5-windows-speech/) and
  [`windows-common/collect-versions.ps1`](windows-common/collect-versions.ps1).
  `run-whisper.ps1` and `score.ps1` were exercised on PowerShell 7.4 (Linux container)
  with a mock `whisper-cli`; `record-clips.ps1`, `run-sapi.ps1` and `run-winrt-live.ps1`
  need Windows and have only been parse-checked.

## Question

On the maintainer's Windows machine, with his own mixed Chinese-English speech full of
code identifiers, how fast and how accurate are:

1. **whisper.cpp `small`**, automatic language detection,
2. **whisper.cpp `base`**, automatic language detection,
3. **the platform's offline recognizer** with the Chinese pack,

and does `small` meet the GO threshold (median latency under 2.5 s with acceptable
identifier accuracy)?

Optional extra rows: `small` with a vocabulary `--prompt` (the biasing the plan names for
#22), a GPU build of whisper.cpp, and WinRT live dictation.

## Engines and what "latency" means

| Engine | How it is run | Latency measured |
|---|---|---|
| whisper.cpp `small` / `base` | `whisper-cli.exe` once per clip, as the planned adapter would (subprocess per utterance) | wall clock from process start to exit, **including model load**; whisper's own `load time` and `total time` are recorded too, so a warm (persistent-process) estimate is `wall - load` |
| Platform offline: System.Speech (SAPI desktop recognizer, `zh-CN`, dictation grammar) | `run-sapi.ps1`, engine loaded once, WAV file input | from `SetInputToWaveFile` to the last phrase |
| Optional: WinRT `Windows.Media.SpeechRecognition` dictation | `run-winrt-live.ps1`, live microphone only (WinRT has no file input) | from `RecognizeAsync` to result, **includes speaking time**; not comparable file-for-file |

Why SAPI is the main platform row: WinRT recognizers listen only to a live microphone,
so they cannot process the ten fixed clips. WinRT free dictation may also depend on the
"Online speech recognition" privacy setting, which would make it not offline; the
optional WinRT run checks that with the setting off.

## Corpus and recording protocol

The ten sentences are in [`s5-windows-speech/corpus.tsv`](s5-windows-speech/corpus.tsv)
(`id`, `reference`, `identifiers`). They mix Chinese with identifiers such as
`parseConfig`, `ControllerService`, `src/app.ts`, `settingsURL`, `control_request`.
Edit them **before** recording if they do not sound like how you talk to Claude, then
freeze the file: the reference must not change after the engines have run.

1. **Voice:** the maintainer's own voice only.
2. **Microphone:** the one you would use with PowerUp on this Windows machine. Record its
   name in the versions table. Same position and gain for all ten clips.
3. **Room:** quiet and normal; no noise suppression apps in the chain if you can avoid it.
4. **Delivery:** natural speed, as you would talk to Claude, not dictation-slow. Say the
   identifiers the way you naturally would ("parse config", "settings U R L").
5. **Length:** 5 to 10 seconds each. Start speaking within half a second of pressing
   Enter, press `q` right after you finish. One take per sentence; re-take only on a real
   slip of the tongue (`-Only clipNN`).
6. **Format:** 16 kHz, mono, 16-bit PCM WAV, `clips\clip01.wav` to `clips\clip10.wav`.
   `record-clips.ps1` produces exactly that and writes `clips\SHA256SUMS.txt`.
7. **Privacy and size:** the WAV files stay **out of git** by default (`clips/*.wav` is
   ignored in the kit). Commit `SHA256SUMS.txt`. Commit the audio only if you decide your
   voice may be public and the total is small (ten clips are about 3 MB) (#95 Further Notes).

## Exact commands

PowerShell, non-elevated. Assumes the repository at `C:\src\PowerUp` and tools in `C:\tools`.

```powershell
cd C:\src\PowerUp\docs\research\spikes\s5-windows-speech
New-Item -ItemType Directory -Force results | Out-Null
powershell -NoProfile -ExecutionPolicy Bypass -File ..\windows-common\collect-versions.ps1 > results\versions.md

# 1. Tools. ffmpeg is used only to record (never linked); whisper.cpp official CPU build.
winget install --id Gyan.FFmpeg -e          # then open a NEW terminal so ffmpeg is on PATH
New-Item -ItemType Directory -Force C:\tools\whisper | Out-Null
# Pick the newest release tag at https://github.com/ggml-org/whisper.cpp/releases and write it down.
$tag = '<release tag, e.g. v1.x.y>'
curl.exe -L -o C:\tools\whisper\whisper-bin-x64.zip "https://github.com/ggml-org/whisper.cpp/releases/download/$tag/whisper-bin-x64.zip"
Expand-Archive C:\tools\whisper\whisper-bin-x64.zip -DestinationPath C:\tools\whisper -Force
$cli = (Get-ChildItem C:\tools\whisper -Recurse -Filter whisper-cli.exe | Select-Object -First 1).FullName; $cli
curl.exe -L -o C:\tools\whisper\ggml-small.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
curl.exe -L -o C:\tools\whisper\ggml-base.bin  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
Get-FileHash C:\tools\whisper\ggml-small.bin, C:\tools\whisper\ggml-base.bin | Format-List

# 2. Chinese speech recognizer for the platform row:
#    Settings > Time & language > Language & region > Chinese (Simplified, China) > Language options
#    > Speech recognition: install. Then check what SAPI sees:
powershell -NoProfile -Command "Add-Type -AssemblyName System.Speech; [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() | ft Culture, Description"

# 3. Record the ten clips (find the device name first).
ffmpeg -hide_banner -list_devices true -f dshow -i dummy
powershell -NoProfile -ExecutionPolicy Bypass -File .\record-clips.ps1 -Device "<your microphone name>"

# 4. Run the engines. Close other heavy apps; plug in the laptop; same power mode for all runs.
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-whisper.ps1 -WhisperCli $cli -Model C:\tools\whisper\ggml-small.bin -Label whisper-small
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-whisper.ps1 -WhisperCli $cli -Model C:\tools\whisper\ggml-base.bin  -Label whisper-base
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-sapi.ps1 -Culture zh-CN

# 5. Optional rows.
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-whisper.ps1 -WhisperCli $cli -Model C:\tools\whisper\ggml-small.bin -Label whisper-small-prompt -Prompt "parseConfig, ControllerService, setLight, useEffect, userId, README, HookInstaller, settingsURL, git rebase, commit, JSON, force unwrap, guard let, timeout, control_request, control_response"
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-winrt-live.ps1      # with Online speech recognition OFF

# 6. Score.
powershell -NoProfile -ExecutionPolicy Bypass -File .\score.ps1 > results\score.md
Get-Content results\score.md
```

The `--prompt` row uses identifiers that also appear in the corpus, so it measures the
best case of biasing; say so in the record if you include it.

## Scoring

`score.ps1` reads `results\timings.csv` and `results\<engine>\clipNN.txt`:

- **Mixed error rate (MER):** token edit distance divided by reference tokens, where each
  Chinese character is a token and each run of ASCII letters/digits is a token
  (lower-cased; punctuation ignored). It is CER on the Chinese part and WER on the
  English part. Traditional characters where the reference is Simplified count as errors;
  note it if whisper switches script.
- **Identifiers strict:** the identifier appears verbatim, case-sensitive.
- **Identifiers loose:** it appears after lower-casing and deleting everything except
  `a-z0-9` on both sides ("parse config" counts for `parseConfig`).
- **Median** of the ten per-clip wall latencies per engine (warm-up run discarded).

## GO threshold

Agree on the identifier threshold **before** looking at the results; write it here:

- whisper `small` **median wall latency < 2500 ms** (from #95), and
- whisper `small` **loose identifier accuracy >= 80 %** (provisional reading of "acceptable
  identifier accuracy"; maintainer to confirm or change: ______ ).

`score.ps1 -GoIdentifierLoose 0.8` prints the GO check with those numbers.

## Versions (fill in)

| Item | Value |
|---|---|
| Windows edition, version, build | |
| Machine, CPU, RAM, power mode | |
| Microphone (name, connection) | |
| whisper.cpp release tag and asset (`whisper-bin-x64.zip` or other) | |
| `ggml-small.bin` SHA-256 | |
| `ggml-base.bin` SHA-256 | |
| whisper threads (`-t`) | |
| SAPI recognizer (Description from `run-sapi.ps1`) | |
| WinRT dictation languages / Online speech recognition setting (optional row) | |
| ffmpeg version (recording only) | |
| Corpus commit (`git log -1 --format=%h -- corpus.tsv`) | |
| Clip hashes | `clips\SHA256SUMS.txt` |

## Results (fill in: paste `results\score.md`)

| Engine | Median wall (ms) | Median load (ms) | Warm estimate (wall - load) | MER | Identifiers strict | Identifiers loose |
|---|---:|---:|---:|---:|---:|---:|
| whisper-small | | | | | | |
| whisper-base | | | | | | |
| sapi-zh-CN | | | n/a | | | |
| whisper-small-prompt (optional) | | | | | | |
| winrt-zh-CN-offline (optional, live) | | n/a | n/a | | | |

Observations to note: language detection mistakes (whole clip transcribed as English or
translated), script switching (Traditional/Simplified), identifiers split or
transliterated, any crash or missing output.

## Verdict (fill in)

| Check | Result |
|---|---|
| whisper-small latency < 2.5 s | |
| whisper-small identifiers >= threshold | |
| **S5 verdict for `small` as the Windows default** | GO / NO-GO |

## Consequence

| Outcome | ADR 0011 Windows row and plan |
|---|---|
| `small` GO | Windows STT default: whisper.cpp `small`, auto language; `base` as the low-end fallback. Note whether `--prompt` biasing helped (feeds #22). |
| `small` accurate but too slow, and the warm estimate is under 2.5 s | Model load dominates: the Windows adapter keeps one whisper process (or server) alive instead of one process per utterance; re-measure before deciding. |
| `small` too slow even warm; `base` meets latency with acceptable identifiers | Default `base`; `small` opt-in ("more accurate, slower"). |
| Both whisper models miss the identifier threshold | Default stays whisper.cpp (best of the two), docs say honestly that code identifiers are weak on Windows; vocabulary biasing (#22) moves up; cloud STT is never a silent default (plan risk table). |
| SAPI (or WinRT offline) beats whisper on this corpus | Record it; consider the platform recognizer as the default with whisper opt-in, in an ADR 0011 amendment. |
| No offline Chinese platform recognizer available | Record "not available" for the platform row; whisper.cpp is the only offline option. |

After the verdict: fill ADR 0011's Windows row and the plan's stage 3 speech line in the
consolidation PR (#137).
