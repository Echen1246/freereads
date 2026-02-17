import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'models/book.dart';
import 'models/page_text.dart';

/// Local SQLite database for storing books and extracted text.
class AppDatabase {
  static const String _databaseName = 'freereads.db';
  static const int _databaseVersion = 4;

  Database? _database;

  /// Opens the database connection.
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final databasesPath = await getDatabasesPath();
    final path = join(databasesPath, _databaseName);

    return openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // Books table with calibration and progress
    await db.execute('''
      CREATE TABLE books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        path TEXT NOT NULL UNIQUE,
        page_count INTEGER NOT NULL,
        added_at TEXT NOT NULL,
        last_opened_at TEXT,
        current_page INTEGER DEFAULT 0,
        header_cutoff REAL DEFAULT 0.08,
        footer_cutoff REAL DEFAULT 0.92,
        is_calibrated INTEGER DEFAULT 0,
        cover_path TEXT,
        is_processed INTEGER DEFAULT 0
      )
    ''');

    // Pages table for extracted text and pre-computed phonemes
    await db.execute('''
      CREATE TABLE pages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        page_number INTEGER NOT NULL,
        text TEXT NOT NULL,
        phonemes TEXT,
        extracted_at TEXT NOT NULL,
        FOREIGN KEY (book_id) REFERENCES books (id) ON DELETE CASCADE,
        UNIQUE (book_id, page_number)
      )
    ''');

    // Index for faster page lookups
    await db.execute('''
      CREATE INDEX idx_pages_book_page ON pages (book_id, page_number)
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE books ADD COLUMN current_page INTEGER DEFAULT 0');
      await db.execute('ALTER TABLE books ADD COLUMN header_cutoff REAL DEFAULT 0.08');
      await db.execute('ALTER TABLE books ADD COLUMN footer_cutoff REAL DEFAULT 0.92');
      await db.execute('ALTER TABLE books ADD COLUMN is_calibrated INTEGER DEFAULT 0');
      await db.execute('ALTER TABLE books ADD COLUMN cover_path TEXT');
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE books ADD COLUMN is_processed INTEGER DEFAULT 0');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE pages ADD COLUMN phonemes TEXT');
    }
  }

  // ============ Book Operations ============

  /// Inserts a new book and returns its ID.
  Future<int> insertBook(Book book) async {
    final db = await database;
    return db.insert('books', book.toMap()..remove('id'));
  }

  /// Gets all books ordered by last opened.
  Future<List<Book>> getAllBooks() async {
    final db = await database;
    final maps = await db.query(
      'books',
      orderBy: 'last_opened_at DESC, added_at DESC',
    );
    return maps.map((m) => Book.fromMap(m)).toList();
  }

  /// Gets a book by ID.
  Future<Book?> getBook(int id) async {
    final db = await database;
    final maps = await db.query('books', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Book.fromMap(maps.first);
  }

  /// Updates book's last opened timestamp.
  Future<void> updateLastOpened(int bookId) async {
    final db = await database;
    await db.update(
      'books',
      {'last_opened_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  /// Updates book's reading progress (current page).
  Future<void> updateCurrentPage(int bookId, int currentPage) async {
    final db = await database;
    await db.update(
      'books',
      {
        'current_page': currentPage,
        'last_opened_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  /// Updates book's calibration settings.
  Future<void> updateCalibration(
    int bookId, {
    required double headerCutoff,
    required double footerCutoff,
  }) async {
    final db = await database;
    await db.update(
      'books',
      {
        'header_cutoff': headerCutoff,
        'footer_cutoff': footerCutoff,
        'is_calibrated': 1,
      },
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  /// Updates book's cover thumbnail path.
  Future<void> updateCoverPath(int bookId, String coverPath) async {
    final db = await database;
    await db.update(
      'books',
      {'cover_path': coverPath},
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  /// Checks if a book exists by path.
  Future<Book?> getBookByPath(String path) async {
    final db = await database;
    final maps = await db.query('books', where: 'path = ?', whereArgs: [path]);
    if (maps.isEmpty) return null;
    return Book.fromMap(maps.first);
  }

  /// Marks a book as fully processed (text extraction complete).
  Future<void> markProcessed(int bookId) async {
    final db = await database;
    await db.update(
      'books',
      {'is_processed': 1},
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  /// Deletes a book and its pages.
  Future<void> deleteBook(int id) async {
    final db = await database;
    await db.delete('books', where: 'id = ?', whereArgs: [id]);
  }

  // ============ Page Operations ============

  /// Inserts or updates a page's text.
  Future<void> upsertPageText(PageText page) async {
    final db = await database;
    await db.insert(
      'pages',
      page.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Gets text for a specific page.
  Future<PageText?> getPageText(int bookId, int pageNumber) async {
    final db = await database;
    final maps = await db.query(
      'pages',
      where: 'book_id = ? AND page_number = ?',
      whereArgs: [bookId, pageNumber],
    );
    if (maps.isEmpty) return null;
    return PageText.fromMap(maps.first);
  }

  /// Gets all pages for a book in order.
  Future<List<PageText>> getAllPages(int bookId) async {
    final db = await database;
    final maps = await db.query(
      'pages',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'page_number ASC',
    );
    return maps.map((m) => PageText.fromMap(m)).toList();
  }

  /// Checks if a page has been extracted.
  Future<bool> hasPageText(int bookId, int pageNumber) async {
    final db = await database;
    final count = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM pages WHERE book_id = ? AND page_number = ?',
      [bookId, pageNumber],
    ));
    return count != null && count > 0;
  }

  /// Gets the count of extracted pages for a book.
  Future<int> getExtractedPageCount(int bookId) async {
    final db = await database;
    final count = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM pages WHERE book_id = ?',
      [bookId],
    ));
    return count ?? 0;
  }

  /// Closes the database connection.
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
