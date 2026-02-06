import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';

// ============================================================================
// C Function Signatures
// ============================================================================

// int espeak_Initialize(int output, int buflength, const char *path, int options)
typedef EspeakInitializeNative = Int32 Function(
  Int32 output,
  Int32 buflength,
  Pointer<Utf8> path,
  Int32 options,
);
typedef EspeakInitializeDart = int Function(
  int output,
  int buflength,
  Pointer<Utf8> path,
  int options,
);

// int espeak_SetVoiceByName(const char *name)
typedef EspeakSetVoiceByNameNative = Int32 Function(Pointer<Utf8> name);
typedef EspeakSetVoiceByNameDart = int Function(Pointer<Utf8> name);

// const char *espeak_TextToPhonemes(const void **textptr, int textmode, int phonememode)
typedef EspeakTextToPhonemesNative = Pointer<Utf8> Function(
  Pointer<Pointer<Utf8>> textptr,
  Int32 textmode,
  Int32 phonememode,
);
typedef EspeakTextToPhonemesDart = Pointer<Utf8> Function(
  Pointer<Pointer<Utf8>> textptr,
  int textmode,
  int phonememode,
);

// int espeak_Terminate(void)
typedef EspeakTerminateNative = Int32 Function();
typedef EspeakTerminateDart = int Function();

// ============================================================================
// Constants
// ============================================================================

/// Audio output modes
const int espeakAUDIO_OUTPUT_SYNCHRONOUS = 0x02;

/// Character encoding modes
const int espeakCHARS_UTF8 = 1;

/// Phoneme output modes
const int espeakPHONEMES_IPA = 0x02;

// ============================================================================
// EspeakPhonemizer Class
// ============================================================================

/// High-quality phonemizer using espeak-ng native library.
/// Provides IPA phoneme output that matches HuggingFace Kokoro quality.
class EspeakPhonemizer {
  static DynamicLibrary? _lib;
  static bool _initialized = false;
  static String? _dataPath;

  // Function pointers
  static EspeakInitializeDart? _initialize;
  static EspeakSetVoiceByNameDart? _setVoiceByName;
  static EspeakTextToPhonemesDart? _textToPhonemes;
  static EspeakTerminateDart? _terminate;

  /// Check if the phonemizer is ready
  static bool get isInitialized => _initialized;

  /// Load the native library and lookup functions
  static void _loadLibrary() {
    if (_lib != null) return;

    if (Platform.isAndroid) {
      _lib = DynamicLibrary.open('libespeak-ng.so');
    } else if (Platform.isIOS) {
      // iOS would need a different approach (static linking or framework)
      throw UnsupportedError('iOS not yet supported for espeak-ng');
    } else if (Platform.isMacOS) {
      // For macOS development/testing
      throw UnsupportedError('macOS not yet supported for espeak-ng');
    } else {
      throw UnsupportedError('Platform not supported for espeak-ng');
    }

    _initialize = _lib!.lookupFunction<EspeakInitializeNative, EspeakInitializeDart>(
      'espeak_Initialize',
    );

    _setVoiceByName = _lib!.lookupFunction<EspeakSetVoiceByNameNative, EspeakSetVoiceByNameDart>(
      'espeak_SetVoiceByName',
    );

    _textToPhonemes = _lib!.lookupFunction<EspeakTextToPhonemesNative, EspeakTextToPhonemesDart>(
      'espeak_TextToPhonemes',
    );

    _terminate = _lib!.lookupFunction<EspeakTerminateNative, EspeakTerminateDart>(
      'espeak_Terminate',
    );

    print('[EspeakPhonemizer] Library loaded successfully');
  }

  /// Extract espeak-ng-data.zip from assets to filesystem (first launch only)
  static Future<String> _extractDataIfNeeded() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dataDir = Directory('${appDir.path}/espeak-ng-data');
    
    // Check if already extracted
    final markerFile = File('${dataDir.path}/.extracted');
    if (await markerFile.exists()) {
      print('[EspeakPhonemizer] Data already extracted at ${dataDir.path}');
      return appDir.path;  // Return parent path (espeak expects path to folder containing espeak-ng-data)
    }

    print('[EspeakPhonemizer] Extracting espeak-ng-data.zip...');

    // Load the zip from assets
    final ByteData zipData = await rootBundle.load('assets/espeak-ng-data.zip');
    final Uint8List zipBytes = zipData.buffer.asUint8List();

    // Decode the archive
    final archive = ZipDecoder().decodeBytes(zipBytes);

    // Extract files
    for (final file in archive) {
      final filePath = '${appDir.path}/${file.name}';
      
      if (file.isFile) {
        final outFile = File(filePath);
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      } else {
        await Directory(filePath).create(recursive: true);
      }
    }

    // Create marker file
    await markerFile.create(recursive: true);
    await markerFile.writeAsString('extracted');

    print('[EspeakPhonemizer] Extraction complete: ${archive.length} files');
    return appDir.path;
  }

  /// Initialize espeak-ng with the data path
  /// Call this once at app startup
  static Future<bool> initialize() async {
    if (_initialized) return true;

    try {
      // Extract data if needed
      _dataPath = await _extractDataIfNeeded();

      // Load the native library
      _loadLibrary();

      // Initialize espeak-ng
      final pathPtr = _dataPath!.toNativeUtf8();
      
      // Options: espeakINITIALIZE_PHONEME_IPA (0x02) for IPA output
      final result = _initialize!(
        espeakAUDIO_OUTPUT_SYNCHRONOUS, // output mode
        0,                               // buffer length (default)
        pathPtr,                         // path to espeak-ng-data parent folder
        0x02,                            // options: IPA phonemes
      );

      calloc.free(pathPtr);

      if (result <= 0) {
        print('[EspeakPhonemizer] Initialize failed with result: $result');
        return false;
      }

      print('[EspeakPhonemizer] Initialized with sample rate: $result Hz');

      // Set default voice to English US
      final voicePtr = 'en-us'.toNativeUtf8();
      _setVoiceByName!(voicePtr);
      calloc.free(voicePtr);

      _initialized = true;
      return true;
    } catch (e, stack) {
      print('[EspeakPhonemizer] Initialize error: $e');
      print(stack);
      return false;
    }
  }

  /// Punctuation that should be preserved for prosody/pauses
  static final _punctuationPattern = RegExp(r'([.!?;:,])');
  
  /// Convert text to IPA phonemes, preserving punctuation for proper pauses
  /// Returns the phoneme string, or null on error
  static String? phonemize(String text, {String language = 'en-us'}) {
    if (!_initialized) {
      print('[EspeakPhonemizer] Not initialized, call initialize() first');
      return null;
    }

    if (text.isEmpty) return '';

    try {
      // Set language/voice
      final langPtr = language.toNativeUtf8();
      _setVoiceByName!(langPtr);
      calloc.free(langPtr);

      // Split text by punctuation while keeping the punctuation marks
      // This ensures punctuation is preserved for Kokoro's prosody
      final segments = <String>[];
      int lastEnd = 0;
      
      for (final match in _punctuationPattern.allMatches(text)) {
        // Add the text before the punctuation
        if (match.start > lastEnd) {
          segments.add(text.substring(lastEnd, match.start));
        }
        // Add the punctuation itself
        segments.add(match.group(0)!);
        lastEnd = match.end;
      }
      // Add any remaining text after the last punctuation
      if (lastEnd < text.length) {
        segments.add(text.substring(lastEnd));
      }
      
      // Phonemize each segment, keeping punctuation as-is
      final phonemeBuffer = StringBuffer();
      
      for (final segment in segments) {
        // If it's punctuation, keep it as-is for Kokoro's prosody
        if (_punctuationPattern.hasMatch(segment) && segment.length == 1) {
          phonemeBuffer.write(segment);
          continue;
        }
        
        // Skip empty segments
        final trimmed = segment.trim();
        if (trimmed.isEmpty) {
          // Preserve spaces between words
          if (segment.contains(' ') && phonemeBuffer.isNotEmpty) {
            phonemeBuffer.write(' ');
          }
          continue;
        }
        
        // Phonemize the text segment
        final phonemes = _phonemizeSegment(trimmed);
        if (phonemes != null && phonemes.isNotEmpty) {
          if (phonemeBuffer.isNotEmpty && 
              !phonemeBuffer.toString().endsWith(' ') &&
              !_punctuationPattern.hasMatch(phonemeBuffer.toString()[phonemeBuffer.length - 1])) {
            phonemeBuffer.write(' ');
          }
          phonemeBuffer.write(phonemes);
        }
      }

      final result = phonemeBuffer.toString().trim();
      return result;
    } catch (e, stack) {
      print('[EspeakPhonemizer] Phonemize error: $e');
      print(stack);
      return null;
    }
  }
  
  /// Internal: phonemize a single text segment (no punctuation)
  static String? _phonemizeSegment(String text) {
    if (text.isEmpty) return '';
    
    // Prepare text pointer (espeak modifies this pointer as it consumes text)
    final textPtr = text.toNativeUtf8();
    final textPtrPtr = calloc<Pointer<Utf8>>();
    textPtrPtr.value = textPtr;

    // Collect all phonemes
    final phonemeBuffer = StringBuffer();

    while (textPtrPtr.value != nullptr && textPtrPtr.value.address != 0) {
      // Get phonemes for next chunk
      // textmode = 1 (UTF8), phonememode = 0x02 (IPA)
      final resultPtr = _textToPhonemes!(textPtrPtr, espeakCHARS_UTF8, espeakPHONEMES_IPA);

      if (resultPtr != nullptr && resultPtr.address != 0) {
        final chunk = resultPtr.toDartString();
        if (chunk.isNotEmpty) {
          phonemeBuffer.write(chunk);
        }
      }

      // Check if we've consumed all text
      if (textPtrPtr.value == nullptr || textPtrPtr.value.address == 0) {
        break;
      }
      
      // Safety check for the remaining text
      try {
        final remaining = textPtrPtr.value.toDartString();
        if (remaining.isEmpty) break;
      } catch (e) {
        break;
      }
    }

    // Cleanup
    calloc.free(textPtr);
    calloc.free(textPtrPtr);
    // Note: resultPtr is managed by espeak, don't free it

    return phonemeBuffer.toString().trim();
  }

  /// Cleanup resources
  static void dispose() {
    if (_initialized && _terminate != null) {
      _terminate!();
      _initialized = false;
      print('[EspeakPhonemizer] Terminated');
    }
  }
}
