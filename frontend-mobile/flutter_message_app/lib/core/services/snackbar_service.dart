import 'package:flutter/material.dart';

class SnackbarService {
  static void show(BuildContext context, String message, {Color? backgroundColor}) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor ?? Colors.redAccent,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  static void showSuccess(BuildContext context, String message) {
    show(context, message, backgroundColor: Colors.green);
  }

  static void showError(BuildContext context, String message) {
    show(context, message, backgroundColor: Colors.redAccent);
  }

  static void showInfo(BuildContext context, String message) {
    show(context, message, backgroundColor: Colors.blueAccent);
  }
}
