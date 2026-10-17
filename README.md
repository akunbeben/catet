# Catet

A native macOS meeting recorder with live local transcription and meeting notes through Codex.

## Setup

Requires Apple Silicon, macOS 14+, Apple’s command-line tools, Nix, Codex CLI signed in with ChatGPT (`codex login`), and a valid code-signing identity in your login Keychain.

```sh
./setup.sh
./catet open
```

Setup installs `/Applications/Catet.app`. Setup and the first recording need internet to download models. Later recordings use the cached models offline.

## Use

- Record from the floating control or menu bar. Get participants’ consent and allow microphone access. Online meetings also need screen/system audio permission. Catet saves audio only.
- Read the live transcript in the meeting library. Stop to finish the transcript and create notes if enabled.
- Open **Catet → Settings…** for recording preferences. Press **Control+Option+Space** for quick recording and **?** in the library for shortcuts.

Recordings stay in `~/Library/Application Support/Catet/meetings` for review and retries. Use the app to manage them while recording or processing is active. Run `./catet --help` for imports and CLI usage.

## Privacy

Audio and transcription stay on your Mac. Creating meeting notes sends the transcript to Codex through your ChatGPT account. Review transcripts and notes before sharing.

## Development

Run `./install.sh` to rebuild and replace the installed app. Finish active recordings and processing first. Run `./test.sh` for regression checks.

MIT. See [LICENSE](LICENSE).
