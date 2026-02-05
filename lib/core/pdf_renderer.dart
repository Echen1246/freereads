import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

/// Renders PDF pages to images for OCR processing.
/// Uses pdfrx with PDFium for high-performance native rendering.
class PdfRenderer {
  PdfDocument? _document;
  String? _currentPath;

  /// Opens a PDF document from the given file path.
  Future<void> open(String path) async {
    if (_currentPath == path && _document != null) return;

    await close();
    _document = await PdfDocument.openFile(path);
    _currentPath = path;
  }

  /// Opens a PDF document from the given file path (alias for open).
  Future<void> openFile(String path) => open(path);

  /// Opens a PDF document from asset bundle.
  Future<void> openAsset(String assetPath) async {
    if (_currentPath == assetPath && _document != null) return;

    await close();
    _document = await PdfDocument.openAsset(assetPath);
    _currentPath = assetPath;
  }

  /// Returns the total number of pages in the document.
  int get pageCount => _document?.pages.length ?? 0;

  /// Renders a page to a temp file for ML Kit processing.
  /// Returns the path to the temp file.
  /// 
  /// Uses temp file pattern to avoid InputImage.fromBytes stride issues.
  Future<String> renderPageToTempFile(int pageIndex, {double scale = 2.0}) async {
    if (_document == null) {
      throw StateError('No document open. Call open() first.');
    }

    if (pageIndex < 0 || pageIndex >= pageCount) {
      throw RangeError('Page index $pageIndex out of range [0, $pageCount)');
    }

    final page = _document!.pages[pageIndex];
    
    // Render page to image
    final pdfImage = await page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
      backgroundColor: Colors.white,
    );

    if (pdfImage == null) {
      throw StateError('Failed to render page $pageIndex');
    }

    // Get the raw pixel data
    final pixels = pdfImage.pixels;
    final width = pdfImage.width;
    final height = pdfImage.height;
    final format = pdfImage.format;

    // Create BMP file in temp directory (simpler than PNG, ML Kit can read it)
    final tempDir = await getTemporaryDirectory();
    final tempPath = '${tempDir.path}/page_cache_$pageIndex.bmp';
    final tempFile = File(tempPath);

    // Convert to BMP format
    final bmpData = _createBmpFromPixels(pixels, width, height, format);
    await tempFile.writeAsBytes(bmpData);

    pdfImage.dispose();
    return tempPath;
  }

  /// Renders a page and returns the raw image for display.
  Future<PdfImage?> renderPageForDisplay(int pageIndex, {double scale = 2.0}) async {
    if (_document == null) return null;
    if (pageIndex < 0 || pageIndex >= pageCount) return null;

    final page = _document!.pages[pageIndex];
    return page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
      backgroundColor: Colors.white,
    );
  }

  /// Gets the page dimensions for a given page index.
  ({double width, double height})? getPageDimensions(int pageIndex) {
    if (_document == null || pageIndex < 0 || pageIndex >= pageCount) {
      return null;
    }
    final page = _document!.pages[pageIndex];
    return (width: page.width, height: page.height);
  }

  /// Closes the current document and releases resources.
  Future<void> close() async {
    await _document?.dispose();
    _document = null;
    _currentPath = null;
  }

  /// Creates a BMP file from pixel data.
  /// Handles both RGBA and BGRA pixel formats.
  Uint8List _createBmpFromPixels(
    Uint8List pixels,
    int width,
    int height,
    ui.PixelFormat format,
  ) {
    final rowSize = ((width * 3 + 3) ~/ 4) * 4; // Row size must be multiple of 4
    final imageSize = rowSize * height;
    final fileSize = 54 + imageSize; // Header + pixel data

    final bmp = Uint8List(fileSize);
    final data = ByteData.view(bmp.buffer);

    // BMP Header
    bmp[0] = 0x42; // 'B'
    bmp[1] = 0x4D; // 'M'
    data.setUint32(2, fileSize, Endian.little);
    data.setUint32(10, 54, Endian.little); // Pixel data offset

    // DIB Header
    data.setUint32(14, 40, Endian.little); // DIB header size
    data.setInt32(18, width, Endian.little);
    data.setInt32(22, -height, Endian.little); // Negative = top-down
    data.setUint16(26, 1, Endian.little); // Color planes
    data.setUint16(28, 24, Endian.little); // Bits per pixel (BGR)
    data.setUint32(34, imageSize, Endian.little);

    // Determine pixel order based on format
    final isRgba = format == ui.PixelFormat.rgba8888;

    // Pixel data (convert to BGR)
    for (var y = 0; y < height; y++) {
      var offset = 54 + y * rowSize;
      for (var x = 0; x < width; x++) {
        final srcIdx = (y * width + x) * 4;
        if (isRgba) {
          // RGBA -> BGR
          bmp[offset++] = pixels[srcIdx + 2]; // B
          bmp[offset++] = pixels[srcIdx + 1]; // G
          bmp[offset++] = pixels[srcIdx + 0]; // R
        } else {
          // BGRA -> BGR
          bmp[offset++] = pixels[srcIdx + 0]; // B
          bmp[offset++] = pixels[srcIdx + 1]; // G
          bmp[offset++] = pixels[srcIdx + 2]; // R
        }
      }
    }

    return bmp;
  }
}
