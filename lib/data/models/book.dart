/// Represents a book in the FreeReads library.
class Book {
  final int? id;
  final String title;
  final String path;
  final int pageCount;
  final DateTime addedAt;
  final DateTime? lastOpenedAt;
  
  // Reading progress
  final int currentPage;
  
  // Calibration settings (per-book, applied to all pages)
  final double headerCutoff;
  final double footerCutoff;
  final bool isCalibrated;
  
  // Optional cover thumbnail path
  final String? coverPath;

  const Book({
    this.id,
    required this.title,
    required this.path,
    required this.pageCount,
    required this.addedAt,
    this.lastOpenedAt,
    this.currentPage = 0,
    this.headerCutoff = 0.08,
    this.footerCutoff = 0.92,
    this.isCalibrated = false,
    this.coverPath,
  });

  Book copyWith({
    int? id,
    String? title,
    String? path,
    int? pageCount,
    DateTime? addedAt,
    DateTime? lastOpenedAt,
    int? currentPage,
    double? headerCutoff,
    double? footerCutoff,
    bool? isCalibrated,
    String? coverPath,
  }) {
    return Book(
      id: id ?? this.id,
      title: title ?? this.title,
      path: path ?? this.path,
      pageCount: pageCount ?? this.pageCount,
      addedAt: addedAt ?? this.addedAt,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
      currentPage: currentPage ?? this.currentPage,
      headerCutoff: headerCutoff ?? this.headerCutoff,
      footerCutoff: footerCutoff ?? this.footerCutoff,
      isCalibrated: isCalibrated ?? this.isCalibrated,
      coverPath: coverPath ?? this.coverPath,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'path': path,
      'page_count': pageCount,
      'added_at': addedAt.toIso8601String(),
      'last_opened_at': lastOpenedAt?.toIso8601String(),
      'current_page': currentPage,
      'header_cutoff': headerCutoff,
      'footer_cutoff': footerCutoff,
      'is_calibrated': isCalibrated ? 1 : 0,
      'cover_path': coverPath,
    };
  }

  factory Book.fromMap(Map<String, dynamic> map) {
    return Book(
      id: map['id'] as int?,
      title: map['title'] as String,
      path: map['path'] as String,
      pageCount: map['page_count'] as int,
      addedAt: DateTime.parse(map['added_at'] as String),
      lastOpenedAt: map['last_opened_at'] != null
          ? DateTime.parse(map['last_opened_at'] as String)
          : null,
      currentPage: (map['current_page'] as int?) ?? 0,
      headerCutoff: (map['header_cutoff'] as num?)?.toDouble() ?? 0.08,
      footerCutoff: (map['footer_cutoff'] as num?)?.toDouble() ?? 0.92,
      isCalibrated: (map['is_calibrated'] as int?) == 1,
      coverPath: map['cover_path'] as String?,
    );
  }

  @override
  String toString() {
    return 'Book(id: $id, title: $title, pages: $pageCount, currentPage: $currentPage, calibrated: $isCalibrated)';
  }
}
