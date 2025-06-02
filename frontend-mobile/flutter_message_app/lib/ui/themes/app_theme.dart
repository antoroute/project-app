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
    onSurface: AppColors.grey[50],
    secondary: AppColors.blue[300],      // fab, boutons d’action
    onSecondary: Colors.white,
    tertiary: AppColors.yellow[400],     // couleur tertiaire
    onTertiary: Colors.white,
    error: AppColors.red[400],
    onError: AppColors.green[400],
    outlineVariant: AppColors.grey[900],
  );

  /// Thème global de l’application
  static final ThemeData theme = ThemeData(
    primarySwatch: AppColors.purple,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: colorScheme.surface,

    // AppBar
    appBarTheme: AppBarTheme(
      backgroundColor: colorScheme.surface,
      foregroundColor: colorScheme.onSecondary,
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
      fillColor: AppColors.grey[700],
      hintStyle: TextStyle(color: colorScheme.onSecondary.withOpacity(0.6)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
    ),

    // Styles de texte
    textTheme: TextTheme(
      displayLarge: TextStyle(color: colorScheme.onSecondary),
      displayMedium: TextStyle(color: colorScheme.onSecondary),
      bodyLarge: TextStyle(color: colorScheme.onSecondary),
      bodyMedium: TextStyle(color: colorScheme.onSecondary),
      labelLarge: TextStyle(color: colorScheme.onSecondary),
      labelMedium: TextStyle(color: colorScheme.onSecondary),
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
