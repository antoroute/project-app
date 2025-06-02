import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

extension DateTimeFormatting on DateTime {
  /// Renvoie "HH:mm"
  String toHm() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// Rend "Aujourd'hui", "Hier" ou "d MMMM yyyy" en français.
  String toChatDateHeader() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dateOnly = DateTime(year, month, day);
    if (dateOnly == today) {
      return "Aujourd'hui";
    } else if (dateOnly == today.subtract(const Duration(days: 1))) {
      return "Hier";
    } else {
      // e.g. "15 mars 2025"
      return DateFormat("d MMMM yyyy", "fr_FR").format(this);
    }
  }
}


extension ContextDimensions on BuildContext {
  /// Taille de l’écran
  Size get screenSize => MediaQuery.of(this).size;

  /// Largeur max pour une bulle (~70% de l’écran)
  double get maxBubbleWidth => screenSize.width * 0.7;
}
