import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppTheme {
  /// Palette de couleurs centrale, on part du swatch violet comme primary
  static final ColorScheme colorScheme = ColorScheme.fromSwatch(
    primarySwatch: AppColors.purple,
    backgroundColor: AppColors.grey[900],
    cardColor: AppColors.grey[700],
    accentColor: AppColors.green[400],   // “accent” / secondary
    brightness: Brightness.dark,
  ).copyWith(
    surface: AppColors.grey[800],
    onSurface: AppColors.grey[100]!,
    secondary: AppColors.blue[300],      // fab, boutons d’action
    onSecondary: Colors.white,
    tertiary: AppColors.yellow[400],     // couleur tertiaire
    onTertiary: Colors.white,
    error: AppColors.red[400],
    onError: Colors.white,
  );

  /// Thème global de l’application
  static final ThemeData theme = ThemeData(
    primarySwatch: AppColors.purple,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: colorScheme.surface,

    // AppBar
    appBarTheme: AppBarTheme(
      backgroundColor: colorScheme.surface,
      foregroundColor: colorScheme.onSurface,
      elevation: 1,
    ),

    // Boutons sur surfaces
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
    ),

    // Champs de saisie
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.onSurface,
      hintStyle: TextStyle(color: colorScheme.onSurface.withOpacity(0.6)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
    ),

    // Styles de texte
    textTheme: TextTheme(
      displayLarge: TextStyle(color: colorScheme.onSurface),
      displayMedium: TextStyle(color: colorScheme.onSurface),
      bodyLarge: TextStyle(color: colorScheme.onSurface),
      bodyMedium: TextStyle(color: colorScheme.onSurface),
      labelLarge: TextStyle(color: colorScheme.onSurface),
      labelMedium: TextStyle(color: colorScheme.onSurface),
    ),

    // Icônes
    iconTheme: IconThemeData(color: colorScheme.onSurface),

    // FAB
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: colorScheme.secondary,
      foregroundColor: colorScheme.onSecondary,
    ),
  );
}
