# Matrice de préparation aux stores

Statut : checklist de travail, exigences à revérifier avant soumission
Dernière mise à jour : 2026-08-23

| Sujet | Google Play | Apple App Store | Microsoft Store | macOS |
|---|---|---|---|---|
| Identité | package définitif, compte développeur | bundle ID, équipe/signature | identité package/éditeur | bundle ID, Developer ID/App Store |
| Artefact | AAB signé | archive iOS signée | MSIX signé recommandé | archive signée/notarisée ou App Store |
| Confidentialité | Data safety + politique | App Privacy + politique | politique/permissions | App Privacy si App Store |
| Suppression compte | dans l'app + ressource Web | dans l'app si création de compte | parcours produit | idem distribution choisie |
| Contenu utilisateur | signalement/blocage/contact | signalement/blocage/contact | règles de contenu | idem |
| Tests | piste fermée selon type de compte/règles courantes | TestFlight | flight/package privé | TestFlight ou bêta signée |
| Cryptographie | déclarations locales à vérifier | export compliance à renseigner | marchés visés à vérifier | export compliance/notarisation |
| Notifications | FCM/permission/canaux | APNs/capabilities/permission | stratégie Windows | APNs si utilisé |

## Bloqueurs actuels du dépôt

- Nom commercial non validé et collision probable sur Google Play.
- Android utilise `com.example` et la signature debug pour release.
- Identifiants/capacités Apple issus du template, push non préparé.
- Packaging/signature Windows et intégration notifications non définis.
- macOS ne dispose pas encore des entitlements réseau/release requis et n'est pas validé.
- Suppression de compte, politique, support et site public inexistants.
- Données collectées, fournisseurs et rétentions non finalisés.

## Vérifications officielles avant chaque release

- Google Play policy center : <https://support.google.com/googleplay/android-developer/topic/9858052>
- Google Play suppression de compte : <https://support.google.com/googleplay/android-developer/answer/13327111>
- Apple App Review Guidelines : <https://developer.apple.com/app-store/review/guidelines/>
- Apple account deletion : <https://developer.apple.com/support/offering-account-deletion-in-your-app/>
- Apple privacy details : <https://developer.apple.com/app-store/app-privacy-details/>
- Microsoft Store policies : <https://learn.microsoft.com/windows/apps/publish/store-policies>

Les versions minimales SDK, délais et processus changent. `TC-801` doit relever les exigences effectives avec date et source pour la release candidate.

La distribution de fonctions cryptographiques et la conformité RGPD nécessitent une vérification adaptée aux pays visés, notamment les démarches françaises/ANSSI potentiellement applicables. Ce document n'est pas un avis juridique.
