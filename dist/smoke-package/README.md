# Hermes

Windows-first push-to-talk speech-to-text app in Rust.

Defaults:

- Hold `F8` to record
- Release to transcribe
- Type transcript into the focused app
- Local Whisper model via `whisper-cli.exe`
- GPU-first when configured, CPU fallback on failure

## Requirements

- Windows 10 or 11
- Whisper runtime files in `whisper-runtime\`
- A local Whisper model file
- A working microphone

Default config path:

`%APPDATA%\Hermes\Hermes\config\config.toml`

Default model path:

`%LOCALAPPDATA%\Hermes\Hermes\data\models\ggml-medium.en.bin`

## Quick Start

1. Keep `hermes.exe` and `whisper-runtime\` together.
2. Make sure `whisper-runtime\` contains:
   - `whisper-cli.exe`
   - `whisper.dll`
   - `ggml.dll`
   - `ggml-base.dll`
   - `ggml-cpu.dll`
3. Put a model file at the configured `model_path`.
4. Launch `hermes.exe`.

If Python is installed and `scripts\ptt_tooling.py` is present, you can also open Settings and download a model directly from the GUI.

## Configuration

You can edit:

- `whisper_cli_path`
- `model_path`
- `backend`
- `hotkey.modifier`
- `hotkey.key`
- `min_record_ms`
- `auto_punctuation`
- `type_output`
- `language`

Use the tray menu `Settings` or edit `config.toml` directly.

## Commands

Diagnostics:

```powershell
.\hermes.exe --diagnose
```

Background mode:

```powershell
.\hermes.exe --background
```

Open settings directly:

```powershell
.\hermes.exe --settings
```
