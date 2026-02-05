import 'ocr_processor.dart';

/// Calibration zone configuration for filtering text blocks.
class CalibrationZone {
  /// Top boundary as percentage of page height (0.0-1.0)
  final double headerCutoff;
  
  /// Bottom boundary as percentage of page height (0.0-1.0)
  final double footerCutoff;
  
  /// Left boundary as percentage of page width (0.0-1.0)
  final double leftMargin;
  
  /// Right boundary as percentage of page width (0.0-1.0)
  final double rightMargin;

  const CalibrationZone({
    this.headerCutoff = 0.05,
    this.footerCutoff = 0.95,
    this.leftMargin = 0.05,
    this.rightMargin = 0.95,
  });

  /// Default calibration with reasonable margins
  static const CalibrationZone defaultZone = CalibrationZone();
}

/// The "Heuristic Janitor" - filters and sorts OCR text blocks
/// into proper reading order.
class PageSorter {
  /// Tolerance for column detection (as percentage of page width).
  /// Blocks within this horizontal tolerance are considered same column.
  final double columnTolerance;

  PageSorter({this.columnTolerance = 0.15});

  /// Filters text blocks to only include those within the calibration zone.
  List<OcrTextBlock> filterByZone(
    List<OcrTextBlock> blocks,
    CalibrationZone zone,
    double pageWidth,
    double pageHeight,
  ) {
    final minX = pageWidth * zone.leftMargin;
    final maxX = pageWidth * zone.rightMargin;
    final minY = pageHeight * zone.headerCutoff;
    final maxY = pageHeight * zone.footerCutoff;

    return blocks.where((block) {
      // Block must be substantially within the zone
      final blockCenterX = block.centerX;
      final blockCenterY = block.centerY;
      
      return blockCenterX >= minX && 
             blockCenterX <= maxX && 
             blockCenterY >= minY && 
             blockCenterY <= maxY;
    }).toList();
  }

  /// Sorts text blocks in reading order.
  /// Handles both single-column and two-column layouts.
  /// 
  /// Algorithm:
  /// 1. Detect if layout is single or multi-column based on X distribution
  /// 2. Group blocks by column (using X-bucket tolerance)
  /// 3. Sort each column by Y position (top to bottom)
  /// 4. Concatenate columns left to right
  List<OcrTextBlock> sortInReadingOrder(
    List<OcrTextBlock> blocks,
    double pageWidth,
  ) {
    if (blocks.isEmpty) return [];
    if (blocks.length == 1) return blocks;

    // Detect columns by clustering X positions
    final columns = _detectColumns(blocks, pageWidth);
    
    // Sort each column by Y position
    for (final column in columns) {
      column.sort((a, b) => a.top.compareTo(b.top));
    }

    // Flatten columns left to right
    return columns.expand((column) => column).toList();
  }

  /// Detects columns in the text blocks.
  /// Returns a list of columns, each containing blocks sorted by X position.
  List<List<OcrTextBlock>> _detectColumns(
    List<OcrTextBlock> blocks,
    double pageWidth,
  ) {
    final tolerance = pageWidth * columnTolerance;
    
    // Sort blocks by X position first
    final sortedByX = List<OcrTextBlock>.from(blocks)
      ..sort((a, b) => a.left.compareTo(b.left));

    final columns = <List<OcrTextBlock>>[];
    
    for (final block in sortedByX) {
      bool addedToColumn = false;
      
      // Try to add to existing column
      for (final column in columns) {
        final columnCenterX = column
            .map((b) => b.centerX)
            .reduce((a, b) => a + b) / column.length;
        
        if ((block.centerX - columnCenterX).abs() < tolerance) {
          column.add(block);
          addedToColumn = true;
          break;
        }
      }
      
      // Create new column if not added
      if (!addedToColumn) {
        columns.add([block]);
      }
    }

    // Sort columns left to right by average X position
    columns.sort((a, b) {
      final avgA = a.map((b) => b.centerX).reduce((x, y) => x + y) / a.length;
      final avgB = b.map((b) => b.centerX).reduce((x, y) => x + y) / b.length;
      return avgA.compareTo(avgB);
    });

    return columns;
  }

  /// Merges hyphenated words across line breaks.
  /// Pattern: word- \n continued -> wordcontinued
  String mergeHyphenatedWords(String text) {
    // Match word ending with hyphen, followed by newline and lowercase letter
    final pattern = RegExp(r'(\w)-\s*\n\s*([a-z])');
    return text.replaceAllMapped(pattern, (match) {
      return '${match.group(1)}${match.group(2)}';
    });
  }

  /// Combines all blocks into a single string in reading order.
  String blocksToText(List<OcrTextBlock> sortedBlocks) {
    final text = sortedBlocks.map((b) => b.text).join('\n');
    return mergeHyphenatedWords(text);
  }

  /// Full pipeline: filter, sort, and merge to produce clean text.
  String process(
    List<OcrTextBlock> blocks,
    CalibrationZone zone,
    double pageWidth,
    double pageHeight,
  ) {
    final filtered = filterByZone(blocks, zone, pageWidth, pageHeight);
    final sorted = sortInReadingOrder(filtered, pageWidth);
    return blocksToText(sorted);
  }
}
