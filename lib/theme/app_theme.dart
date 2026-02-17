import 'package:flutter/material.dart';

/// FreeReads dark theme - minimal Spotify/Audible inspired aesthetic
class AppTheme {
  AppTheme._();

  // Color palette
  static const Color _background = Color(0xFF0D0D0D);
  static const Color _surface = Color(0xFF1A1A1A);
  static const Color _surfaceVariant = Color(0xFF242424);
  static const Color _primary = Color(0xFF1DB954); // Spotify green accent
  static const Color _primaryVariant = Color(0xFF1ED760);
  static const Color _onBackground = Color(0xFFE8E8E8);
  static const Color _onSurface = Color(0xFFB3B3B3);
  static const Color _onSurfaceVariant = Color(0xFF6A6A6A);
  static const Color _error = Color(0xFFCF6679);

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _background,
      colorScheme: const ColorScheme.dark(
        surface: _surface,
        primary: _primary,
        secondary: _primaryVariant,
        error: _error,
        onPrimary: _background,
        onSecondary: _background,
        onSurface: _onSurface,
        onError: _background,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: _background,
        foregroundColor: _onBackground,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'SF Pro Display',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: _onBackground,
          letterSpacing: -0.3,
        ),
      ),
      cardTheme: CardThemeData(
        color: _surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: _primary,
          foregroundColor: _background,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 16,
            letterSpacing: 0.5,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: _onBackground,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: _primary,
        inactiveTrackColor: _surfaceVariant,
        thumbColor: _onBackground,
        overlayColor: _primary.withValues(alpha: 0.2),
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          color: _onBackground,
          letterSpacing: -0.5,
        ),
        headlineMedium: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: _onBackground,
          letterSpacing: -0.3,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: _onBackground,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: _onBackground,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          color: _onSurface,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: _onSurface,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: _onSurfaceVariant,
        ),
        labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: _primary,
          letterSpacing: 0.5,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: _surfaceVariant,
        thickness: 1,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: _primary,
        linearTrackColor: _surfaceVariant,
      ),
    );
  }

  // Semantic colors for the app
  static const Color playButton = _primary;
  static const Color calibrationZone = Color(0x40FF4444);
  static const Color calibrationBorder = Color(0xFFFF4444);
  static const Color contentZone = Color(0x4044FF44);
  static const Color contentBorder = Color(0xFF44FF44);
}
