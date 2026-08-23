# Registre de compatibilité des plateformes

Statut : baseline technique V1, preuves de build partielles
Dernière vérification : 2026-08-24
Tâche : `TC-006`

Ce registre fixe les cibles de conception et distingue une compatibilité déclarée d'une compatibilité réellement testée. Une ligne « compatible » ne devient une preuve de publication qu'après build, installation et test sur la matrice définie dans `docs/quality/TEST_STRATEGY.md`.

## Matrice V1

| Cible | Minimum publié | Architectures | Niveau de support | Cible de test haute |
|---|---|---|---|---|
| Android | Android 9, API 28 | `arm64-v8a`, `armeabi-v7a`; `x86_64` pour émulateur | obligatoire | Android 16, API 36 |
| iPhone/iPad | iOS/iPadOS 15 | arm64 | obligatoire | iOS/iPadOS 26 |
| Windows | Windows 11 25H2 | x64 | obligatoire | dernière Windows 11 stable supportée |
| macOS | macOS 14 Sonoma | arm64 Apple Silicon | souhaité, non bloquant | dernière macOS stable supportée |
| Site public | navigateurs evergreen | sans objet | obligatoire, aucun secret/message | deux dernières versions Chrome, Edge et Firefox ; Safari 16.4+ |

Règles transverses :

- un système doit recevoir ses correctifs éditeur ; l'application ne promet pas de support sur un OS arrivé en fin de maintenance ;
- `targetSdk` Android est 36 au minimum pour les soumissions après le 31 août 2026, avec `compileSdk` 36 ou supérieur ;
- les soumissions iOS utilisent Xcode 26 ou supérieur et le SDK iOS 26 ou supérieur ; le deployment target reste iOS 15 ;
- le paquet Windows V1 est un MSIX x64 distribué par le Microsoft Store ; aucun installateur non signé n'est proposé ;
- macOS Intel n'est pas annoncé : Flutter organise sa dépréciation et cette architecture doublerait une partie des tests pour une cible non bloquante ;
- le site public reste lisible et permet le téléchargement, le support et la suppression de compte sans JavaScript indispensable. Il ne stocke aucune clé de messagerie.

## Justification et utilisateurs exclus

### Android

API 28 fournit le dialogue biométrique système et permet StrongBox lorsqu'il existe. Le plancher Flutter courant est API 24, mais prendre API 28 évite de promettre une nouvelle application de sécurité sur Android 7/8. La part exacte exclue ne peut pas être déduite du dépôt ; elle devra être mesurée dans Play Console avant la bêta publique.

### Apple mobile

iOS 15 est à la fois le plancher Flutter courant et le deployment target minimum accepté par Xcode 26.6. Apple indique que 79 % des iPhone actifs sur l'App Store utilisaient déjà iOS 26 au 7 juin 2026, ce qui rend le plancher 15 conservateur sans imposer le dernier OS.

### Windows

Windows 10 est compatible Flutter mais son support général s'est terminé le 14 octobre 2025. La V1 cible donc Windows 11 25H2, maintenu pour les éditions grand public jusqu'au 12 octobre 2027. Cela exclut volontairement Windows 10 et les installations Windows 11 non maintenues. Ce choix réduit le risque local et la matrice de support, au prix de portée desktop.

### macOS

macOS est non bloquant pour la V1. Le choix macOS 14+ et Apple Silicon réduit les coûts de build, notarisation et tests. Une demande de support Intel ou macOS 12/13 exige des preuves de plugins et une réouverture d'ADR-0001.

## Toolchain à figer dans TC-707

| Élément | Baseline |
|---|---|
| Flutter | 3.44.7 stable, version exacte dans la CI |
| Dart | version fournie par Flutter 3.44.7 ; contrainte projet à réaligner |
| Android | API 36, JDK 17, Gradle/AGP compatibles avec le template Flutter retenu |
| Apple | Xcode 26.6 ou version 26 supportée plus récente ; SDK iOS/macOS correspondant |
| Windows | runner Windows 2025 x64, Visual Studio Desktop C++ accepté par `flutter doctor` |

Les numéros ne sont pas des dépendances flottantes : toute montée de Flutter/Xcode/SDK passe d'abord par la matrice de tests. Les exigences stores sont revérifiées dans `TC-801` immédiatement avant publication.

## Compatibilité des dépendances critiques verrouillées

| Dépendance actuelle | Android | iOS | Windows | macOS | Décision / preuve restante |
|---|---|---|---|---|---|
| `flutter_secure_storage 9.2.4` | oui | oui | oui | oui | provisoirement conservé ; tester création, lecture, révocation, isolation de compte et comportement après désinstallation dans `TC-306`/`TC-703`/`TC-706` |
| `local_auth 2.3.0` | oui | oui | oui | oui | biométrie uniquement comme déverrouillage local optionnel ; tester absence de capteur, PIN et annulation dans `TC-306` |
| `sqflite 2.4.2` | oui | oui | non | oui | incompatible Windows et base actuelle non chiffrée ; remplacer derrière une abstraction réellement chiffrée dans `TC-306`, `TC-602` et `TC-703` |
| `path_provider 2.1.5` | oui | oui | oui | oui | conserver derrière l'abstraction de stockage ; vérifier permissions et chemins de mise à jour |
| `mobile_scanner 3.5.7` | oui | oui | non | oui | ne jamais charger sur Windows ; invitation par lien/code dans `TC-704`; montée de version séparée |
| `flutter_local_notifications 19.4.2` | oui | oui | oui | oui | le code actuel n'initialise que Android/iOS ; adapter Windows/macOS et tester MSIX/entitlements dans `TC-509`, `TC-705`, `TC-706` |
| `connectivity_plus 6.1.5` | oui | oui | oui | oui | son état réseau n'est jamais une preuve d'accès Internet ; tester reprise réelle dans `TC-505`/`TC-508` |
| `socket_io_client 2.0.3+1` | oui | oui | oui | oui | le client déclare Socket.IO serveur jusqu'à 4.6 alors que le backend utilise 4.7.5 ; mettre à niveau ou prouver le contrat dans `TC-505` |
| `cryptography 2.7.0` et primitives Dart | oui | oui | oui | oui | compatibilité source seulement ; choix, stockage de clés et vecteurs relèvent de `TC-306` à `TC-312` |

Constats directs sur le dépôt :

- iOS est encore configuré avec un deployment target 12.0 et macOS avec 10.14 ;
- Android reprend `minSdk` et `targetSdk` implicitement depuis Flutter au lieu d'enregistrer la décision produit ;
- le stockage de messages annonce un chiffrement mais ouvre une base SQLite en clair et génère une clé prédictible qui n'est pas utilisée ;
- le registrant Windows ne contient ni `sqflite`, ni scanner ;
- les notifications sont initialisées sans paramètres Windows/macOS ;
- `.env` est un asset obligatoire et le client contient encore un secret partagé de repli ; les builds ne doivent pas être artificiellement débloqués avec un faux secret.

Ces écarts sont des bloqueurs de validation, pas des raisons d'abaisser la matrice.

## Prototypes et preuves attendues

Chaque cible obligatoire doit exécuter le même probe avant clôture de TC-006 :

1. build debug/release sans secret partagé embarqué ;
2. création d'une clé aléatoire par CSPRNG, stockage OS, lecture puis effacement ;
3. ouverture d'une base réellement chiffrée, écriture, redémarrage, lecture, puis preuve que SQLite standard ne lit pas le fichier ;
4. connexion HTTPS et Socket.IO au staging restreint, coupure/reprise et absence de doublon ;
5. déverrouillage local disponible/indisponible/annulé ;
6. notification générique sans contenu ;
7. invitation par deep link et code, avec scanner seulement sur plateformes compatibles ;
8. passage premier plan/arrière-plan, verrouillage et révocation de session.

## Matériel accessible au propriétaire au 2026-08-24

| Plateforme | Disponibilité actuelle | Usage prévu | Information encore requise |
|---|---|---|---|
| Android | appareil physique disponible | développement et parcours manuels fréquents | modèle, version Android, niveau API et architecture |
| Windows | PC Windows 11 disponible | développement, installation/MSIX et parcours manuels fréquents | édition, version `winver`, numéro de build et architecture |
| iOS/iPadOS | aucun appareil actuellement | CI et simulateur d'abord ; accès ponctuel à organiser avant bêta | modèle et OS du futur appareil de test |
| macOS | aucun Mac actuellement | CI seulement tant que la cible reste non annoncée | Mac Apple Silicon macOS 14+ avant toute annonce |

Un simulateur valide le build et une partie du cycle de vie, mais ne remplace pas un appareil pour Keychain/Secure Enclave, biométrie, APNs, veille et consommation réseau. Un iPhone physique est donc une condition de la bêta iOS. Le Mac physique n'est une condition que si macOS est finalement annoncé.

## Sources officielles vérifiées le 2026-08-23

- [Flutter — plateformes de déploiement supportées](https://docs.flutter.dev/reference/supported-platforms)
- [Google Play — exigence target API](https://developer.android.com/google/play/requirements/target-sdk)
- [Android — BiometricPrompt](https://developer.android.com/reference/android/hardware/biometrics/BiometricPrompt)
- [Android — Android Keystore et StrongBox](https://developer.android.com/privacy-and-security/keystore)
- [Apple — exigences de soumission](https://developer.apple.com/app-store/submitting/)
- [Apple — SDK et systèmes requis par Xcode](https://developer.apple.com/xcode/system-requirements)
- [Apple — adoption iOS/iPadOS](https://developer.apple.com/support/app-store/)
- [Microsoft — état des versions Windows 11](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information)
- [Microsoft — exigences des paquets MSIX](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-package-requirements)
- [GitHub — runners hébergés](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- Dépendances verrouillées : [flutter_secure_storage 9.2.4](https://pub.dev/packages/flutter_secure_storage/versions/9.2.4), [local_auth 2.3.0](https://pub.dev/packages/local_auth/versions/2.3.0), [sqflite 2.4.2](https://pub.dev/packages/sqflite/versions/2.4.2), [path_provider 2.1.5](https://pub.dev/packages/path_provider/versions/2.1.5), [mobile_scanner 3.5.7](https://pub.dev/packages/mobile_scanner/versions/3.5.7), [flutter_local_notifications 19.4.2](https://pub.dev/packages/flutter_local_notifications/versions/19.4.2), [connectivity_plus 6.1.5](https://pub.dev/packages/connectivity_plus/versions/6.1.5), [socket_io_client 2.0.3+1](https://pub.dev/packages/socket_io_client/versions/2.0.3%2B1) et [cryptography 2.7.0](https://pub.dev/packages/cryptography/versions/2.7.0).
