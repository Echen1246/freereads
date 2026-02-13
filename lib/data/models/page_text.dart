/// Represents extracted text and pre-computed phonemes from a single page.
class PageText {
  final int? id;
  final int bookId;
  final int pageNumber;
  final String text;
  /// Pre-phonemized text (misaki-compatible IPA). Null if not yet phonemized.
  final String? phonemes;
  final DateTime extractedAt;

  const PageText({
    this.id,
    required this.bookId,
    required this.pageNumber,
    required this.text,
    this.phonemes,
    required this.extractedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'book_id': bookId,
      'page_number': pageNumber,
      'text': text,
      'phonemes': phonemes,
      'extracted_at': extractedAt.toIso8601String(),
    };
  }

  factory PageText.fromMap(Map<String, dynamic> map) {
    return PageText(
      id: map['id'] as int?,
      bookId: map['book_id'] as int,
      pageNumber: map['page_number'] as int,
      text: map['text'] as String,
      phonemes: map['phonemes'] as String?,
      extractedAt: DateTime.parse(map['extracted_at'] as String),
    );
  }

  PageText copyWith({
    int? id,
    int? bookId,
    int? pageNumber,
    String? text,
    String? phonemes,
    DateTime? extractedAt,
  }) {
    return PageText(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      pageNumber: pageNumber ?? this.pageNumber,
      text: text ?? this.text,
      phonemes: phonemes ?? this.phonemes,
      extractedAt: extractedAt ?? this.extractedAt,
    );
  }
}
