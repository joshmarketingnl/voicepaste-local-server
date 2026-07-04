#!/usr/bin/env bash
#
# VoicePaste local transcription server — macOS installer
#
# Turns the official VoicePaste desktop app into a fully local, free,
# offline transcription tool by running whisper.cpp as an OpenAI-compatible
# endpoint on http://127.0.0.1:8765/v1.
#
# Usage:
#   ./install.sh [--model small|turbo] [--port 8765] [--autostart]
#   ./install.sh --uninstall
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/joshmarketingnl/voicepaste-local-server/main/macos/install.sh | bash
#
set -euo pipefail

RELEASE_BASE="https://github.com/joshmarketingnl/voicepaste-local-server/releases/download/v1.0.0"
WHISPER_CPP_VERSION="v1.9.1"
INSTALL_DIR="$HOME/Library/Application Support/voicepaste-local-server"
AGENT_LABEL="com.voicepaste.local-server"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LOG_FILE="$HOME/Library/Logs/voicepaste-local-server.log"

MODEL=""
PORT="8765"
AUTOSTART="no"
UNINSTALL="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)     MODEL="${2:?}"; shift 2 ;;
    --port)      PORT="${2:?}"; shift 2 ;;
    --autostart) AUTOSTART="yes"; shift ;;
    --uninstall) UNINSTALL="yes"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWaarschuwing:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mFout:\033[0m %s\n' "$*" >&2; exit 1; }

# ----- Uninstall ------------------------------------------------------------
if [[ "$UNINSTALL" == "yes" ]]; then
  say "Uninstalling..."
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  rm -f "$AGENT_PLIST"
  pkill -f "voicepaste-local-server/bin/whisper-server" 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
  say "Removed. Set the VoicePaste provider back to https://api.openai.com/v1 if needed."
  exit 0
fi

# ----- Model selection ------------------------------------------------------
# Default: best-quality turbo on Apple Silicon (Metal makes it fast),
# lightweight small on Intel Macs.
if [[ -z "$MODEL" ]]; then
  if [[ "$(uname -m)" == "arm64" ]]; then MODEL="turbo"; else MODEL="small"; fi
  say "Geen --model opgegeven — standaard voor deze Mac: $MODEL"
fi

case "$MODEL" in
  small) MODEL_FILE="ggml-small-q5_1.bin"
         MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin" ;;
  turbo) MODEL_FILE="ggml-large-v3-turbo-q5_0.bin"
         MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin" ;;
  *) die "--model must be 'small' (190 MB) or 'turbo' (574 MB, best quality)" ;;
esac
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
VAD_FILE="ggml-silero-v5.1.2.bin"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  BIN_ASSET="whisper-server-darwin-arm64" ;;
  x86_64) BIN_ASSET="whisper-server-darwin-x64" ;;
  *) die "Unsupported architecture: $ARCH" ;;
esac

mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/models"

# ----- whisper-server binary ------------------------------------------------
BIN_PATH="$INSTALL_DIR/bin/whisper-server"
if [[ ! -x "$BIN_PATH" ]]; then
  say "Downloading whisper-server ($ARCH, Metal-accelerated)..."
  if curl -fL --progress-bar -o "$BIN_PATH" "$RELEASE_BASE/$BIN_ASSET"; then
    chmod +x "$BIN_PATH"
  else
    warn "Prebuilt download failed — building whisper.cpp $WHISPER_CPP_VERSION from source."
    command -v git   >/dev/null || die "git is required (install Xcode Command Line Tools: xcode-select --install)"
    command -v cmake >/dev/null || {
      command -v brew >/dev/null || die "cmake is required. Install Homebrew (https://brew.sh) or cmake manually."
      brew install cmake
    }
    BUILD_DIR="$(mktemp -d)"
    git clone --depth 1 --branch "$WHISPER_CPP_VERSION" https://github.com/ggml-org/whisper.cpp "$BUILD_DIR"
    cmake -S "$BUILD_DIR" -B "$BUILD_DIR/build" -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DGGML_METAL_EMBED_LIBRARY=ON
    cmake --build "$BUILD_DIR/build" --config Release -j --target whisper-server
    cp "$BUILD_DIR/build/bin/whisper-server" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf "$BUILD_DIR"
  fi
else
  say "whisper-server already installed."
fi

# ----- ffmpeg (needed to decode the app's webm/opus recordings) -------------
if ! command -v ffmpeg >/dev/null; then
  if command -v brew >/dev/null; then
    say "Installing ffmpeg via Homebrew (needed for audio conversion)..."
    brew install ffmpeg
  else
    die "ffmpeg is required. Install Homebrew (https://brew.sh) and run: brew install ffmpeg"
  fi
fi

# ----- Models ----------------------------------------------------------------
if [[ ! -f "$INSTALL_DIR/models/$MODEL_FILE" ]]; then
  say "Downloading speech model $MODEL_FILE..."
  curl -fL --progress-bar -o "$INSTALL_DIR/models/$MODEL_FILE" "$MODEL_URL"
fi
if [[ ! -f "$INSTALL_DIR/models/$VAD_FILE" ]]; then
  say "Downloading Silero VAD model..."
  curl -fL --progress-bar -o "$INSTALL_DIR/models/$VAD_FILE" "$VAD_URL"
fi

# ----- Start script ----------------------------------------------------------
# ffmpeg location varies (Apple Silicon brew: /opt/homebrew/bin) — the server
# resolves it via PATH, so the start script extends PATH explicitly.
cat > "$INSTALL_DIR/start-server.sh" <<EOF
#!/usr/bin/env bash
export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH"
exec "$INSTALL_DIR/bin/whisper-server" \\
  -m "$INSTALL_DIR/models/$MODEL_FILE" \\
  -l auto \\
  --host 127.0.0.1 \\
  --port $PORT \\
  --convert \\
  --inference-path /v1/audio/transcriptions \\
  --vad \\
  --vad-model "$INSTALL_DIR/models/$VAD_FILE"
EOF
chmod +x "$INSTALL_DIR/start-server.sh"

# ----- LaunchAgent (autostart) -----------------------------------------------
if [[ "$AUTOSTART" == "yes" ]]; then
  say "Installing LaunchAgent (starts automatically at login)..."
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$INSTALL_DIR/start-server.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_FILE</string>
  <key>StandardErrorPath</key><string>$LOG_FILE</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
else
  say "Starting server in the background (this session only)..."
  pkill -f "voicepaste-local-server/bin/whisper-server" 2>/dev/null || true
  nohup "$INSTALL_DIR/start-server.sh" >>"$LOG_FILE" 2>&1 &
fi

# ----- Health check ----------------------------------------------------------
say "Waiting for the server to come up..."
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then
    break
  fi
  sleep 1
done
curl -s -o /dev/null "http://127.0.0.1:$PORT/" || die "Server did not start — check $LOG_FILE"

cat <<EOF

$(printf '\033[1;32m')Klaar! / Done!$(printf '\033[0m')

Zet in de VoicePaste-app bij Settings de Provider op:
Set the Provider in the VoicePaste app Settings to:

    http://127.0.0.1:$PORT/v1

Er is geen API-key nodig (de app herkent localhost).
No API key needed (the app auto-detects localhost providers).

Model: $MODEL_FILE  |  Logs: $LOG_FILE
$( [[ "$AUTOSTART" == "yes" ]] \
  && echo "Autostart: aan (LaunchAgent $AGENT_LABEL)" \
  || echo "Tip: draai de installer opnieuw met --autostart om de server automatisch te laten meestarten." )
EOF
