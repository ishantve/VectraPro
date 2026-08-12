# Vosk model — drop it here

VectraPro uses the **offline Vosk** speech engine for the push-to-talk mic
(Azure is only the fallback). The acoustic model is **hundreds of MB**, so it is
**not committed to git** — you add it here manually.

## How to add the model

1. Get the model folder (e.g. `atc-lgraph-v10`). Unzip so it directly contains
   `am/`, `conf/`, `graph/`, `ivector/`, … (a `vosk-model.json` is optional).
2. Copy the whole `atc-lgraph-v10/` folder **into this `Models/` folder** on disk,
   so you end up with:

   ```
   Models/
     README.md            ← this file (committed)
     atc-lgraph-v10/       ← the model (git-ignored)
       am/  conf/  graph/  ivector/  …
   ```

3. Rebuild. This `Models/` folder is wired into the app target as a **folder
   reference** (blue folder), so its contents ship inside the app bundle with the
   directory structure preserved, and `VoskLiveRecognizer` loads it at runtime.

## ⚠️ Do NOT add the model as a "group"

If you re-add this folder to Xcode, always choose **“Create folder references”**
(blue), never **“Create groups”** (yellow). A group flattens the files, and the
model has duplicate filenames across sub-folders (e.g. `words.txt` in both
`graph/` and `graph.orig_base/`) — that produces a *“Multiple commands produce
words.txt”* build error.

## No model present?

The app still builds and runs — `VoskLiveRecognizer` fails to load, and the mic
falls back to **Azure** automatically. Offline transcription just won't be
available until a model is added here.

## Newer model versions

`VoskModelLocator` picks the **highest** version it finds, so dropping in a newer
folder (e.g. `atc-lgraph-v11`) alongside works with no code change.
