# VoicePaste Local Server

Run the official **VoicePaste** desktop app (Developer beta v1.1+) **100% locally** — free,
private, and offline. No OpenAI API costs, and your voice never leaves your machine.

This works because the VoicePaste app has a configurable **Provider** setting with built-in
localhost support (no API key required for local providers). This project runs
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) as a drop-in OpenAI-compatible
transcription endpoint:

```
VoicePaste app  ──▶  http://127.0.0.1:8765/v1  ──▶  whisper.cpp (on your machine)
(unchanged!)         "looks like the OpenAI API"     Metal on macOS / AVX2 on Windows
```

## Snelstart (Nederlands)

**macOS** — open Terminal en plak:

```bash
curl -fsSL https://raw.githubusercontent.com/joshmarketingnl/voicepaste-local-server/main/macos/install.sh | bash -s -- --autostart
```

**Windows** — open PowerShell en plak:

```powershell
irm https://raw.githubusercontent.com/joshmarketingnl/voicepaste-local-server/main/windows/install.ps1 -OutFile "$env:TEMP\vpls-install.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\vpls-install.ps1" -AutoStart
```

Zet daarna in de VoicePaste-app bij **Settings → Provider**:

```
http://127.0.0.1:8765/v1
```

Klaar — geen API-key nodig. Dicteer zoals altijd; alles blijft op je eigen computer.

## What gets installed

| | macOS | Windows |
|---|---|---|
| Location | `~/Library/Application Support/voicepaste-local-server` | `%LOCALAPPDATA%\voicepaste-local-server` |
| Engine | `whisper-server` (Metal-accelerated, prebuilt or built from source) | `whisper-server.exe` (AVX2 CPU build) |
| Speech model | Whisper **small q5_1** (190 MB) by default | same |
| VAD | Silero v5 (trims silence, prevents hallucinations) | same |
| Audio decode | ffmpeg (via Homebrew) | ffmpeg (via winget) |
| Autostart | LaunchAgent (`--autostart`) | Startup shortcut (`-AutoStart`) |

### Options

```bash
# macOS                                   # Windows
./install.sh --model small               .\install.ps1 -Model small     # lighter model
./install.sh --port 9000                 .\install.ps1 -Port 9000
./install.sh --uninstall                 .\install.ps1 -Uninstall
                                          .\install.ps1 -Gpu off         # force CPU build
```

### Defaults & speed

| Machine | Engine | Default model | Speed per sentence* |
|---|---|---|---|
| Windows + NVIDIA GPU (auto-detected) | **CUDA** | **turbo** (best quality) | **~0.4 s** |
| Windows, CPU only | AVX2 CPU | small | ~4 s |
| Apple Silicon Mac | **Metal** | **turbo** (best quality) | fast |
| Intel Mac | CPU | small | moderate |

\* measured on an RTX 3060 Ti with a 7-second recording (warm server).

- **small**: 190 MB download, ~600 MB RAM. Light and quick on CPU.
- **turbo** (large-v3-turbo): 574 MB download, ~1.2 GB RAM (CPU) / ~1 GB VRAM (GPU).
  Near cloud-level accuracy.

Both models support **99 languages** with automatic language detection and code-switching.

## How it works

The VoicePaste app records webm/opus segments and sends them via the OpenAI SDK to
`{provider}/audio/transcriptions`. The installer runs whisper.cpp's `whisper-server` with:

```
whisper-server -m <model> -l auto --host 127.0.0.1 --port 8765 \
  --convert --inference-path /v1/audio/transcriptions \
  --vad --vad-model <silero>
```

- `--inference-path` makes the endpoint OpenAI-path-compatible
- `--convert` uses ffmpeg to decode the app's webm uploads
- `-l auto` enables language auto-detection (the app omits the `language` field in auto mode)
- The `model` field sent by the app is ignored by the server; the local GGML model is used

The server idles at ~0% CPU and holds the model in RAM (~350 MB for small) while running.

## Troubleshooting

- **App says transcription failed** → the server isn't running. Start it:
  - macOS: `bash "$HOME/Library/Application Support/voicepaste-local-server/start-server.sh"`
    (or reinstall with `--autostart`)
  - Windows: double-click `start-transcriptie-server-stil.vbs` in `%LOCALAPPDATA%\voicepaste-local-server`
- **Logs**: macOS `~/Library/Logs/voicepaste-local-server.log`; Windows: run the `.cmd`
  variant to see live output.
- **Back to the cloud**: set the Provider back to `https://api.openai.com/v1`.

## Credits

[whisper.cpp](https://github.com/ggml-org/whisper.cpp) (Georgi Gerganov) ·
[OpenAI Whisper](https://github.com/openai/whisper) models ·
[Silero VAD](https://github.com/snakers4/silero-vad) ·
Related: [voicepaste-local](https://github.com/joshmarketingnl/voicepaste-local) — an
open-source VoicePaste fork with this local engine built in.

## License

MIT
