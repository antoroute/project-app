import 'package:local_auth/local_auth.dart';

class BiometricService {
  final LocalAuthentication _auth = LocalAuthentication();

  /// Vérifie si l’appareil supporte et a au moins un capteur biométrique configuré
  Future<bool> canCheckBiometrics() async {
    final deviceSupported = await _auth.isDeviceSupported();
    final canCheck       = await _auth.canCheckBiometrics;
    final available      = await _auth.getAvailableBiometrics();
    return deviceSupported && canCheck && available.isNotEmpty;
  }

  /// Lance la popup biométrique ou code de déverrouillage si configuré
  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Veuillez vous authentifier pour continuer',
        options: const AuthenticationOptions(
          useErrorDialogs: true,
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}