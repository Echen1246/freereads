import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:kokoro_tts_flutter/kokoro_tts_flutter.dart';

import 'espeak_phonemizer.dart';

/// TTS Engine status
enum TtsStatus {
  uninitialized,
  initializing,
  ready,
  speaking,
  paused,
  error,
}

/// Pre-generated audio chunk ready for playback
class _AudioChunk {
  final Int16List pcmData;
  final int sampleRate;
  final double duration;
  
  _AudioChunk({
    required this.pcmData,
    required this.sampleRate,
    required this.duration,
  });
}

/// Text-to-Speech engine using Kokoro TTS and SoLoud audio.
/// 
/// This class wraps kokoro_tts_flutter for phonemization and ONNX inference,
/// and flutter_soloud for low-latency PCM audio streaming.
/// 
/// Uses pre-buffering to minimize gaps between chunks.
class TtsEngine {
  /// Kokoro TTS instance
  Kokoro? _kokoro;
  
  /// SoLoud audio engine
  SoLoud? _soloud;
  
  /// Current status
  TtsStatus _status = TtsStatus.uninitialized;
  
  /// Current audio handle for playback control
  SoundHandle? _currentHandle;
  
  /// Current voice ID
  String? _currentVoiceId;
  
  /// Speech rate (0.5 - 2.0)
  double _rate = 1.0;
  
  /// Pre-buffered audio chunks ready to play
  final Queue<_AudioChunk> _audioBuffer = Queue<_AudioChunk>();
  
  /// Number of chunks to pre-buffer before starting playback
  static const int _preBufferCount = 2;

  // Stream controller for status updates
  final _statusController = StreamController<TtsStatus>.broadcast();
  Stream<TtsStatus> get statusStream => _statusController.stream;
  TtsStatus get status => _status;
  
  /// Available voice IDs after initialization
  List<String> get availableVoices => _kokoro?.getVoices() ?? [];

  /// Whether espeak-ng phonemizer is available (Android only for now)
  bool _useEspeak = false;

  /// Tokenizer vocabulary: phoneme character → token ID.
  /// Loaded from assets/tokenizer_vocab.json to enable token-level splitting.
  Map<String, int> _vocab = {};

  // =========================================================================
  // Token IDs for smart splitting
  // =========================================================================
  /// Sentence-ending punctuation: . ! ?
  static const Set<int> _sentenceEndTokens = {4, 5, 6};
  /// Phrase-level breaks: ; : ,
  static const Set<int> _phraseBreakTokens = {1, 2, 3};
  /// Space token
  static const int _spaceToken = 16;
  /// Max tokens per batch.  The Kokoro model accepts up to 510, but ONNX
  /// inference runs on the Android platform thread (method channel limitation).
  /// Batches >~250 tokens can exceed Android's 5-second ANR timeout on mobile
  /// devices, so we cap at 200 for safety.
  static const int _maxTokensPerBatch = 200;

  /// Initialize the TTS engine.
  /// 
  /// [modelPath] - Path to the ONNX model file (e.g., 'assets/models/model.onnx')
  /// [voicesPath] - Path to the voices JSON file (e.g., 'assets/models/voices.json')
  /// [isInt8] - Whether the model is int8 quantized
  Future<void> initialize({
    String modelPath = 'assets/models/model.onnx',
    String voicesPath = 'assets/models/voices.json',
    bool isInt8 = false,
  }) async {
    // Allow re-initialization if in error state
    if (_status != TtsStatus.uninitialized && _status != TtsStatus.error) {
      debugPrint('[TTS] Already initialized, status: $_status');
      return;
    }
    
    _setStatus(TtsStatus.initializing);
    
    try {
      // Initialize espeak-ng phonemizer (Android only for now)
      if (Platform.isAndroid) {
        debugPrint('[TTS] Initializing espeak-ng phonemizer...');
        _useEspeak = await EspeakPhonemizer.initialize();
        if (_useEspeak) {
          debugPrint('[TTS] espeak-ng phonemizer ready - HuggingFace quality enabled!');
        } else {
          debugPrint('[TTS] espeak-ng failed to initialize, using built-in phonemizer');
        }
      } else {
        debugPrint('[TTS] espeak-ng not available on this platform, using built-in phonemizer');
        _useEspeak = false;
      }

      // Initialize SoLoud audio engine
      _soloud = SoLoud.instance;
      
      // Ensure clean state - deinit if already initialized
      if (_soloud!.isInitialized) {
        debugPrint('[TTS] SoLoud already initialized, cleaning up...');
        try {
          _soloud!.deinit();
          await Future.delayed(const Duration(milliseconds: 200));
        } catch (e) {
          debugPrint('[TTS] Cleanup error (ignoring): $e');
        }
      }
      
      await _soloud!.init();
      debugPrint('[TTS] SoLoud initialized successfully');
      
      // Initialize Kokoro TTS
      final config = KokoroConfig(
        modelPath: modelPath,
        voicesPath: voicesPath,
        isInt8: isInt8,
      );
      
      _kokoro = Kokoro(config);
      await _kokoro!.initialize();
      
      // Load tokenizer vocab for token-level splitting
      final vocabJson = await rootBundle.loadString('assets/tokenizer_vocab.json');
      final vocabMap = jsonDecode(vocabJson) as Map<String, dynamic>;
      _vocab = vocabMap.map((k, v) => MapEntry(k, v as int));
      debugPrint('[TTS] Loaded tokenizer vocab: ${_vocab.length} entries');
      
      // Set default voice (first available)
      final voices = _kokoro!.getVoices();
      // Debug: print available voices
      assert(() {
        // ignore: avoid_print
        print('[TTS] Available voices: $voices');
        return true;
      }());
      
      if (voices.isNotEmpty) {
        _currentVoiceId = voices.first;
      }
      
      _setStatus(TtsStatus.ready);
    } catch (e, stackTrace) {
      // Debug: print error
      assert(() {
        // ignore: avoid_print
        print('[TTS] Initialization error: $e');
        // ignore: avoid_print
        print('[TTS] Stack trace: $stackTrace');
        return true;
      }());
      _setStatus(TtsStatus.error);
      rethrow;
    }
  }

  /// Sets the voice to use for TTS.
  void setVoice(String voiceId) {
    if (_kokoro == null) {
      throw StateError('TTS engine not initialized');
    }
    
    if (!_kokoro!.getVoices().contains(voiceId)) {
      throw ArgumentError('Voice $voiceId not found');
    }
    
    _currentVoiceId = voiceId;
  }

  // ===========================================================================
  // Phonemization + Token-level splitting pipeline
  // ===========================================================================
  //
  // New architecture (replaces old character-count chunking):
  //   1. Phonemize entire page text at once via espeak-ng
  //   2. Walk the phoneme string, counting actual tokens via vocab
  //   3. Split at sentence boundaries (.!?) staying under 510 tokens
  //   4. Each batch → createTTS(isPhonemes: true) → audio
  //
  // This maximizes context per model call and ensures clean prosody breaks.
  // ===========================================================================

  /// Prepares phoneme batches from raw text.
  /// Returns (list of batches, whether they are phoneme strings).
  /// 
  /// When espeak-ng is available: phonemizes all text at once, then splits
  /// the phoneme string into ≤510-token batches at sentence boundaries.
  /// 
  /// Fallback (no espeak): splits raw text conservatively by sentences
  /// and lets Kokoro's built-in phonemizer handle each chunk.
  (List<String> batches, bool isPhonemes) _prepareBatches(String text) {
    if (_useEspeak) {
      final phonemes = EspeakPhonemizer.phonemize(text);
      if (phonemes != null && phonemes.isNotEmpty) {
        debugPrint('[TTS] Full phonemes (${phonemes.length} chars): ${phonemes.length > 80 ? '${phonemes.substring(0, 80)}...' : phonemes}');
        final batches = _splitPhonemesAtBoundaries(phonemes);
        debugPrint('[TTS] Split into ${batches.length} batches');
        return (batches, true);
      }
      debugPrint('[TTS] espeak returned null, falling back to text chunking');
    }
    
    // Fallback: conservative text chunking for built-in phonemizer.
    // 150 chars ≈ stays safely under 510 tokens after phonemization.
    return (_chunkTextFallback(text, maxChars: 150), false);
  }

  /// Splits a phoneme string into batches of at most [_maxTokensPerBatch]
  /// tokens, preferring to split at sentence boundaries (.!?), then phrase
  /// breaks (,;:), then spaces, and hard-splitting only as a last resort.
  List<String> _splitPhonemesAtBoundaries(String phonemes) {
    if (phonemes.isEmpty) return [];

    // Quick check: does the whole string fit in one batch?
    int totalTokens = 0;
    for (int i = 0; i < phonemes.length; i++) {
      if (_vocab.containsKey(phonemes[i])) totalTokens++;
    }
    if (totalTokens <= _maxTokensPerBatch) {
      return [phonemes];
    }

    final batches = <String>[];
    int batchStart = 0;
    int tokenCount = 0;
    int lastSentenceEnd = -1;
    int lastPhraseBreak = -1;
    int lastSpace = -1;

    for (int i = 0; i < phonemes.length; i++) {
      final char = phonemes[i];
      final tokenId = _vocab[char];

      if (tokenId != null) {
        tokenCount++;

        // Track candidate split points
        if (_sentenceEndTokens.contains(tokenId)) {
          lastSentenceEnd = i;
        } else if (_phraseBreakTokens.contains(tokenId)) {
          lastPhraseBreak = i;
        } else if (tokenId == _spaceToken) {
          lastSpace = i;
        }
      }

      // When we reach the token limit, split at the best boundary
      if (tokenCount >= _maxTokensPerBatch) {
        int splitAt;
        if (lastSentenceEnd > batchStart) {
          splitAt = lastSentenceEnd + 1; // include the punctuation
        } else if (lastPhraseBreak > batchStart) {
          splitAt = lastPhraseBreak + 1;
        } else if (lastSpace > batchStart) {
          splitAt = lastSpace + 1;
        } else {
          splitAt = i + 1; // hard split at current position
        }

        final batch = phonemes.substring(batchStart, splitAt).trim();
        if (batch.isNotEmpty) {
          batches.add(batch);
        }
        batchStart = splitAt;

        // Recount tokens from the new start through current position
        tokenCount = 0;
        lastSentenceEnd = -1;
        lastPhraseBreak = -1;
        lastSpace = -1;
        for (int j = batchStart; j <= i; j++) {
          final tid = _vocab[phonemes[j]];
          if (tid != null) {
            tokenCount++;
            if (_sentenceEndTokens.contains(tid)) lastSentenceEnd = j;
            else if (_phraseBreakTokens.contains(tid)) lastPhraseBreak = j;
            else if (tid == _spaceToken) lastSpace = j;
          }
        }
      }
    }

    // Add remaining phonemes
    if (batchStart < phonemes.length) {
      final remaining = phonemes.substring(batchStart).trim();
      if (remaining.isNotEmpty) {
        batches.add(remaining);
      }
    }

    // Log batch sizes for debugging
    for (int i = 0; i < batches.length; i++) {
      int tokens = 0;
      for (int j = 0; j < batches[i].length; j++) {
        if (_vocab.containsKey(batches[i][j])) tokens++;
      }
      debugPrint('[TTS] Batch ${i + 1}/${batches.length}: $tokens tokens, ${batches[i].length} chars');
    }

    return batches;
  }

  /// Fallback: chunks raw text by character count at sentence boundaries.
  /// Used when espeak-ng is not available and Kokoro does its own phonemization.
  List<String> _chunkTextFallback(String text, {int maxChars = 150}) {
    if (text.length <= maxChars) return [text];

    final chunks = <String>[];
    final sentencePattern = RegExp(r'(?<=[.!?])\s+');
    final sentences = text.split(sentencePattern);
    var currentChunk = StringBuffer();

    for (final sentence in sentences) {
      if (currentChunk.length + sentence.length > maxChars) {
        if (currentChunk.isNotEmpty) {
          chunks.add(currentChunk.toString().trim());
          currentChunk.clear();
        }
        if (sentence.length > maxChars) {
          // Split long sentence by commas/spaces
          final words = sentence.split(RegExp(r'(?<=[,;])\s*|\s+'));
          for (final word in words) {
            if (currentChunk.length + word.length + 1 > maxChars && currentChunk.isNotEmpty) {
              chunks.add(currentChunk.toString().trim());
              currentChunk.clear();
            }
            currentChunk.write(word);
            currentChunk.write(' ');
          }
        } else {
          currentChunk.write(sentence);
          currentChunk.write(' ');
        }
      } else {
        currentChunk.write(sentence);
        currentChunk.write(' ');
      }
    }
    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk.toString().trim());
    }
    return chunks;
  }

  /// Generates audio for a single batch (phonemes or raw text).
  Future<_AudioChunk?> _generateAudio(String batch, {required bool isPhonemes}) async {
    if (_kokoro == null || _currentVoiceId == null) return null;
    if (batch.trim().isEmpty) return null;

    try {
      final result = await _kokoro!.createTTS(
        text: batch,
        voice: _currentVoiceId!,
        speed: _rate,
        lang: 'en-us',
        isPhonemes: isPhonemes,
      );

      return _AudioChunk(
        pcmData: result.toInt16PCM(),
        sampleRate: result.sampleRate,
        duration: result.duration,
      );
    } catch (e) {
      debugPrint('[TTS] Error generating audio: $e');
      return null;
    }
  }

  /// Speaks the given text with pre-buffered streaming.
  /// 
  /// Pipeline:
  ///   1. Phonemize all text at once (espeak-ng) or chunk text (fallback)
  ///   2. Split into optimal batches at sentence boundaries
  ///   3. Pre-generate audio chunks ahead of playback
  ///   4. Stream playback with overlap (generate N+1 while playing N)
  /// 
  /// Returns the total generated audio duration in seconds.
  Future<double> speak(String text) async {
    if (_status != TtsStatus.ready && _status != TtsStatus.paused) {
      throw StateError('TTS engine not ready. Current status: $_status');
    }

    if (_kokoro == null || _currentVoiceId == null) {
      throw StateError('TTS engine not properly initialized');
    }

    await stop();
    _audioBuffer.clear();
    _setStatus(TtsStatus.speaking);

    try {
      // Step 1: Phonemize all text and split into optimal batches
      final (batches, isPhonemes) = _prepareBatches(text);
      final totalBatches = batches.length;
      double totalDuration = 0;
      int generateIndex = 0;
      int playIndex = 0;

      debugPrint('[TTS] Starting playback: $totalBatches batches (phonemes=$isPhonemes), pre-buffering $_preBufferCount');

      // Phase 1: Pre-buffer initial batches before starting playback
      while (generateIndex < totalBatches && _audioBuffer.length < _preBufferCount) {
        if (_status != TtsStatus.speaking) break;

        debugPrint('[TTS] Pre-buffering batch ${generateIndex + 1}/$totalBatches...');
        final audio = await _generateAudio(batches[generateIndex], isPhonemes: isPhonemes);
        if (audio != null) {
          _audioBuffer.addLast(audio);
          totalDuration += audio.duration;
        }
        generateIndex++;
      }

      debugPrint('[TTS] Pre-buffer complete, ${_audioBuffer.length} batches ready. Starting playback...');

      // Phase 2: Play and generate in overlapping fashion
      while (playIndex < totalBatches && _status == TtsStatus.speaking) {
        if (_audioBuffer.isNotEmpty) {
          final audio = _audioBuffer.removeFirst();
          playIndex++;

          debugPrint('[TTS] Playing batch $playIndex/$totalBatches (${audio.duration.toStringAsFixed(2)}s), buffer: ${_audioBuffer.length}');

          // Start playback (non-blocking)
          final playFuture = _playPcmInt16AndWait(audio.pcmData, sampleRate: audio.sampleRate);

          // While audio plays, generate the next batch if needed
          if (generateIndex < totalBatches && _audioBuffer.length < _preBufferCount) {
            debugPrint('[TTS] Generating batch ${generateIndex + 1}/$totalBatches while playing...');
            final nextAudio = await _generateAudio(batches[generateIndex], isPhonemes: isPhonemes);
            if (nextAudio != null) {
              _audioBuffer.addLast(nextAudio);
              totalDuration += nextAudio.duration;
            }
            generateIndex++;
          }

          // Wait for current audio to finish
          await playFuture;
          debugPrint('[TTS] Batch $playIndex finished');
        } else if (generateIndex < totalBatches) {
          // Buffer empty, generate and play immediately
          debugPrint('[TTS] Buffer empty, generating batch ${generateIndex + 1}/$totalBatches directly...');
          final audio = await _generateAudio(batches[generateIndex], isPhonemes: isPhonemes);
          generateIndex++;

          if (audio != null) {
            totalDuration += audio.duration;
            playIndex++;
            await _playPcmInt16AndWait(audio.pcmData, sampleRate: audio.sampleRate);
          }
        } else {
          break;
        }
      }

      _audioBuffer.clear();
      _setStatus(TtsStatus.ready);
      debugPrint('[TTS] Playback complete. Total duration: ${totalDuration.toStringAsFixed(2)}s');
      return totalDuration;
    } catch (e) {
      debugPrint('[TTS] Error during speak: $e');
      _audioBuffer.clear();
      _setStatus(TtsStatus.error);
      rethrow;
    }
  }

  /// Plays Int16 PCM audio data through SoLoud and waits for completion.
  Future<void> _playPcmInt16AndWait(Int16List pcmData, {required int sampleRate}) async {
    if (_soloud == null) {
      throw StateError('SoLoud not initialized');
    }

    // Create a WAV-like audio buffer in memory for SoLoud
    final wavData = _createWavFromPcm(pcmData, sampleRate: sampleRate);
    
    // Calculate expected duration
    final durationSeconds = pcmData.length / sampleRate;
    debugPrint('[TTS] Created WAV: ${wavData.length} bytes, $sampleRate Hz, ${durationSeconds.toStringAsFixed(2)}s');
    
    // Load audio from memory
    final source = await _soloud!.loadMem('tts_audio.wav', wavData);
    debugPrint('[TTS] Loaded audio source: ${source.soundHash}');
    
    // Play the audio
    _currentHandle = await _soloud!.play(source);
    debugPrint('[TTS] Started playback, handle: $_currentHandle');
    
    // Wait based on calculated duration + some buffer
    final waitDuration = Duration(milliseconds: (durationSeconds * 1000).toInt() + 100);
    debugPrint('[TTS] Waiting ${waitDuration.inMilliseconds}ms for playback...');
    
    // Wait for the expected duration, checking periodically if stopped
    final endTime = DateTime.now().add(waitDuration);
    while (DateTime.now().isBefore(endTime) && _status == TtsStatus.speaking) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    
    debugPrint('[TTS] Playback wait complete');
    
    // Cleanup
    if (_soloud != null) {
      try {
        if (_currentHandle != null) {
          _soloud!.stop(_currentHandle!);
        }
        await _soloud!.disposeSource(source);
      } catch (e) {
        debugPrint('[TTS] Error during cleanup: $e');
      }
    }
    _currentHandle = null;
  }

  /// Creates a WAV file header and combines with PCM data.
  Uint8List _createWavFromPcm(Int16List pcmData, {required int sampleRate}) {
    final dataSize = pcmData.length * 2; // 16-bit = 2 bytes per sample
    final fileSize = 44 + dataSize; // WAV header is 44 bytes
    
    final wav = Uint8List(fileSize);
    final data = ByteData.view(wav.buffer);
    
    // RIFF header
    wav[0] = 0x52; // 'R'
    wav[1] = 0x49; // 'I'
    wav[2] = 0x46; // 'F'
    wav[3] = 0x46; // 'F'
    data.setUint32(4, fileSize - 8, Endian.little); // File size - 8
    wav[8] = 0x57; // 'W'
    wav[9] = 0x41; // 'A'
    wav[10] = 0x56; // 'V'
    wav[11] = 0x45; // 'E'
    
    // fmt chunk
    wav[12] = 0x66; // 'f'
    wav[13] = 0x6D; // 'm'
    wav[14] = 0x74; // 't'
    wav[15] = 0x20; // ' '
    data.setUint32(16, 16, Endian.little); // fmt chunk size
    data.setUint16(20, 1, Endian.little); // Audio format (1 = PCM)
    data.setUint16(22, 1, Endian.little); // Number of channels (1 = mono)
    data.setUint32(24, sampleRate, Endian.little); // Sample rate
    data.setUint32(28, sampleRate * 2, Endian.little); // Byte rate (SampleRate * NumChannels * BitsPerSample/8)
    data.setUint16(32, 2, Endian.little); // Block align (NumChannels * BitsPerSample/8)
    data.setUint16(34, 16, Endian.little); // Bits per sample
    
    // data chunk
    wav[36] = 0x64; // 'd'
    wav[37] = 0x61; // 'a'
    wav[38] = 0x74; // 't'
    wav[39] = 0x61; // 'a'
    data.setUint32(40, dataSize, Endian.little); // Data size
    
    // Copy PCM data
    for (int i = 0; i < pcmData.length; i++) {
      data.setInt16(44 + i * 2, pcmData[i], Endian.little);
    }
    
    return wav;
  }

  /// Pauses current speech.
  Future<void> pause() async {
    if (_status != TtsStatus.speaking) return;
    
    if (_currentHandle != null && _soloud != null) {
      _soloud!.setPause(_currentHandle!, true);
    }
    _setStatus(TtsStatus.paused);
  }

  /// Resumes paused speech.
  Future<void> resume() async {
    if (_status != TtsStatus.paused) return;
    
    if (_currentHandle != null && _soloud != null) {
      _soloud!.setPause(_currentHandle!, false);
    }
    _setStatus(TtsStatus.speaking);
  }

  /// Stops current speech and clears buffers.
  Future<void> stop() async {
    // Clear the pre-buffer
    _audioBuffer.clear();
    
    if (_currentHandle != null && _soloud != null) {
      _soloud!.stop(_currentHandle!);
      _currentHandle = null;
    }
    
    if (_status == TtsStatus.speaking || _status == TtsStatus.paused) {
      _setStatus(TtsStatus.ready);
    }
  }

  /// Sets the speech rate (0.5 = half speed, 2.0 = double speed).
  void setRate(double rate) {
    _rate = rate.clamp(0.5, 2.0);
  }

  /// Sets the volume (0.0 to 1.0).
  void setVolume(double volume) {
    if (_soloud != null) {
      _soloud!.setGlobalVolume(volume);
    }
  }

  void _setStatus(TtsStatus status) {
    _status = status;
    _statusController.add(status);
  }

  /// Releases all resources.
  Future<void> dispose() async {
    debugPrint('[TTS] Disposing TTS engine...');
    await stop();
    _audioBuffer.clear();
    
    // Dispose espeak-ng phonemizer
    if (_useEspeak) {
      EspeakPhonemizer.dispose();
      _useEspeak = false;
    }
    
    // Dispose Kokoro TTS
    await _kokoro?.dispose();
    _kokoro = null;
    
    // Properly cleanup SoLoud
    if (_soloud != null && _soloud!.isInitialized) {
      try {
        _soloud!.deinit();
      } catch (e) {
        debugPrint('[TTS] Error during SoLoud cleanup: $e');
      }
    }
    _soloud = null;
    
    _status = TtsStatus.uninitialized;
    await _statusController.close();
    debugPrint('[TTS] TTS engine disposed');
  }
}
