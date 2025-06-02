import 'package:flutter/material.dart';

/// Vos swatches de couleur, pour chaque colonne de la palette
class AppColors {
  // -------------------
  // Grey Swatch
  // -------------------
  static const int _greyPrimaryValue = 0xFF363F56;
  static const MaterialColor grey = MaterialColor(
    _greyPrimaryValue,
    <int, Color>{
      50: Color(0xFFF3F5F9),
      100: Color(0xFFC0C7CE),
      200: Color(0xFF9297A8),
      300: Color(0xFF6E768B),
      400: Color(0xFF515A6F),
      500: Color(_greyPrimaryValue),
      600: Color(0xFF182135),
      700: Color(0xFF182135),
      800: Color(0xFF0F1423),
      900: Color(0xFF0F1423),
    },
  );

  // -------------------
  // Purple Swatch (PRIMARY)
  // -------------------
  static const int _purplePrimaryValue = 0xFF6519B5;
  static const MaterialColor purple = MaterialColor(
    _purplePrimaryValue,
    <int, Color>{
      50: Color(0xFFF1E6FD),
      100: Color(0xFFD7B5F8),
      200: Color(0xFFBC83F5),
      300: Color(0xFFA055EC),
      400: Color(0xFF832CE1),
      500: Color(_purplePrimaryValue),
      600: Color(0xFF4B108D),
      700: Color(0xFF330661),
      800: Color(0xFF1C0031),
      900: Color(0xFF1C0031),
    },
  );

  // -------------------
  // Green Swatch
  // -------------------
  static const int _greenPrimaryValue = 0xFF18B64D;
  static const MaterialColor green = MaterialColor(
    _greenPrimaryValue,
    <int, Color>{
      50: Color(0xFFDFFCEA),
      100: Color(0xFFB2F9CB),
      200: Color(0xFF78EC9F),
      300: Color(0xFF4EE684),
      400: Color(0xFF41CC73),
      500: Color(_greenPrimaryValue),
      600: Color(0xFF0C8D38),
      700: Color(0xFF056123),
      800: Color(0xFF003212),
      900: Color(0xFF003212),
    },
  );

  // -------------------
  // Yellow Swatch
  // -------------------
  static const int _yellowPrimaryValue = 0xFFE39B2F;
  static const MaterialColor yellow = MaterialColor(
    _yellowPrimaryValue,
    <int, Color>{
      50: Color(0xFFF8ECDA),
      100: Color(0xFFF8DEB4),
      200: Color(0xFFF1C47A),
      300: Color(0xFFE8AC4F),
      400: Color(0xFFE39B2F),
      500: Color(_yellowPrimaryValue),
      600: Color(0xFFB5771A),
      700: Color(0xFF8C5A0F),
      800: Color(0xFF653F06),
      900: Color(0xFF342000),
    },
  );

  // -------------------
  // Red Swatch
  // -------------------
  static const int _redPrimaryValue = 0xFFE02C2C;
  static const MaterialColor red = MaterialColor(
    _redPrimaryValue,
    <int, Color>{
      50: Color(0xFFFCE5E6),
      100: Color(0xFFF9B5B5),
      200: Color(0xFFF17B7A),
      300: Color(0xFFEC5556),
      400: Color(0xFFE02C2C),
      500: Color(_redPrimaryValue),
      600: Color(0xFFB61918),
      700: Color(0xFF8B0E0D),
      800: Color(0xFF630706),
      900: Color(0xFF320000),
    },
  );

  // -------------------
  // Blue Swatch
  // -------------------
  static const int _bluePrimaryValue = 0xFF2D5CE1;
  static const MaterialColor blue = MaterialColor(
    _bluePrimaryValue,
    <int, Color>{
      50: Color(0xFFE5EDFD),
      100: Color(0xFFB6C9F9),
      200: Color(0xFF81A0F4),
      300: Color(0xFF547FEC),
      400: Color(0xFF2D5CE1),
      500: Color(_bluePrimaryValue),
      600: Color(0xFF1943B7),
      700: Color(0xFF0F308B),
      800: Color(0xFF052162),
      900: Color(0xFF000F30),
    },
  );
}
