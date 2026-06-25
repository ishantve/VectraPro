# VectraPro Transcription Backend

FastAPI service that the iOS app calls to transcribe recorded audio. It reads
Azure Speech credentials from `azure_config.plist` and uses the
Azure Cognitive Services Speech SDK (with the custom-model `EndpointId`).

## Config

`azure_config.plist` (gitignored — holds secrets):

```xml
<dict>
    <key>EndpointId</key>      <string>…custom model id…</string>
    <key>Region</key>         <string>eastus2</string>
    <key>SubscriptionKey</key> <string>…azure key…</string>
</dict>
```

Copy `azure_config.example.plist` → `azure_config.plist` and fill in values.

## Run

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```

## API

- `GET /health` → `{"status": "ok", "region": "..."}`
- `POST /transcribe` — multipart form-data, field `file` = WAV (16 kHz mono PCM).
  Returns `{"text": "..."}`.

## Point the iOS app at it

In `VectraPro/Configuration/AppConfiguration.swift` set:

```swift
static let transcriptionEndpoint = "http://<your-mac-LAN-ip>:8000/transcribe"
```

> Plain HTTP is blocked by iOS App Transport Security. For LAN testing either
> serve over HTTPS, or add an ATS exception (requires a custom Info.plist).
> A real device must be on the same network as the Mac running the server.
