import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Manages large assets delivered via Play Asset Delivery.
///
/// On Android, model files (model.onnx, voices.json, espeak-ng-data.zip)
/// are shipped in an install-time asset pack and copied to the app's
/// files directory on first launch. Subsequent launches use the cached
/// copies directly.
class AssetManager {
  static const _channel = MethodChannel('com.nonchalant.murmur/assets');

  /// Files that are delivered via Play Asset Delivery on Android.
  static const _padAssets = [
    'model.onnx',
    'voices.json',
    'espeak-ng-data.zip',
  ];

  /// Ensures all large assets are available in the app's files directory.
  /// Returns true if all assets are ready, false if something failed.
  ///
  /// On non-Android platforms, returns true immediately (assets are bundled
  /// normally via Flutter).
  static Future<bool> ensureAssets({
    void Function(String asset, int current, int total)? onProgress,
  }) async {
    if (!Platform.isAndroid) return true;

    for (int i = 0; i < _padAssets.length; i++) {
      final asset = _padAssets[i];
      onProgress?.call(asset, i + 1, _padAssets.length);

      try {
        final path = await _channel.invokeMethod<String>('copyAssetToFiles', {
          'assetName': asset,
          'destName': asset,
        });
        debugPrint('[AssetManager] $asset -> $path');
      } catch (e) {
        debugPrint('[AssetManager] Failed to copy $asset: $e');
        return false;
      }
    }
    return true;
  }

  /// Returns the file path for a PAD asset, or null if not yet copied.
  static Future<String?> getAssetPath(String fileName) async {
    if (!Platform.isAndroid) return null; // Use Flutter assets on other platforms

    try {
      return await _channel.invokeMethod<String>('getFilePath', {
        'fileName': fileName,
      });
    } catch (e) {
      debugPrint('[AssetManager] Error getting path for $fileName: $e');
      return null;
    }
  }

  /// Returns the file path for the ONNX model.
  static Future<String> get modelPath async {
    final path = await getAssetPath('model.onnx');
    return path ?? 'assets/models/model.onnx'; // Fallback to Flutter asset
  }

  /// Returns the file path for the voices JSON.
  static Future<String> get voicesPath async {
    final path = await getAssetPath('voices.json');
    return path ?? 'assets/models/voices.json'; // Fallback to Flutter asset
  }

  /// Returns the file path for the espeak-ng data zip.
  static Future<String> get espeakDataPath async {
    final path = await getAssetPath('espeak-ng-data.zip');
    return path ?? 'assets/espeak-ng-data.zip'; // Fallback to Flutter asset
  }
}
