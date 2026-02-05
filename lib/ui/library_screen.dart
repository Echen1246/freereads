import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/pdf_renderer.dart';
import '../data/database.dart';
import '../data/models/book.dart';
import 'reader_screen.dart';

/// Library screen - Kindle-style grid of book covers.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final AppDatabase _database = AppDatabase();
  List<Book> _books = [];
  bool _isLoading = true;
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    setState(() => _isLoading = true);
    try {
      final books = await _database.getAllBooks();
      setState(() {
        _books = books;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load books: $e')),
        );
      }
    }
  }

  Future<void> _importPdf() async {
    if (_isImporting) return;

    setState(() => _isImporting = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        setState(() => _isImporting = false);
        return;
      }

      final file = result.files.first;
      if (file.path == null) {
        throw Exception('Could not access file path');
      }

      // Copy PDF to app's documents directory
      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory('${appDir.path}/books');
      if (!await booksDir.exists()) {
        await booksDir.create(recursive: true);
      }

      final fileName = p.basename(file.path!);
      final newPath = '${booksDir.path}/$fileName';

      // Check if already imported
      final existingBook = await _database.getBookByPath(newPath);
      if (existingBook != null) {
        setState(() => _isImporting = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('This book is already in your library')),
          );
        }
        return;
      }

      // Copy file
      await File(file.path!).copy(newPath);

      // Get page count and generate cover
      final pdfRenderer = PdfRenderer();
      await pdfRenderer.openFile(newPath);
      final pageCount = pdfRenderer.pageCount;

      // Generate cover thumbnail
      String? coverPath;
      try {
        final coversDir = Directory('${appDir.path}/covers');
        if (!await coversDir.exists()) {
          await coversDir.create(recursive: true);
        }
        coverPath = await pdfRenderer.renderPageToTempFile(0, scale: 0.5);
        // Move to covers directory with proper name
        final coverFileName = '${p.basenameWithoutExtension(fileName)}_cover.bmp';
        final finalCoverPath = '${coversDir.path}/$coverFileName';
        await File(coverPath).copy(finalCoverPath);
        await File(coverPath).delete();
        coverPath = finalCoverPath;
      } catch (e) {
        // Cover generation failed, continue without cover
        coverPath = null;
      }

      pdfRenderer.close();

      // Extract title from filename
      final title = p.basenameWithoutExtension(fileName)
          .replaceAll('-', ' ')
          .replaceAll('_', ' ');

      // Add to database
      final book = Book(
        title: title,
        path: newPath,
        pageCount: pageCount,
        addedAt: DateTime.now(),
        coverPath: coverPath,
      );

      await _database.insertBook(book);
      await _loadBooks();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added "$title" to library')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to import: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      setState(() => _isImporting = false);
    }
  }

  Future<void> _openBook(Book book) async {
    await _database.updateLastOpened(book.id!);

    if (mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ReaderScreen(book: book),
        ),
      );
      // Refresh on return
      _loadBooks();
    }
  }

  Future<void> _deleteBook(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Book'),
        content: Text('Remove "${book.title}" from your library?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Delete',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        // Delete cover file
        if (book.coverPath != null) {
          final coverFile = File(book.coverPath!);
          if (await coverFile.exists()) {
            await coverFile.delete();
          }
        }
        // Delete PDF file
        final pdfFile = File(book.path);
        if (await pdfFile.exists()) {
          await pdfFile.delete();
        }
        // Delete from database
        await _database.deleteBook(book.id!);
        await _loadBooks();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Deleted "${book.title}"')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'FreeReads',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                          letterSpacing: -1.5,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Your Library',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                  ),
                ],
              ),
            ),

            // Content
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _books.isEmpty
                      ? _buildEmptyState()
                      : _buildBookGrid(),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isImporting ? null : _importPdf,
        icon: _isImporting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                ),
              )
            : const Icon(Icons.add),
        label: Text(_isImporting ? 'Importing...' : 'Add Book'),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color:
                      Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                  width: 2,
                ),
              ),
              child: Icon(
                Icons.library_books_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No books yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Tap the button below to add your first PDF',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6),
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBookGrid() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.65,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: _books.length,
      itemBuilder: (context, index) {
        final book = _books[index];
        return _BookCard(
          book: book,
          onTap: () => _openBook(book),
          onLongPress: () => _deleteBook(book),
        );
      },
    );
  }
}

class _BookCard extends StatelessWidget {
  final Book book;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _BookCard({
    required this.book,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cover
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _buildCover(context),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Title
          Text(
            book.title,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          // Progress
          Row(
            children: [
              if (book.currentPage > 0) ...[
                Icon(
                  Icons.bookmark,
                  size: 12,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 4),
              ],
              Text(
                book.currentPage > 0
                    ? 'Page ${book.currentPage + 1} of ${book.pageCount}'
                    : '${book.pageCount} pages',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.5),
                    ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCover(BuildContext context) {
    if (book.coverPath != null) {
      final file = File(book.coverPath!);
      return Image.file(
        file,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) {
          return _buildPlaceholderCover(context);
        },
      );
    }
    return _buildPlaceholderCover(context);
  }

  Widget _buildPlaceholderCover(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.menu_book_rounded,
              size: 48,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                book.title,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.5),
                    ),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
