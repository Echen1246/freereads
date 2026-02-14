import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/espeak_phonemizer.dart';
import '../core/page_sorter.dart';
import '../core/pdf_renderer.dart';
import '../core/tts_engine.dart';
import '../data/database.dart';
import '../data/models/book.dart';
import '../data/models/page_text.dart';
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

  /// Book IDs currently being processed (text extraction).
  final Map<int, double> _processingProgress = {};

  static const _onboardingKey = 'has_seen_onboarding';

  @override
  void initState() {
    super.initState();
    _loadBooks();
    _checkFirstLaunch();
  }

  Future<void> _checkFirstLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_onboardingKey) != true) {
      if (mounted) {
        await _showOnboarding();
        await prefs.setBool(_onboardingKey, true);
      }
    }
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

      // Add to database (isProcessed defaults to false)
      final book = Book(
        title: title,
        path: newPath,
        pageCount: pageCount,
        addedAt: DateTime.now(),
        coverPath: coverPath,
      );

      final bookId = await _database.insertBook(book);
      await _loadBooks();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Processing "$title"...')),
        );
      }

      // Start text extraction in background (doesn't block UI between pages)
      _processBook(bookId, newPath, pageCount);
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

  /// Extracts text from all pages of a native PDF, phonemizes it, and
  /// stores both text and phonemes in the DB.
  /// Runs after import; each page extraction is fast for native PDFs.
  Future<void> _processBook(int bookId, String pdfPath, int pageCount) async {
    if (_processingProgress.containsKey(bookId)) return; // already processing

    setState(() => _processingProgress[bookId] = 0);

    final renderer = PdfRenderer();
    final sorter = PageSorter();

    try {
      await renderer.openFile(pdfPath);

      // Ensure espeak is initialized for phonemization
      final espeakReady = await EspeakPhonemizer.initialize();
      if (!espeakReady) {
        debugPrint('[Library] espeak not available, storing text only');
      }

      for (int i = 0; i < pageCount; i++) {
        // Check if already extracted (e.g., partial previous run)
        if (await _database.hasPageText(bookId, i)) {
          setState(() => _processingProgress[bookId] = (i + 1) / pageCount);
          continue;
        }

        // Try native text extraction (fast path)
        String? text = await renderer.extractNativeText(i);

        if (text != null && text.isNotEmpty) {
          text = sorter.reflowText(text);
        }

        // Pre-phonemize per sentence so playback can skip phonemization
        // entirely and still do accurate sentence-to-batch tracking.
        String? phonemesJson;
        if (text != null && text.isNotEmpty && espeakReady) {
          final sentences = TtsEngine.splitSentences(text);
          final sentencePhonemes = <String>[];
          for (final s in sentences) {
            final ph = EspeakPhonemizer.phonemize(s);
            sentencePhonemes.add(ph ?? s);
          }
          phonemesJson = jsonEncode(sentencePhonemes);
          debugPrint('[Library] Page $i: ${sentences.length} sentences, '
              '${text.length} chars');
        }

        // Store text + per-sentence phonemes JSON
        await _database.upsertPageText(PageText(
          bookId: bookId,
          pageNumber: i,
          text: text ?? '',
          phonemes: phonemesJson,
          extractedAt: DateTime.now(),
        ));

        if (mounted) {
          setState(() => _processingProgress[bookId] = (i + 1) / pageCount);
        }
      }

      // Mark book as processed
      await _database.markProcessed(bookId);
      await _loadBooks();

      debugPrint('[Library] Book $bookId processing complete ($pageCount pages)');
    } catch (e) {
      debugPrint('[Library] Error processing book $bookId: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Processing failed: $e')),
        );
      }
    } finally {
      await renderer.close();
      if (mounted) {
        setState(() => _processingProgress.remove(bookId));
      }
    }
  }

  Future<void> _openBook(Book book) async {
    if (!book.isProcessed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Book is still processing...')),
        );
      }
      return;
    }

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

  /// Multi-slide onboarding dialog explaining app features.
  Future<void> _showOnboarding() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _OnboardingDialog(),
    );
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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
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
                  IconButton(
                    icon: Icon(
                      Icons.help_outline,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.5),
                    ),
                    onPressed: _showOnboarding,
                    tooltip: 'How it works',
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
          processingProgress: _processingProgress[book.id],
          onTap: () => _openBook(book),
          onLongPress: () => _deleteBook(book),
        );
      },
    );
  }
}

class _BookCard extends StatelessWidget {
  final Book book;
  final double? processingProgress; // null = not processing, 0.0-1.0 = progress
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _BookCard({
    required this.book,
    this.processingProgress,
    required this.onTap,
    required this.onLongPress,
  });

  bool get _isProcessing => processingProgress != null || !book.isProcessed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Opacity(
        opacity: _isProcessing ? 0.5 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cover
            Expanded(
              child: Stack(
                children: [
                  Container(
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
                  // Processing overlay
                  if (_isProcessing)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 32,
                                height: 32,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  value: processingProgress,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                processingProgress != null
                                    ? '${(processingProgress! * 100).toInt()}%'
                                    : 'Processing...',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
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
                if (book.currentPage > 0 && !_isProcessing) ...[
                  Icon(
                    Icons.bookmark,
                    size: 12,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                ],
                Text(
                  _isProcessing
                      ? 'Processing...'
                      : book.currentPage > 0
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

// ---------------------------------------------------------------------------
// Onboarding dialog
// ---------------------------------------------------------------------------

class _OnboardingDialog extends StatefulWidget {
  const _OnboardingDialog();

  @override
  State<_OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<_OnboardingDialog> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  static const _slides = <_OnboardingSlide>[
    _OnboardingSlide(
      icon: Icons.menu_book_rounded,
      title: 'Welcome to FreeReads',
      body: 'Turn any PDF textbook into a human-quality audiobook. '
          'Everything runs on your device -- no internet, no accounts, '
          'no subscriptions.',
    ),
    _OnboardingSlide(
      icon: Icons.add_circle_outline,
      title: 'Import a Book',
      body: 'Tap "Add Book" to import a PDF. FreeReads will extract the '
          'text and prepare pronunciations automatically. The book will '
          'be grayed out until processing finishes.',
    ),
    _OnboardingSlide(
      icon: Icons.record_voice_over,
      title: 'Choose a Voice',
      body: 'Pick from several American and British voices, male or female. '
          'Tap the voice name at the bottom of the reader to switch anytime.',
    ),
    _OnboardingSlide(
      icon: Icons.subtitles,
      title: 'Live Captions',
      body: 'Follow along with sentence-by-sentence captions while '
          'listening. Toggle them on or off with the subtitles button '
          'in the top-right corner of the reader.',
    ),
    _OnboardingSlide(
      icon: Icons.tune,
      title: 'Calibrate Pages',
      body: 'If the reader picks up headers or page numbers, tap the '
          'tune icon to adjust header/footer cutoff sliders so only '
          'the main text is read aloud.',
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _next() {
    if (_currentPage < _slides.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 280,
              child: PageView.builder(
                controller: _pageController,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _currentPage = i),
                itemBuilder: (context, index) {
                  final slide = _slides[index];
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          slide.icon,
                          size: 32,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        slide.title,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        slide.body,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurface.withValues(alpha: 0.7),
                              height: 1.5,
                            ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            // Page dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_slides.length, (i) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _currentPage == i ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _currentPage == i
                        ? colorScheme.primary
                        : colorScheme.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
            const SizedBox(height: 24),
            // Buttons
            Row(
              children: [
                if (_currentPage > 0)
                  TextButton(
                    onPressed: () => _pageController.previousPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    ),
                    child: const Text('Back'),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: _next,
                  child: Text(
                    _currentPage < _slides.length - 1 ? 'Next' : 'Get Started',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardingSlide {
  final IconData icon;
  final String title;
  final String body;

  const _OnboardingSlide({
    required this.icon,
    required this.title,
    required this.body,
  });
}
