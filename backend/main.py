"""
VectraPro transcription backend.

Receives a WAV upload from the iOS app and returns its transcription using
Azure Cognitive Services Speech, configured from azure_config.plist.
"""

import os
import plistlib
import tempfile
import threading
from pathlib import Path

import azure.cognitiveservices.speech as speechsdk
from fastapi import FastAPI, File, HTTPException, UploadFile

CONFIG_PATH = Path(__file__).parent / "azure_config.plist"


def load_config() -> dict:
    with open(CONFIG_PATH, "rb") as f:
        return plistlib.load(f)


_config = load_config()
SUBSCRIPTION_KEY = _config["SubscriptionKey"]
REGION = _config["Region"]
ENDPOINT_ID = _config.get("EndpointId") or None

app = FastAPI(title="VectraPro Transcription")


def transcribe_wav(path: str) -> str:
    """Run continuous recognition over a WAV file and return the full text."""
    speech_config = speechsdk.SpeechConfig(subscription=SUBSCRIPTION_KEY, region=REGION)
    if ENDPOINT_ID:
        # Use the custom speech model.
        speech_config.endpoint_id = ENDPOINT_ID

    audio_config = speechsdk.audio.AudioConfig(filename=path)
    recognizer = speechsdk.SpeechRecognizer(
        speech_config=speech_config, audio_config=audio_config
    )

    segments: list[str] = []
    done = threading.Event()

    def on_recognized(evt):
        if evt.result.reason == speechsdk.ResultReason.RecognizedSpeech:
            segments.append(evt.result.text)

    recognizer.recognized.connect(on_recognized)
    recognizer.session_stopped.connect(lambda _evt: done.set())
    recognizer.canceled.connect(lambda _evt: done.set())

    recognizer.start_continuous_recognition()
    done.wait(timeout=60)
    recognizer.stop_continuous_recognition()

    return " ".join(segments).strip()


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "region": REGION}


@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...)) -> dict:
    data = await file.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty audio upload")

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp.write(data)
        tmp_path = tmp.name

    try:
        text = transcribe_wav(tmp_path)
        return {"text": text}
    finally:
        os.remove(tmp_path)
