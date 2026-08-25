import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/services/account_device_trust_service.dart';
import 'package:provider/provider.dart';

import 'home_screen.dart';

class DeviceTrustGateScreen extends StatelessWidget {
  const DeviceTrustGateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return switch (auth.deviceTrustState) {
      DeviceTrustState.active => const HomeScreen(),
      DeviceTrustState.pending => const _PendingDeviceScreen(),
      DeviceTrustState.revoked => const _RevokedDeviceScreen(),
      DeviceTrustState.requiresEnrollment => const _EnrollmentScreen(),
      DeviceTrustState.error => const _TrustErrorScreen(),
      DeviceTrustState.checking => const _CheckingDeviceScreen(),
      DeviceTrustState.unauthenticated => const _CheckingDeviceScreen(),
    };
  }
}

class _CheckingDeviceScreen extends StatelessWidget {
  const _CheckingDeviceScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Vérification de cet appareil…'),
        ],
      ),
    ),
  );
}

class _PendingDeviceScreen extends StatefulWidget {
  const _PendingDeviceScreen();

  @override
  State<_PendingDeviceScreen> createState() => _PendingDeviceScreenState();
}

class _PendingDeviceScreenState extends State<_PendingDeviceScreen> {
  Timer? _timer;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 8), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing || !mounted) return;
    setState(() => _refreshing = true);
    try {
      await context.read<AuthProvider>().refreshDeviceTrust(
        showChecking: false,
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final device = auth.currentAccountDevice;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Appareil en attente'),
        actions: <Widget>[
          IconButton(
            onPressed: auth.logout,
            icon: const Icon(Icons.logout),
            tooltip: 'Se déconnecter',
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.phonelink_lock, size: 72),
              const SizedBox(height: 20),
              const Text(
                'Validez ce nouvel appareil depuis un appareil déjà autorisé.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              if (device != null) ...<Widget>[
                Text('${device.deviceName} · ${device.platform}'),
                const SizedBox(height: 8),
                SelectableText('Empreinte : ${device.fingerprint}'),
              ],
              const SizedBox(height: 16),
              const Text(
                'Aucun ancien message ni secret n’est transféré. Après validation, seuls les futurs messages seront reçus.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _refreshing ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Vérifier maintenant'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RevokedDeviceScreen extends StatelessWidget {
  const _RevokedDeviceScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Appareil révoqué')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.gpp_bad, size: 72),
            const SizedBox(height: 20),
            const Text(
              'Cet appareil n’est plus autorisé à accéder aux conversations.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: context.read<AuthProvider>().logout,
              child: const Text('Se déconnecter'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _EnrollmentScreen extends StatefulWidget {
  const _EnrollmentScreen();

  @override
  State<_EnrollmentScreen> createState() => _EnrollmentScreenState();
}

class _EnrollmentScreenState extends State<_EnrollmentScreen> {
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _enroll() async {
    if (_password.text.isEmpty) return;
    setState(() => _loading = true);
    await context.read<AuthProvider>().enrollCurrentDevice(_password.text);
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Autoriser cet appareil'),
      actions: <Widget>[
        IconButton(
          onPressed: context.read<AuthProvider>().logout,
          icon: const Icon(Icons.logout),
        ),
      ],
    ),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'Confirmez votre mot de passe pour créer l’identité sécurisée de cette installation.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _password,
              obscureText: _obscure,
              autofillHints: const <String>[AutofillHints.password],
              decoration: InputDecoration(
                labelText: 'Mot de passe',
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                ),
              ),
              onSubmitted: (_) => _loading ? null : _enroll(),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _loading ? null : _enroll,
              child:
                  _loading
                      ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Text('Continuer'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _TrustErrorScreen extends StatelessWidget {
  const _TrustErrorScreen();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Vérification impossible')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.security, size: 72),
              const SizedBox(height: 20),
              const Text(
                'CircleHaven ne peut pas confirmer l’identité sécurisée de cet appareil. Aucune conversation n’a été ouverte.',
                textAlign: TextAlign.center,
              ),
              if (auth.deviceTrustError != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  'Référence : ${auth.deviceTrustError}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: auth.refreshDeviceTrust,
                icon: const Icon(Icons.refresh),
                label: const Text('Réessayer'),
              ),
              TextButton(
                onPressed: auth.logout,
                child: const Text('Se déconnecter'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
