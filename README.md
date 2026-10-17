# Catet

A native Swift macOS meeting recorder. WhisperKit transcribes audio locally while you record. Imported audio and transcription retries use whisper.cpp. Meeting notes are generated through Codex CLI using your ChatGPT subscription. No paid API key or Python runtime is required.

## Setup

Requires an Apple Silicon Mac running macOS 14 or later, Apple's command-line tools (`xcode-select --install`), Nix, and Codex CLI signed in with ChatGPT (`codex login`).

```sh
./setup.sh
./catet open
```

Setup downloads the runtime, a checksum-verified multilingual Whisper model (574 MB), and a local speech detector (885 KB). It installs Catet in `/Applications`, registers it with macOS, and opens its permission settings. Runtime dependencies are pinned under `~/Library/Application Support/Catet/runtime`, independently of this checkout. The first recording also downloads WhisperKit's multilingual streaming model and tokenizer to `~/Library/Application Support/Catet/models`. Keep an internet connection during this preparation. Later recordings use the cached model offline.

## Record a meeting

Use the floating control on the left edge of the screen or the Catet menu bar menu. Grant microphone access. For online meetings, also grant screen/system audio recording access in macOS System Settings. Catet saves audio, not screen images. You can explicitly choose microphone-only recording if system audio access is unavailable.

Recording choices are saved after the first confirmation. Later recordings start immediately. Open **Catet → Settings…** to change recording choices, request microphone or system audio access, open macOS privacy settings, or reveal the installed app in Finder. If you need to add Catet manually, select `/Applications/Catet.app`.

If system audio access is denied, choose **Open Settings and stop**, allow Catet under **Privacy & Security → Screen & System Audio Recording**, then reopen Catet and start a new recording. **Stop and save** keeps the available microphone recording without sending it to Codex. Use **Process recording** in the library when you want to process it. Missing system audio remains visible as a separate warning.

Start recording after participants agree to be recorded. The meeting library shows a transcript preview that updates during recording. Recent text can change as more audio arrives. Stop when the meeting ends. Catet finishes the remaining audio before creating meeting notes. Very short recordings offer **Keep** or **Move to Trash**. Trashed recordings can be restored from macOS Trash. Use the library to retry failed processing or open the meeting's files. Existing audio files can also be imported.

Audio and transcripts are stored under `~/Library/Application Support/Catet/meetings`. Do not delete these files while a recording or processing job is running. Recordings are kept after processing so failures can be retried.

Press **Control+Option+Space** from any app to open quick recording. **Return** records or stops, **Escape** closes the keyboard controls, and **Command+Return** opens the library. While Catet is active, **Shift+Command+R** also opens quick recording.

In the library, use **j/k** to move between meetings, **gg/G** for the first or last meeting, **Return/l** to read, and **h/Escape** to return to the list. Search with **/**, **Command+F**, or **Command+K**. Press **?** for the remaining shortcuts.

## Privacy and Codex

Transcription runs on your Mac and does not upload audio. Creating meeting notes sends the transcript to Codex through your signed-in subscription. It also replaces the recording title with a short title based on the transcript. Choose automatic meeting notes in **Catet → Settings…**, or create notes later from the library. Subscription availability and usage limits apply. A Codex failure leaves the local recording and transcript available.

If Codex supplies a usage-limit reset time, Catet saves the retry and creates the notes when that time arrives. Keep Catet running for an on-time retry. If the app is closed or the Mac is asleep, the retry runs when Catet is active again. When the reset time cannot be confirmed, retry manually.

Open **Catet → Codex Accounts…** to add and sign in to another ChatGPT account. Added accounts have separate credentials and do not change your terminal's Codex login. Select the account for new requests, or use **Use another account** on a failed meeting. Catet never rotates accounts automatically. A scheduled retry keeps the account that reached its limit.

Meeting failures show a short explanation. Use **Show diagnostics** to open the technical log, which may contain transcript content.

Catet does not infer participants' names from their voices. Review transcripts and generated notes before sharing them, especially names, decisions, and action items.

## Integrations

Run `./catet --help` for the CLI. Other tools can consume each meeting's `transcript.txt`, timestamped `transcript.json`, and `mom.md` files.

```sh
./catet list --json
./catet import /path/to/meeting.m4a --title 'Weekly planning'
# Use the meeting directory printed by import:
./catet process '/path/to/meeting-directory'
./catet mom '/path/to/meeting-directory'
```

`process` performs local transcription. `mom` explicitly sends the transcript to Codex. `process --mom` performs both. For local automation, use the CLI exit status and meeting metadata to distinguish completion from failure.

## Rebuild

```sh
./install.sh
```

`install.sh` rebuilds and updates `/Applications/Catet.app`. It refuses to replace the app while recording or processing is active. Builds require a valid code-signing identity in your login Keychain. The installer remembers the selected identity to keep recording permissions stable across rebuilds. Set `CATET_SIGN_IDENTITY` to select a different certificate. This is a locally signed installation, not a notarized distribution.

Run `./test.sh` for the native engine's regression checks.

## License

MIT. See [LICENSE](LICENSE).
