import 'package:flutter/material.dart';

import '../core/tts_engine.dart';

/// Audio player screen for TTS playback.
/// Minimal dark theme inspired by Spotify/Audible.
class PlayerScreen extends StatefulWidget {
  final String text;
  final String title;

  const PlayerScreen({
    super.key,
    required this.text,
    required this.title,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final TtsEngine _ttsEngine = TtsEngine();
  
  bool _isInitialized = false;
  bool _isInitializing = false;
  bool _isPlaying = false;
  String? _initError;
  double _progress = 0.0;
  double _audioDuration = 0.0;
  double _playbackSpeed = 1.0;
  String? _selectedVoice;
  List<String> _availableVoices = [];

  @override
  void initState() {
    super.initState();
    _initializeTts();
  }

  @override
  void dispose() {
    _ttsEngine.dispose();
    super.dispose();
  }

  Future<void> _initializeTts() async {
    if (_isInitializing) return;
    
    setState(() {
      _isInitializing = true;
      _initError = null;
    });
    
    try {
      await _ttsEngine.initialize(
        modelPath: 'assets/models/model.onnx',
        voicesPath: 'assets/models/voices.json',
        isInt8: false,
      );
      
      setState(() {
        _isInitialized = true;
        _isInitializing = false;
        _availableVoices = _ttsEngine.availableVoices;
        if (_availableVoices.isNotEmpty) {
          _selectedVoice = _availableVoices.first;
        }
      });
      
      // Listen to status changes
      _ttsEngine.statusStream.listen((status) {
        if (mounted) {
          setState(() {
            _isPlaying = status == TtsStatus.speaking;
          });
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _initError = e.toString();
        });
      }
    }
  }

  Future<void> _togglePlayback() async {
    if (!_isInitialized) return;
    
    if (_isPlaying) {
      await _ttsEngine.pause();
    } else if (_ttsEngine.status == TtsStatus.paused) {
      await _ttsEngine.resume();
    } else {
      try {
        if (_selectedVoice != null) {
          _ttsEngine.setVoice(_selectedVoice!);
        }
        final duration = await _ttsEngine.speak(widget.text);
        setState(() {
          _audioDuration = duration;
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('TTS Error: $e'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    }
  }

  void _setPlaybackSpeed(double speed) {
    setState(() => _playbackSpeed = speed);
    _ttsEngine.setRate(speed);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // App bar
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
                    'NOW PLAYING',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.more_vert),
                    onPressed: _showVoiceSelector,
                  ),
                ],
              ),
            ),

            const Spacer(flex: 2),

            // Status indicator when initializing
            if (_isInitializing)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    'Loading TTS model...',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              )
            else if (_initError != null)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 64,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Failed to load TTS',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      _initError!,
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _initializeTts,
                    child: const Text('Retry'),
                  ),
                ],
              )
            else
              // Book/chapter art placeholder
              Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 40,
                      offset: const Offset(0, 20),
                    ),
                  ],
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.menu_book_rounded,
                        size: 80,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (_selectedVoice != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Voice: $_selectedVoice',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ),

            const Spacer(),

            // Title and info
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  Text(
                    widget.title,
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${widget.text.split(' ').length} words',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // Progress bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  SliderTheme(
                    data: Theme.of(context).sliderTheme,
                    child: Slider(
                      value: _progress,
                      onChanged: (value) {
                        setState(() => _progress = value);
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(Duration(seconds: (_progress * _audioDuration).toInt())),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Text(
                          _formatDuration(Duration(seconds: _audioDuration.toInt())),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Playback controls
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Speed button
                TextButton(
                  onPressed: _isInitialized ? _showSpeedDialog : null,
                  child: Text(
                    '${_playbackSpeed}x',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                
                const SizedBox(width: 24),
                
                // Skip back
                IconButton(
                  icon: const Icon(Icons.replay_10),
                  iconSize: 36,
                  onPressed: () {},
                ),
                
                const SizedBox(width: 16),
                
                // Play/Pause button
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isInitialized 
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.surface,
                  ),
                  child: IconButton(
                    icon: Icon(
                      _isPlaying ? Icons.pause : Icons.play_arrow,
                      color: _isInitialized ? Colors.black : Colors.grey,
                    ),
                    iconSize: 48,
                    onPressed: _isInitialized ? _togglePlayback : null,
                    padding: const EdgeInsets.all(16),
                  ),
                ),
                
                const SizedBox(width: 16),
                
                // Skip forward
                IconButton(
                  icon: const Icon(Icons.forward_30),
                  iconSize: 36,
                  onPressed: () {},
                ),
                
                const SizedBox(width: 24),
                
                // Stop button
                IconButton(
                  icon: const Icon(Icons.stop),
                  onPressed: _isPlaying ? () => _ttsEngine.stop() : null,
                ),
              ],
            ),

            const Spacer(flex: 2),

            // Text preview
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.text_snippet_outlined,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Text Preview',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.text.length > 200 
                        ? '${widget.text.substring(0, 200)}...' 
                        : widget.text,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _showSpeedDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
              Text(
                'Playback Speed',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              ...[0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map((speed) {
                return ListTile(
                  title: Text('${speed}x'),
                  trailing: _playbackSpeed == speed
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () {
                    _setPlaybackSpeed(speed);
                    Navigator.of(context).pop();
                  },
                );
              }),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
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
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
              Text(
                'Select Voice',
                style: Theme.of(context).textTheme.titleMedium,
              ),
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
                          ? Icon(
                              Icons.check,
                              color: Theme.of(context).colorScheme.primary,
                            )
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
        );
      },
    );
  }
}
