import 'package:flutter/material.dart';

/// Service pour afficher des SnackBars globalement.
class SnackbarService {
  /// Affiche une erreur en rouge.
  static void showError(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Affiche un message de succès en vert.
  static void showSuccess(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Affiche un message d’information en bleu.
  static void showInfo(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.blueAccent,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Erreur spécifique en cas de rate limit (429).
  static void showRateLimitError(BuildContext context) {
    showError(context, 'Trop de requêtes, veuillez réessayer dans un instant.');
  }
}
