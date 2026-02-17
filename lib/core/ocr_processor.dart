import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Represents a recognized text block with its bounding box.
class OcrTextBlock {
  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  const OcrTextBlock({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  double get width => right - left;
  double get height => bottom - top;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  @override
  String toString() => 'OcrTextBlock("${text.substring(0, text.length.clamp(0, 20))}..." at ($left, $top))';
}

/// OCR processor using Google ML Kit.
/// Extracts text blocks with bounding box coordinates from images.
class OcrProcessor {
  final TextRecognizer _textRecognizer;

  OcrProcessor() : _textRecognizer = TextRecognizer();

  /// Processes an image file and returns recognized text blocks.
  /// 
  /// Uses InputImage.fromFilePath to avoid byte stride issues.
  /// The temp file should be a PNG or BMP image.
  Future<List<OcrTextBlock>> processImageFile(String imagePath) async {
    final file = File(imagePath);
    if (!await file.exists()) {
      throw FileSystemException('Image file not found', imagePath);
    }

    final inputImage = InputImage.fromFilePath(imagePath);
    final recognizedText = await _textRecognizer.processImage(inputImage);

    final blocks = <OcrTextBlock>[];
    
    for (final block in recognizedText.blocks) {
      final boundingBox = block.boundingBox;
      blocks.add(OcrTextBlock(
        text: block.text,
        left: boundingBox.left,
        top: boundingBox.top,
        right: boundingBox.right,
        bottom: boundingBox.bottom,
      ));
    }

    return blocks;
  }

  /// Processes an image and returns the full recognized text.
  Future<String> processImageToText(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    final recognizedText = await _textRecognizer.processImage(inputImage);
    return recognizedText.text;
  }

  /// Cleans up temp file after OCR processing.
  Future<void> cleanupTempFile(String tempPath) async {
    try {
      final file = File(tempPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      // Ignore cleanup errors
    }
  }

  /// Releases resources.
  void dispose() {
    _textRecognizer.close();
  }
}
