import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/ocr_processor.dart';
import '../core/page_sorter.dart';
import '../core/pdf_renderer.dart';
import '../core/tts_engine.dart';
import '../data/database.dart';
import '../data/models/book.dart';
import '../theme/app_theme.dart';

/// Reader screen - audiobook player with continuous playback.
/// Shows calibration bottom sheet on first open if not calibrated.
class ReaderScreen extends StatefulWidget {
  final Book book;

  const ReaderScreen({super.key, required this.book});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final AppDatabase _database = AppDatabase();
  final PdfRenderer _pdfRenderer = PdfRenderer();
  final OcrProcessor _ocrProcessor = OcrProcessor();
  final PageSorter _pageSorter = PageSorter();
  final TtsEngine _ttsEngine = TtsEngine();

  late Book _book;
  
  // PDF loading state
  bool _pdfLoaded = false;
  int _totalPages = 1; // Default to 1 to avoid division by zero
  
  // Current page image for display
  PdfImage? _currentPageImage;
  ui.Image? _currentDisplayImage;
  
  // TTS state
  bool _ttsInitialized = false;
  bool _ttsInitializing = false;
  String? _ttsError;
  List<String> _availableVoices = [];
  String? _selectedVoice;
  
  // Playback state
  bool _isPlaying = false;
  bool _isProcessingPage = false;
  int _currentPage = 0;
  String _currentText = '';
  double _playbackSpeed = 1.0;
  
  // Calibration preview (for bottom sheet)
  PdfImage? _calibrationPageImage;
  ui.Image? _calibrationDisplayImage;
  double _tempHeaderCutoff = 0.08;
  double _tempFooterCutoff = 0.92;

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    _currentPage = _book.currentPage;
    _tempHeaderCutoff = _book.headerCutoff;
    _tempFooterCutoff = _book.footerCutoff;
    _initializeAll();
  }

  @override
  void dispose() {
    _calibrationPageImage?.dispose();
    _calibrationDisplayImage?.dispose();
    _currentPageImage?.dispose();
    _currentDisplayImage?.dispose();
    _pdfRenderer.close();
    _ocrProcessor.dispose();
    _ttsEngine.dispose();
    super.dispose();
  }

  Future<void> _initializeAll() async {
    try {
      // Open PDF
      await _pdfRenderer.openFile(_book.path);
      
      if (mounted) {
        setState(() {
          _pdfLoaded = true;
          _totalPages = _pdfRenderer.pageCount;
        });
      }
      
      // Load current page image
      await _loadCurrentPageImage();
      
      // Initialize TTS
      await _initializeTts();
      
      // Show calibration if needed
      if (!_book.isCalibrated && mounted) {
        _showCalibrationSheet();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to open PDF: $e')),
        );
        Navigator.of(context).pop();
      }
    }
  }
  
  Future<void> _loadCurrentPageImage() async {
    // Dispose old images
    _currentPageImage?.dispose();
    _currentDisplayImage?.dispose();
    _currentPageImage = null;
    _currentDisplayImage = null;
    
    // Render current page
    _currentPageImage = await _pdfRenderer.renderPageForDisplay(_currentPage);
    if (_currentPageImage != null) {
      _currentDisplayImage = await _currentPageImage!.createImage();
    }
    
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _initializeTts() async {
    if (_ttsInitializing) return;
    
    setState(() {
      _ttsInitializing = true;
      _ttsError = null;
    });
    
    try {
      await _ttsEngine.initialize(
        modelPath: 'assets/models/model.onnx',
        voicesPath: 'assets/models/voices.json',
        isInt8: false,
      );
      
      setState(() {
        _ttsInitialized = true;
        _ttsInitializing = false;
        _availableVoices = _ttsEngine.availableVoices;
        if (_availableVoices.isNotEmpty) {
          _selectedVoice = _availableVoices.first;
        }
      });
      
      // Listen to status changes
      _ttsEngine.statusStream.listen((status) {
        if (mounted) {
          final wasPlaying = _isPlaying;
          setState(() {
            _isPlaying = status == TtsStatus.speaking;
          });
          
          // When TTS finishes (goes back to ready), advance to next page
          if (wasPlaying && status == TtsStatus.ready && _isPlaying == false) {
            _onPageFinished();
          }
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _ttsInitializing = false;
          _ttsError = e.toString();
        });
      }
    }
  }

  Future<void> _showCalibrationSheet() async {
    // Load first page for calibration preview
    _calibrationPageImage = await _pdfRenderer.renderPageForDisplay(0);
    if (_calibrationPageImage != null) {
      _calibrationDisplayImage = await _calibrationPageImage!.createImage();
    }
    
    if (!mounted) return;
    
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _CalibrationSheet(
        displayImage: _calibrationDisplayImage,
        initialHeaderCutoff: _tempHeaderCutoff,
        initialFooterCutoff: _tempFooterCutoff,
        onCalibrationChanged: (header, footer) {
          _tempHeaderCutoff = header;
          _tempFooterCutoff = footer;
        },
      ),
    );
    
    // Clean up calibration images
    _calibrationPageImage?.dispose();
    _calibrationDisplayImage?.dispose();
    _calibrationPageImage = null;
    _calibrationDisplayImage = null;
    
    if (result == true) {
      // Save calibration
      await _database.updateCalibration(
        _book.id!,
        headerCutoff: _tempHeaderCutoff,
        footerCutoff: _tempFooterCutoff,
      );
      
      setState(() {
        _book = _book.copyWith(
          headerCutoff: _tempHeaderCutoff,
          footerCutoff: _tempFooterCutoff,
          isCalibrated: true,
        );
      });
    }
  }

  Future<void> _processCurrentPage() async {
    if (_isProcessingPage) return;
    
    setState(() => _isProcessingPage = true);
    
    try {
      // Render page to temp file for OCR
      final tempPath = await _pdfRenderer.renderPageToTempFile(_currentPage);
      
      // Run OCR
      final blocks = await _ocrProcessor.processImageFile(tempPath);
      
      // Clean up
      await _ocrProcessor.cleanupTempFile(tempPath);
      
      // Get dimensions and process text
      final dimensions = _pdfRenderer.getPageDimensions(_currentPage);
      if (dimensions != null) {
        final zone = CalibrationZone(
          headerCutoff: _book.headerCutoff,
          footerCutoff: _book.footerCutoff,
        );
        
        _currentText = _pageSorter.process(
          blocks,
          zone,
          dimensions.width * 2,
          dimensions.height * 2,
        );
      }
      
      setState(() => _isProcessingPage = false);
    } catch (e) {
      setState(() => _isProcessingPage = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('OCR failed: $e')),
        );
      }
    }
  }

  Future<void> _togglePlayback() async {
    if (!_ttsInitialized) return;
    
    if (_isPlaying) {
      await _ttsEngine.pause();
    } else if (_ttsEngine.status == TtsStatus.paused) {
      await _ttsEngine.resume();
    } else {
      await _startPlaying();
    }
  }

  Future<void> _startPlaying() async {
    if (_currentText.isEmpty) {
      await _processCurrentPage();
    }
    
    if (_currentText.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No text found on this page')),
        );
      }
      return;
    }
    
    try {
      if (_selectedVoice != null) {
        _ttsEngine.setVoice(_selectedVoice!);
      }
      await _ttsEngine.speak(_currentText);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('TTS Error: $e')),
        );
      }
    }
  }

  void _onPageFinished() {
    // Auto-advance to next page
    if (_currentPage < _totalPages - 1) {
      _goToNextPage();
    }
  }

  Future<void> _goToNextPage({bool autoPlay = true}) async {
    if (_currentPage >= _totalPages - 1) return;
    
    await _ttsEngine.stop();
    
    setState(() {
      _currentPage++;
      _currentText = '';
    });
    
    // Load new page image
    await _loadCurrentPageImage();
    
    // Save progress
    await _database.updateCurrentPage(_book.id!, _currentPage);
    
    // Start playing next page
    if (autoPlay) {
      await _startPlaying();
    }
  }

  Future<void> _goToPreviousPage({bool autoPlay = true}) async {
    if (_currentPage <= 0) return;
    
    await _ttsEngine.stop();
    
    setState(() {
      _currentPage--;
      _currentText = '';
    });
    
    // Load new page image
    await _loadCurrentPageImage();
    
    // Save progress
    await _database.updateCurrentPage(_book.id!, _currentPage);
    
    // Start playing
    if (autoPlay) {
      await _startPlaying();
    }
  }
  
  /// Navigate to a specific page (for manual navigation without auto-play)
  Future<void> _goToPage(int page) async {
    if (page < 0 || page >= _totalPages || page == _currentPage) return;
    
    await _ttsEngine.stop();
    
    setState(() {
      _currentPage = page;
      _currentText = '';
    });
    
    // Load new page image
    await _loadCurrentPageImage();
    
    // Save progress
    await _database.updateCurrentPage(_book.id!, _currentPage);
  }

  void _setPlaybackSpeed(double speed) {
    setState(() => _playbackSpeed = speed);
    _ttsEngine.setRate(speed);
  }

  /// Test: speak "countries" with correct phonemes to verify if model or phonemizer is the issue
  Future<void> _runPhonemeTest() async {
    if (_ttsEngine.status != TtsStatus.ready) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('TTS not ready')),
      );
      return;
    }

    // Show test options
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSheetHandle(ctx),
              const SizedBox(height: 16),
              Text('Phoneme Test', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Test if the issue is the phonemizer (malsami) or the model (Kokoro).',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.text_fields),
                title: const Text('Say "countries" (via malsami)'),
                subtitle: const Text('Uses our phonemizer'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await _ttsEngine.speak('countries');
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e')),
                      );
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.music_note),
                title: const Text('Say "countries" (correct phonemes)'),
                subtitle: const Text('Bypasses malsami: kˈʌntɹiz'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await _ttsEngine.speakPhonemes('kˈʌntɹiz');
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e')),
                      );
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.music_note),
                title: const Text('Say full sentence (correct phonemes)'),
                subtitle: const Text('Both countries sound natural'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    // "I am sure that no two countries are more alike"
                    await _ttsEngine.speakPhonemes(
                      'aɪ æm ʃʊɹ ðæt noʊ tuː kˈʌntɹiz ɑɹ mɔɹ əlaɪk.'
                    );
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e')),
                      );
                    }
                  }
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  void _showSpeedDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            _buildSheetHandle(context),
            const SizedBox(height: 16),
            Text('Playback Speed', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 24),
            StatefulBuilder(
              builder: (context, setSheetState) {
                return Column(
                  children: [
                    Text(
                      '${_playbackSpeed.toStringAsFixed(2)}x',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Text('0.5x'),
                          Expanded(
                            child: Slider(
                              value: _playbackSpeed,
                              min: 0.5,
                              max: 2.0,
                              divisions: 30, // 0.05 increments
                              onChanged: (value) {
                                setSheetState(() {});
                                _setPlaybackSpeed(value);
                              },
                            ),
                          ),
                          const Text('2.0x'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Quick preset buttons
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [0.75, 0.9, 1.0, 1.1, 1.25].map((speed) => 
                          TextButton(
                            onPressed: () {
                              setSheetState(() {});
                              _setPlaybackSpeed(speed);
                            },
                            style: TextButton.styleFrom(
                              backgroundColor: (_playbackSpeed - speed).abs() < 0.01
                                  ? Theme.of(context).colorScheme.primaryContainer
                                  : null,
                            ),
                            child: Text('${speed}x'),
                          ),
                        ).toList(),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showVoiceSelector() {
    if (_availableVoices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No voices available')),
      );
      return;
    }
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            _buildSheetHandle(context),
            const SizedBox(height: 16),
            Text('Select Voice', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            SizedBox(
              height: 300,
              child: ListView.builder(
                itemCount: _availableVoices.length,
                itemBuilder: (context, index) {
                  final voice = _availableVoices[index];
                  return ListTile(
                    title: Text(voice),
                    trailing: _selectedVoice == voice
                        ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () {
                      setState(() => _selectedVoice = voice);
                      Navigator.of(context).pop();
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSheetHandle(BuildContext context) {
    return Container(
      width: 40,
      height: 4,
      decoration: BoxDecoration(
        color: Theme.of(context).dividerColor,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Show loading while PDF is opening
    if (!_pdfLoaded) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Opening book...', style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      );
    }
    
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down),
                    onPressed: () => Navigator.of(context).pop(),
                    iconSize: 32,
                  ),
                  const Spacer(),
                  Text(
                    'Page ${_currentPage + 1} of $_totalPages',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.science),
                    onPressed: _runPhonemeTest,
                    tooltip: 'Test Phonemes',
                  ),
                  IconButton(
                    icon: const Icon(Icons.tune),
                    onPressed: _showCalibrationSheet,
                    tooltip: 'Recalibrate',
                  ),
                ],
              ),
            ),

            // PDF Page Display (centered, takes most of the space)
            Expanded(
              flex: 5,
              child: _buildPdfPageView(),
            ),
            
            const SizedBox(height: 16),

            // Voice selector and TTS status
            if (_ttsInitializing)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Loading TTS...',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              )
            else if (_ttsError != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: GestureDetector(
                  onTap: _initializeTts,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 16,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'TTS failed - tap to retry',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              GestureDetector(
                onTap: _showVoiceSelector,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.record_voice_over,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _selectedVoice ?? 'Select voice',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 20,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 16),

            // Progress indicator
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _isProcessingPage
                  ? const LinearProgressIndicator()
                  : LinearProgressIndicator(
                      value: _totalPages > 0 ? (_currentPage + 1) / _totalPages : 0,
                      backgroundColor: Theme.of(context).colorScheme.surface,
                    ),
            ),

            const SizedBox(height: 24),

            // Playback controls
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Speed button
                TextButton(
                  onPressed: _ttsInitialized ? _showSpeedDialog : null,
                  child: Text(
                    '${_playbackSpeed}x',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                
                const SizedBox(width: 24),
                
                // Previous page
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded),
                  iconSize: 36,
                  onPressed: _currentPage > 0 ? _goToPreviousPage : null,
                ),
                
                const SizedBox(width: 16),
                
                // Play/Pause button
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _ttsInitialized
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.surface,
                  ),
                  child: IconButton(
                    icon: Icon(
                      _isPlaying ? Icons.pause : Icons.play_arrow,
                      color: _ttsInitialized ? Colors.black : Colors.grey,
                    ),
                    iconSize: 48,
                    onPressed: _ttsInitialized && !_isProcessingPage
                        ? _togglePlayback
                        : null,
                    padding: const EdgeInsets.all(16),
                  ),
                ),
                
                const SizedBox(width: 16),
                
                // Next page
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded),
                  iconSize: 36,
                  onPressed: _currentPage < _totalPages - 1
                      ? _goToNextPage
                      : null,
                ),
                
                const SizedBox(width: 24),
                
                // Stop button
                IconButton(
                  icon: const Icon(Icons.stop),
                  onPressed: _isPlaying ? () => _ttsEngine.stop() : null,
                ),
              ],
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  /// Builds the PDF page view with swipe navigation
  Widget _buildPdfPageView() {
    return GestureDetector(
      // Swipe to navigate pages
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity == null) return;
        
        if (details.primaryVelocity! < -300) {
          // Swipe left -> next page (don't auto-play when swiping)
          _goToNextPage(autoPlay: false);
        } else if (details.primaryVelocity! > 300) {
          // Swipe right -> previous page
          _goToPreviousPage(autoPlay: false);
        }
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        child: Center(
          child: _currentDisplayImage != null
              ? Container(
                  decoration: BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: RawImage(
                      image: _currentDisplayImage,
                      fit: BoxFit.contain,
                    ),
                  ),
                )
              : Container(
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        'Loading page...',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// Calibration bottom sheet for adjusting header/footer cutoffs.
class _CalibrationSheet extends StatefulWidget {
  final ui.Image? displayImage;
  final double initialHeaderCutoff;
  final double initialFooterCutoff;
  final void Function(double header, double footer) onCalibrationChanged;

  const _CalibrationSheet({
    required this.displayImage,
    required this.initialHeaderCutoff,
    required this.initialFooterCutoff,
    required this.onCalibrationChanged,
  });

  @override
  State<_CalibrationSheet> createState() => _CalibrationSheetState();
}

class _CalibrationSheetState extends State<_CalibrationSheet> {
  late double _headerCutoff;
  late double _footerCutoff;

  @override
  void initState() {
    super.initState();
    _headerCutoff = widget.initialHeaderCutoff;
    _footerCutoff = widget.initialFooterCutoff;
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // Handle
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            
            // Title
            Text(
              'Calibrate Reading Zone',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Drag the overlays to exclude headers and footers',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 16),
            
            // Page preview with overlays
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      children: [
                        // Page image
                        if (widget.displayImage != null)
                          Center(
                            child: Container(
                              decoration: BoxDecoration(
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 20,
                                    offset: const Offset(0, 10),
                                  ),
                                ],
                              ),
                              child: RawImage(
                                image: widget.displayImage,
                                fit: BoxFit.contain,
                              ),
                            ),
                          )
                        else
                          const Center(child: Text('Preview unavailable')),
                        
                        // Header overlay
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: constraints.maxHeight * _headerCutoff,
                          child: GestureDetector(
                            onVerticalDragUpdate: (details) {
                              setState(() {
                                _headerCutoff = ((_headerCutoff * constraints.maxHeight +
                                            details.delta.dy) /
                                        constraints.maxHeight)
                                    .clamp(0.0, _footerCutoff - 0.1);
                                widget.onCalibrationChanged(_headerCutoff, _footerCutoff);
                              });
                            },
                            child: Container(
                              color: AppTheme.calibrationZone,
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: Container(
                                  height: 24,
                                  decoration: const BoxDecoration(
                                    border: Border(
                                      bottom: BorderSide(
                                        color: AppTheme.calibrationBorder,
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                  child: const Center(
                                    child: Icon(
                                      Icons.drag_handle,
                                      color: AppTheme.calibrationBorder,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        
                        // Footer overlay
                        Positioned(
                          top: constraints.maxHeight * _footerCutoff,
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: GestureDetector(
                            onVerticalDragUpdate: (details) {
                              setState(() {
                                _footerCutoff = ((_footerCutoff * constraints.maxHeight +
                                            details.delta.dy) /
                                        constraints.maxHeight)
                                    .clamp(_headerCutoff + 0.1, 1.0);
                                widget.onCalibrationChanged(_headerCutoff, _footerCutoff);
                              });
                            },
                            child: Container(
                              color: AppTheme.calibrationZone,
                              child: Align(
                                alignment: Alignment.topCenter,
                                child: Container(
                                  height: 24,
                                  decoration: const BoxDecoration(
                                    border: Border(
                                      top: BorderSide(
                                        color: AppTheme.calibrationBorder,
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                  child: const Center(
                                    child: Icon(
                                      Icons.drag_handle,
                                      color: AppTheme.calibrationBorder,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            
            // Action buttons
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Apply'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
