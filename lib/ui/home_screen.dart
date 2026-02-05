import 'package:flutter/material.dart';

import 'calibration_screen.dart';
import 'player_screen.dart';

/// Home screen - MVP entry point.
/// For the trace bullet MVP, this directly loads the sample PDF.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 48),
              
              // App title
              Text(
                'FreeReads',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  letterSpacing: -1.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Local-only audiobooks',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              
              const Spacer(),
              
              // MVP: Load sample PDF button
              Center(
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
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        Icons.menu_book_rounded,
                        size: 48,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Trace Bullet MVP',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Load sample PDF to test the pipeline',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              
              const Spacer(),
              
              // Action button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _loadSamplePdf,
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                          ),
                        )
                      : const Text('Load Sample PDF'),
                ),
              ),
              
              const SizedBox(height: 16),
              
              // Secondary action - TTS test
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: _testTts,
                  child: Text(
                    'Test TTS Engine',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ),
              
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadSamplePdf() async {
    setState(() => _isLoading = true);
    
    try {
      // Navigate to calibration screen with sample PDF
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => const CalibrationScreen(
              pdfAssetPath: 'assets/sample/The-Mom-Test-en.pdf',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _testTts() async {
    // Navigate to player screen with sample text for TTS testing
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const PlayerScreen(
          text: 'Hello! Welcome to FreeReads. This is a test of the Kokoro text-to-speech engine. '
              'If you can hear this message, the TTS pipeline is working correctly. '
              'FreeReads converts your PDF textbooks into human-quality audio, '
              'all running locally on your device with no cloud dependencies.',
          title: 'TTS Test',
        ),
      ),
    );
  }
}
