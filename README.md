# FreeReads

**Local-Only Audiobook App** - Convert PDF textbooks into human-quality audio, entirely on-device.

## Philosophy: Sovereign Computing

- **No Cloud APIs** - Everything runs on your device's NPU/CPU
- **No Subscriptions** - One-time setup, forever offline
- **No Data Collection** - Your books stay on your device

## Features

- PDF to audio conversion using Kokoro-82M TTS
- On-device OCR with ML Kit
- User-calibrated content zones (header/footer filtering)
- Columnar reading order detection for textbooks
- Minimal dark theme UI

## Tech Stack

| Component | Package | Purpose |
|-----------|---------|---------|
| PDF Rendering | `pdfrx` | Rasterize pages for OCR |
| OCR | `google_mlkit_text_recognition` | Extract text with coordinates |
| TTS | `kokoro_tts_flutter` | Neural text-to-speech |
| Audio | `flutter_soloud` | Low-latency PCM streaming |
| Storage | `sqflite` | Local book/page database |

## Architecture

```
Phase A: Ingestion
PDF → pdfrx → Bitmap → ML Kit OCR → TextBlocks + Rects → Page Sorter → SQLite

Phase B: Playback
SQLite → Text Chunk → Kokoro TTS → PCM Audio → SoLoud → Speaker
```

## Setup

### Prerequisites

1. Flutter SDK (3.9+)
2. Android SDK (minSdk 24+)
3. Kokoro model files from HuggingFace

### Install Dependencies

```bash
flutter pub get
```

### Download TTS Model

Download from [HuggingFace Kokoro](https://huggingface.co/hexgrad/Kokoro-82M):

1. `model.onnx` (Kokoro v1.0) → `assets/models/model.onnx`
2. `voices.json` → `assets/models/voices.json`

### Add Sample PDF

Place a test PDF in `assets/sample/` (e.g., `The-Mom-Test-en.pdf`)

### Run

```bash
# Android
flutter run -d android

# iOS (requires additional Podfile configuration)
flutter run -d ios
```

## Project Structure

```
lib/
├── main.dart                    # App entry point
├── core/
│   ├── ocr_processor.dart       # ML Kit wrapper
│   ├── page_sorter.dart         # Heuristic text sorting
│   ├── pdf_renderer.dart        # pdfrx wrapper
│   └── tts_engine.dart          # Kokoro + SoLoud integration
├── data/
│   ├── database.dart            # SQLite operations
│   └── models/
│       ├── book.dart            # Book entity
│       └── page_text.dart       # Page text entity
├── ui/
│   ├── home_screen.dart         # Entry screen
│   ├── calibration_screen.dart  # PDF zone calibration
│   └── player_screen.dart       # Audio playback
└── theme/
    └── app_theme.dart           # Dark theme styling
```

## Key Implementation Notes

### PDF-to-OCR Pattern (Avoiding Crashes)

Never use `InputImage.fromBytes()` - it causes stride/format crashes on different devices.

Instead, use the temp file pattern:

```dart
// 1. Render PDF to PNG bytes
final pngBytes = await pdfRenderer.renderPage(pageNum);

// 2. Write to temp file
final tempFile = File('${tempDir.path}/page_cache.bmp');
await tempFile.writeAsBytes(pngBytes);

// 3. Load via file path (stable)
final inputImage = InputImage.fromFilePath(tempFile.path);
final text = await textRecognizer.processImage(inputImage);

// 4. Cleanup
await tempFile.delete();
```

### TTS Integration

`kokoro_tts_flutter` returns raw PCM audio. We convert to WAV format in memory for SoLoud playback:

```dart
final result = await kokoro.createTTS(text: text, voice: voiceId);
final pcm = result.toInt16PCM();
final wav = createWavFromPcm(pcm, sampleRate: 24000);
await soloud.loadMem('audio.wav', wav);
```

## MVP "Trace Bullet" Scope

This MVP proves the vertical slice:

1. ✅ Load sample PDF from assets
2. ✅ Render page and display
3. ✅ Draggable calibration overlays
4. ✅ Run OCR with zone filtering
5. ✅ Sort text in reading order
6. ✅ Pass to TTS engine
7. ✅ Stream audio to speaker

## License

MIT
