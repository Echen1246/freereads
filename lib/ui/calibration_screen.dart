import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/ocr_processor.dart';
import '../core/page_sorter.dart';
import '../core/pdf_renderer.dart';
import '../theme/app_theme.dart';
import 'player_screen.dart';

/// Calibration screen for defining content zones on PDF pages.
/// User drags overlays to define header/footer cutoffs and content body.
class CalibrationScreen extends StatefulWidget {
  final String pdfAssetPath;

  const CalibrationScreen({
    super.key,
    required this.pdfAssetPath,
  });

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  final PdfRenderer _pdfRenderer = PdfRenderer();
  final OcrProcessor _ocrProcessor = OcrProcessor();
  final PageSorter _pageSorter = PageSorter();

  // Calibration zone as percentages (0.0 - 1.0)
  double _headerCutoff = 0.08;
  double _footerCutoff = 0.92;

  // State
  bool _isLoading = true;
  bool _isProcessing = false;
  String? _errorMessage;
  PdfImage? _pageImage;
  ui.Image? _displayImage;
  String? _extractedText;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _loadPdf();
  }

  @override
  void dispose() {
    _pageImage?.dispose();
    _displayImage?.dispose();
    _pdfRenderer.close();
    _ocrProcessor.dispose();
    super.dispose();
  }

  Future<void> _loadPdf() async {
    try {
      await _pdfRenderer.openAsset(widget.pdfAssetPath);
      await _renderCurrentPage();
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load PDF: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _renderCurrentPage() async {
    setState(() => _isLoading = true);
    
    try {
      _pageImage?.dispose();
      _displayImage?.dispose();
      
      _pageImage = await _pdfRenderer.renderPageForDisplay(_currentPage);
      
      if (_pageImage != null) {
        _displayImage = await _pageImage!.createImage();
      }
      
      _extractedText = null;
      
      setState(() {
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to render page: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _runOcr() async {
    if (_isProcessing) return;
    
    setState(() => _isProcessing = true);
    
    try {
      // Render page to temp file for OCR
      final tempPath = await _pdfRenderer.renderPageToTempFile(_currentPage);
      
      // Run OCR
      final blocks = await _ocrProcessor.processImageFile(tempPath);
      
      // Clean up temp file
      await _ocrProcessor.cleanupTempFile(tempPath);
      
      // Get page dimensions
      final dimensions = _pdfRenderer.getPageDimensions(_currentPage);
      
      if (dimensions != null) {
        // Filter and sort blocks
        final zone = CalibrationZone(
          headerCutoff: _headerCutoff,
          footerCutoff: _footerCutoff,
        );
        
        final text = _pageSorter.process(
          blocks,
          zone,
          dimensions.width * 2, // Scale factor used in rendering
          dimensions.height * 2,
        );
        
        setState(() {
          _extractedText = text;
          _isProcessing = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'OCR failed: $e';
        _isProcessing = false;
      });
    }
  }

  void _proceedToPlayer() {
    if (_extractedText == null || _extractedText!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please run OCR first')),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => PlayerScreen(
          text: _extractedText!,
          title: 'Page ${_currentPage + 1}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Calibrate • Page ${_currentPage + 1}/${_pdfRenderer.pageCount}'),
        actions: [
          if (_extractedText != null)
            IconButton(
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: _proceedToPlayer,
              tooltip: 'Play audio',
            ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildBody() {
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loadPdf,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    return Column(
      children: [
        // PDF page with calibration overlays
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                children: [
                  // PDF page image
                  if (_displayImage != null)
                    Center(
                      child: _buildPageImage(constraints),
                    )
                  else
                    const Center(
                      child: Text('No page image'),
                    ),
                  
                  // Header cutoff zone (draggable)
                  _buildHeaderOverlay(constraints),
                  
                  // Footer cutoff zone (draggable)
                  _buildFooterOverlay(constraints),
                ],
              );
            },
          ),
        ),
        
        // Extracted text preview
        if (_extractedText != null)
          Container(
            height: 120,
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.text_fields,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Extracted Text',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(
                      _extractedText!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildPageImage(BoxConstraints constraints) {
    if (_displayImage == null) return const SizedBox();
    
    // Calculate aspect ratio to fit in constraints
    final pageAspect = _displayImage!.width / _displayImage!.height;
    final constraintAspect = constraints.maxWidth / constraints.maxHeight;
    
    double width, height;
    if (pageAspect > constraintAspect) {
      width = constraints.maxWidth * 0.9;
      height = width / pageAspect;
    } else {
      height = constraints.maxHeight * 0.9;
      width = height * pageAspect;
    }

    return Container(
      width: width,
      height: height,
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
        image: _displayImage,
        width: width,
        height: height,
        fit: BoxFit.contain,
      ),
    );
  }

  Widget _buildHeaderOverlay(BoxConstraints constraints) {
    final height = constraints.maxHeight * _headerCutoff;
    
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: height,
      child: GestureDetector(
        onVerticalDragUpdate: (details) {
          setState(() {
            _headerCutoff = ((_headerCutoff * constraints.maxHeight + details.delta.dy) / constraints.maxHeight)
                .clamp(0.0, _footerCutoff - 0.1);
          });
        },
        child: Container(
          color: AppTheme.calibrationZone,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              height: 24,
              width: double.infinity,
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
    );
  }

  Widget _buildFooterOverlay(BoxConstraints constraints) {
    final top = constraints.maxHeight * _footerCutoff;
    final height = constraints.maxHeight - top;
    
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      height: height,
      child: GestureDetector(
        onVerticalDragUpdate: (details) {
          setState(() {
            _footerCutoff = ((_footerCutoff * constraints.maxHeight + details.delta.dy) / constraints.maxHeight)
                .clamp(_headerCutoff + 0.1, 1.0);
          });
        },
        child: Container(
          color: AppTheme.calibrationZone,
          child: Align(
            alignment: Alignment.topCenter,
            child: Container(
              height: 24,
              width: double.infinity,
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
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor,
          ),
        ),
      ),
      child: SafeArea(
        child: Row(
          children: [
            // Page navigation
            IconButton(
              onPressed: _currentPage > 0
                  ? () {
                      setState(() => _currentPage--);
                      _renderCurrentPage();
                    }
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              onPressed: _currentPage < _pdfRenderer.pageCount - 1
                  ? () {
                      setState(() => _currentPage++);
                      _renderCurrentPage();
                    }
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
            
            const SizedBox(width: 16),
            
            // OCR button
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isProcessing ? null : _runOcr,
                icon: _isProcessing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.document_scanner, size: 18),
                label: Text(_isProcessing ? 'Processing...' : 'Run OCR'),
              ),
            ),
            
            const SizedBox(width: 8),
            
            // Play button
            IconButton.filled(
              onPressed: _extractedText != null ? _proceedToPlayer : null,
              icon: const Icon(Icons.play_arrow_rounded),
              style: IconButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.black,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
