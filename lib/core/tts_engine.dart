import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
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
          debugPrint('[TTS] espeak-ng failed to initialize, falling back to malsami');
        }
      } else {
        debugPrint('[TTS] espeak-ng not available on this platform, using malsami');
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

  /// Maximum characters per chunk (conservative estimate to stay under 510 phonemes)
  /// After phonemization, each character can expand to 1-3 phonemes on average.
  /// Using 150 chars to stay safely under the 510 phoneme limit.
  static const int _maxChunkChars = 150;

  /// Generates audio for a single text chunk.
  Future<_AudioChunk?> _generateChunk(String text) async {
    if (_kokoro == null || _currentVoiceId == null) return null;
    if (text.trim().isEmpty) return null;
    
    try {
      // Use espeak-ng for phonemization if available (HuggingFace quality)
      // Otherwise fall back to malsami (built into kokoro_tts_flutter)
      String textOrPhonemes = text;
      bool isPhonemes = false;
      
      if (_useEspeak) {
        final phonemes = EspeakPhonemizer.phonemize(text);
        if (phonemes != null && phonemes.isNotEmpty) {
          textOrPhonemes = phonemes;
          isPhonemes = true;
          debugPrint('[TTS] espeak phonemes: $phonemes');
        } else {
          debugPrint('[TTS] espeak returned null, falling back to malsami');
        }
      }
      
      final result = await _kokoro!.createTTS(
        text: textOrPhonemes,
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
      debugPrint('[TTS] Error generating chunk: $e');
      return null;
    }
  }

  /// Speaks the given text with pre-buffered streaming.
  /// 
  /// Pre-generates chunks ahead of playback to minimize gaps.
  /// Returns the generated audio duration in seconds.
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
      // Split text into chunks that fit within model limits
      final chunks = _chunkText(text);
      final totalChunks = chunks.length;
      double totalDuration = 0;
      int generateIndex = 0;
      int playIndex = 0;
      
      debugPrint('[TTS] Starting buffered playback: $totalChunks chunks, pre-buffering $_preBufferCount');
      
      // Phase 1: Pre-buffer initial chunks before starting playback
      while (generateIndex < totalChunks && _audioBuffer.length < _preBufferCount) {
        if (_status != TtsStatus.speaking) break;
        
        final chunk = chunks[generateIndex];
        debugPrint('[TTS] Pre-buffering chunk ${generateIndex + 1}/$totalChunks...');
        
        final audio = await _generateChunk(chunk);
        if (audio != null) {
          _audioBuffer.addLast(audio);
          totalDuration += audio.duration;
        }
        generateIndex++;
      }
      
      debugPrint('[TTS] Pre-buffer complete, ${_audioBuffer.length} chunks ready. Starting playback...');
      
      // Phase 2: Play and generate in overlapping fashion
      while (playIndex < totalChunks && _status == TtsStatus.speaking) {
        // Play next chunk from buffer if available
        if (_audioBuffer.isNotEmpty) {
          final audio = _audioBuffer.removeFirst();
          playIndex++;
          
          debugPrint('[TTS] Playing chunk $playIndex/$totalChunks (${audio.duration.toStringAsFixed(2)}s), buffer: ${_audioBuffer.length}');
          
          // Start playback (non-blocking initially)
          final playFuture = _playPcmInt16AndWait(audio.pcmData, sampleRate: audio.sampleRate);
          
          // While audio plays, generate the next chunk if needed
          if (generateIndex < totalChunks && _audioBuffer.length < _preBufferCount) {
            final chunk = chunks[generateIndex];
            debugPrint('[TTS] Generating chunk ${generateIndex + 1}/$totalChunks while playing...');
            
            final nextAudio = await _generateChunk(chunk);
            if (nextAudio != null) {
              _audioBuffer.addLast(nextAudio);
              totalDuration += nextAudio.duration;
            }
            generateIndex++;
          }
          
          // Wait for current audio to finish
          await playFuture;
          debugPrint('[TTS] Chunk $playIndex finished');
        } else if (generateIndex < totalChunks) {
          // Buffer empty but more to generate - generate and play immediately
          final chunk = chunks[generateIndex];
          debugPrint('[TTS] Buffer empty, generating chunk ${generateIndex + 1}/$totalChunks directly...');
          
          final audio = await _generateChunk(chunk);
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

  /// Chunks text into pieces that stay under the phoneme limit.
  /// Splits on sentence boundaries when possible.
  List<String> _chunkText(String text) {
    if (text.length <= _maxChunkChars) {
      return [text];
    }

    final chunks = <String>[];
    
    // Split by sentence-ending punctuation, keeping the punctuation
    final sentencePattern = RegExp(r'(?<=[.!?])\s+');
    final sentences = text.split(sentencePattern);
    
    var currentChunk = StringBuffer();
    
    for (final sentence in sentences) {
      // If adding this sentence would exceed limit, save current chunk
      if (currentChunk.length + sentence.length > _maxChunkChars) {
        if (currentChunk.isNotEmpty) {
          chunks.add(currentChunk.toString().trim());
          currentChunk.clear();
        }
        
        // If single sentence is too long, split by phrases
        if (sentence.length > _maxChunkChars) {
          chunks.addAll(_splitLongSentence(sentence));
        } else {
          currentChunk.write(sentence);
          currentChunk.write(' ');
        }
      } else {
        currentChunk.write(sentence);
        currentChunk.write(' ');
      }
    }
    
    // Add remaining content
    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk.toString().trim());
    }
    
    return chunks;
  }

  /// Splits a long sentence into smaller chunks by commas/semicolons or words.
  List<String> _splitLongSentence(String sentence) {
    final chunks = <String>[];
    
    // Try splitting by commas/semicolons first
    final phrasePattern = RegExp(r'(?<=[,;])\s*');
    final phrases = sentence.split(phrasePattern);
    
    var currentChunk = StringBuffer();
    
    for (final phrase in phrases) {
      if (currentChunk.length + phrase.length > _maxChunkChars) {
        if (currentChunk.isNotEmpty) {
          chunks.add(currentChunk.toString().trim());
          currentChunk.clear();
        }
        
        // If phrase is still too long, split by words
        if (phrase.length > _maxChunkChars) {
          final words = phrase.split(' ');
          for (final word in words) {
            if (currentChunk.length + word.length + 1 > _maxChunkChars) {
              if (currentChunk.isNotEmpty) {
                chunks.add(currentChunk.toString().trim());
                currentChunk.clear();
              }
            }
            currentChunk.write(word);
            currentChunk.write(' ');
          }
        } else {
          currentChunk.write(phrase);
          currentChunk.write(' ');
        }
      } else {
        currentChunk.write(phrase);
        currentChunk.write(' ');
      }
    }
    
    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk.toString().trim());
    }
    
    return chunks;
  }

  /// Concatenates multiple PCM buffers into one.
  Int16List _concatenatePcm(List<Int16List> buffers) {
    final totalLength = buffers.fold<int>(0, (sum, buf) => sum + buf.length);
    final result = Int16List(totalLength);
    
    var offset = 0;
    for (final buffer in buffers) {
      result.setRange(offset, offset + buffer.length, buffer);
      offset += buffer.length;
    }
    
    return result;
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

  /// Test method: speaks raw phonemes directly (bypasses malsami).
  /// Use this to verify if pronunciation issues are from phonemizer or model.
  Future<void> speakPhonemes(String phonemes) async {
    if (_status != TtsStatus.ready && _status != TtsStatus.paused) {
      throw StateError('TTS engine not ready. Current status: $_status');
    }
    
    if (_kokoro == null || _currentVoiceId == null) {
      throw StateError('TTS engine not properly initialized');
    }

    await stop();
    _setStatus(TtsStatus.speaking);

    try {
      debugPrint('[TTS TEST] Speaking raw phonemes: "$phonemes"');
      
      final result = await _kokoro!.createTTS(
        text: phonemes,
        voice: _currentVoiceId!,
        speed: _rate,
        lang: 'en-us',
        isPhonemes: true,  // Bypass phonemizer!
      );
      
      final pcmData = result.toInt16PCM();
      debugPrint('[TTS TEST] Generated ${pcmData.length} samples');
      
      await _playPcmInt16AndWait(pcmData, sampleRate: result.sampleRate);
      
      _setStatus(TtsStatus.ready);
    } catch (e) {
      debugPrint('[TTS TEST] Error: $e');
      _setStatus(TtsStatus.error);
      rethrow;
    }
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
