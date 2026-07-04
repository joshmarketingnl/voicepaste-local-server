# VoicePaste local transcription server — Windows installer
#
# Turns the official VoicePaste desktop app into a fully local, free,
# offline transcription tool by running whisper.cpp as an OpenAI-compatible
# endpoint on http://127.0.0.1:8765/v1.
#
# Usage (PowerShell):
#   .\install.ps1 [-Model small|turbo] [-Gpu auto|on|off] [-Port 8765] [-AutoStart] [-Uninstall]
#
# With an NVIDIA GPU (auto-detected) the CUDA build is installed and the
# best-quality turbo model becomes the default — transcription drops from
# seconds to ~0.4s per sentence.
#
param(
  [ValidateSet('small', 'turbo')]
  [string]$Model = 'small',
  [ValidateSet('auto', 'on', 'off')]
  [string]$Gpu = 'auto',
  [int]$Port = 8765,
  [switch]$AutoStart,
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ReleaseBase = 'https://github.com/joshmarketingnl/voicepaste-local-server/releases/download/v1.0.0'
$CudaZipUrl = 'https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-cublas-12.4.0-bin-x64.zip'
$InstallDir = Join-Path $env:LOCALAPPDATA 'voicepaste-local-server'
$StartupDir = [Environment]::GetFolderPath('Startup')
$StartupLink = Join-Path $StartupDir 'VoicePaste lokale transcriptie-server.lnk'

function Say($msg) { Write-Host "==> $msg" -ForegroundColor Green }

if ($Uninstall) {
  Say 'Uninstalling...'
  Get-Process whisper-server -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$InstallDir*" } | Stop-Process -Force
  if (Test-Path $StartupLink) { Remove-Item $StartupLink -Force }
  if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
  Say 'Removed. Set the VoicePaste provider back to https://api.openai.com/v1 if needed.'
  exit 0
}

# GPU detection: NVIDIA driver present -> CUDA build + turbo model default
$UseGpu = $false
if ($Gpu -eq 'on') { $UseGpu = $true }
elseif ($Gpu -eq 'auto') {
  $UseGpu = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)
}
if ($UseGpu -and -not $PSBoundParameters.ContainsKey('Model')) {
  # On GPU the best model is also fast — make it the default
  $Model = 'turbo'
}
Say "Engine: $(if ($UseGpu) { 'GPU (CUDA)' } else { 'CPU' }) | Model: $Model"

if ($Model -eq 'small') {
  $ModelFile = 'ggml-small-q5_1.bin'
  $ModelUrl = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin'
} else {
  $ModelFile = 'ggml-large-v3-turbo-q5_0.bin'
  $ModelUrl = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin'
}
$VadFile = 'ggml-silero-v5.1.2.bin'
$VadUrl = 'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin'

New-Item -ItemType Directory -Force (Join-Path $InstallDir 'bin') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $InstallDir 'models') | Out-Null

# ----- whisper-server binary (with required DLLs) ---------------------------
$BinSub = if ($UseGpu) { 'bin-gpu' } else { 'bin' }
$ServerExe = Join-Path $InstallDir "$BinSub\whisper-server.exe"
if (-not (Test-Path $ServerExe)) {
  if ($UseGpu) {
    Say 'Downloading whisper-server (CUDA build, ~680 MB incl. CUDA runtime)...'
    $zip = Join-Path $env:TEMP 'whisper-cublas-win-x64.zip'
    Invoke-WebRequest -Uri $CudaZipUrl -OutFile $zip
    $tmp = Join-Path $env:TEMP 'whisper-cublas-extract'
    Expand-Archive $zip -DestinationPath $tmp -Force
    New-Item -ItemType Directory -Force (Join-Path $InstallDir $BinSub) | Out-Null
    $src = if (Test-Path (Join-Path $tmp 'Release')) { Join-Path $tmp 'Release' } else { $tmp }
    $wanted = @('whisper-server.exe', 'whisper.dll') +
      (Get-ChildItem $src -Filter 'ggml*.dll').Name +
      (Get-ChildItem $src -Filter 'cublas*.dll').Name +
      (Get-ChildItem $src -Filter 'cudart*.dll').Name +
      (Get-ChildItem $src -Filter 'nvrtc*.dll').Name +
      (Get-ChildItem $src -Filter 'nvblas*.dll').Name
    foreach ($name in ($wanted | Select-Object -Unique)) {
      Copy-Item (Join-Path $src $name) (Join-Path $InstallDir $BinSub)
    }
    Remove-Item $zip -Force
    Remove-Item $tmp -Recurse -Force
  } else {
    Say 'Downloading whisper-server (CPU/AVX2 build)...'
    $zip = Join-Path $env:TEMP 'whisper-server-win32-x64.zip'
    Invoke-WebRequest -Uri "$ReleaseBase/whisper-server-win32-x64.zip" -OutFile $zip
    Expand-Archive $zip -DestinationPath (Join-Path $InstallDir $BinSub) -Force
    Remove-Item $zip -Force
  }
} else {
  Say 'whisper-server already installed.'
}

# ----- ffmpeg (needed to decode the app's webm/opus recordings) -------------
$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
if (-not $ffmpeg) {
  Say 'Installing ffmpeg via winget (needed for audio conversion)...'
  winget install --id Gyan.FFmpeg -e --accept-source-agreements --accept-package-agreements
  Write-Host 'NB: open een NIEUW PowerShell-venster als ffmpeg zojuist is geinstalleerd (PATH).' -ForegroundColor Yellow
}

# ----- Models ----------------------------------------------------------------
$ModelPath = Join-Path $InstallDir "models\$ModelFile"
if (-not (Test-Path $ModelPath)) {
  Say "Downloading speech model $ModelFile..."
  Invoke-WebRequest -Uri $ModelUrl -OutFile $ModelPath
}
$VadPath = Join-Path $InstallDir "models\$VadFile"
if (-not (Test-Path $VadPath)) {
  Say 'Downloading Silero VAD model...'
  Invoke-WebRequest -Uri $VadUrl -OutFile $VadPath
}

# ----- Start scripts ----------------------------------------------------------
$cmdScript = @"
@echo off
rem VoicePaste lokale transcriptie-server (whisper.cpp, $(if ($UseGpu) { 'GPU/CUDA' } else { 'CPU' }))
cd /d "%~dp0"
echo Server draait op http://127.0.0.1:$Port/v1 - venster sluiten = server stopt.
"%~dp0$BinSub\whisper-server.exe" -m "%~dp0models\$ModelFile" -l auto -t 8 --host 127.0.0.1 --port $Port --convert --inference-path /v1/audio/transcriptions --vad --vad-model "%~dp0models\$VadFile"
pause
"@
Set-Content -Path (Join-Path $InstallDir 'start-transcriptie-server.cmd') -Value $cmdScript -Encoding ascii

$vbsScript = @"
' Start de VoicePaste lokale transcriptie-server zonder zichtbaar venster.
Set shell = CreateObject("WScript.Shell")
scriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
' Werkmap expliciet zetten: whisper-server schrijft temp-conversiebestanden
' naar de werkmap; bij autostart kan die onbeschrijfbaar zijn.
shell.CurrentDirectory = scriptDir
cmd = """" & scriptDir & "$BinSub\whisper-server.exe""" & _
  " -m """ & scriptDir & "models\$ModelFile""" & _
  " -l auto -t 8 --host 127.0.0.1 --port $Port --convert" & _
  " --inference-path /v1/audio/transcriptions" & _
  " --vad --vad-model """ & scriptDir & "models\$VadFile"""
shell.Run cmd, 0, False
"@
$vbsPath = Join-Path $InstallDir 'start-transcriptie-server-stil.vbs'
Set-Content -Path $vbsPath -Value $vbsScript -Encoding ascii

# ----- Autostart (Startup folder shortcut) -----------------------------------
if ($AutoStart) {
  Say 'Installing autostart shortcut...'
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($StartupLink)
  $link.TargetPath = 'wscript.exe'
  $link.Arguments = "`"$vbsPath`""
  $link.Save()
}

# ----- Start now + health check ----------------------------------------------
Say 'Starting server...'
Get-Process whisper-server -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -like "$InstallDir*" } | Stop-Process -Force
Start-Process wscript.exe -ArgumentList "`"$vbsPath`""

$up = $false
foreach ($i in 1..30) {
  try {
    Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 2 | Out-Null
    $up = $true; break
  } catch { Start-Sleep -Seconds 1 }
}
if (-not $up) { throw "Server did not start - run start-transcriptie-server.cmd in $InstallDir to see the error." }

Write-Host ''
Write-Host 'Klaar! / Done!' -ForegroundColor Green
Write-Host ''
Write-Host 'Zet in de VoicePaste-app bij Settings de Provider op:'
Write-Host 'Set the Provider in the VoicePaste app Settings to:'
Write-Host ''
Write-Host "    http://127.0.0.1:$Port/v1" -ForegroundColor Cyan
Write-Host ''
Write-Host 'Er is geen API-key nodig / No API key needed.'
if (-not $AutoStart) {
  Write-Host 'Tip: draai de installer opnieuw met -AutoStart om de server met Windows te laten meestarten.' -ForegroundColor Yellow
}
