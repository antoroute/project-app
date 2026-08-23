# Prompt — Revue de code ou de tâche

```text
Tu travailles dans /root/Projets/Trust-Circle comme relecteur, en lecture seule sauf demande explicite de correction.

Périmètre de revue : <commit, diff, branche ou TC-XXX>
Intention attendue : <résumé>

Lis AGENTS.md, docs/PROJECT_CONTEXT.md, la fiche de tâche, les invariants de sécurité et ADR pertinents. Inspecte le diff ainsi que le contexte nécessaire autour des changements. Ne suppose pas que compilation = correction.

Cherche en priorité :
- violation d'identité/JWT/ACL ou concurrence transactionnelle ;
- fuite de secret, contenu, clé ou métadonnée excessive ;
- faille crypto, sérialisation ambiguë, rejeu, ordre vérification/affichage ;
- perte/duplication offline, idempotence et migration/rollback ;
- régression Android/iOS/Windows/macOS ;
- contrat/API/documentation devenus incohérents ;
- tests absents, trop faibles ou ne couvrant pas le défaut initial.

Valide chaque constat avec une preuve dans le code. Classe les constats Critique, Haut, Moyen ou Faible et donne fichier + ligne, scénario concret, impact et correctif recommandé. N'édite rien sauf si je demande explicitement de corriger.

Si aucun défaut n'est trouvé, dis-le clairement mais liste les risques résiduels et validations non exécutées. Termine par une conclusion Go / Go avec réserves / No-Go par rapport aux critères de la fiche.
```
