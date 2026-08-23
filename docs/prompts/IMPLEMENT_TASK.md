# Prompt — Implémenter une tâche

Copier le bloc ci-dessous et remplacer les champs entre chevrons. Ne jamais y coller de secret, `.env`, jeton ou donnée de production.

```text
Tu travailles dans le dépôt /root/Projets/Trust-Circle.

Tâche principale : <TC-XXX — titre>
Fiche : docs/tasks/<fichier>.md
Objectif particulier ou contrainte du jour : <optionnel>

Avant d'agir :
1. lis entièrement AGENTS.md, docs/PROJECT_CONTEXT.md et la fiche de tâche ;
2. lis les documents/ADR liés par la fiche et inspecte le code concerné ;
3. vérifie l'état Git et préserve toute modification utilisateur hors périmètre ;
4. reformule brièvement l'objectif, les critères d'acceptation et les invariants de sécurité affectés.

Exécute la tâche de bout en bout dans son périmètre. Ajoute les tests de non-régression, valide le résultat avec les commandes réellement disponibles et mets à jour la documentation/fiche si le comportement ou une décision change. N'invente pas de secret ni d'accès production. Aucune action production sans mon autorisation explicite et un plan sauvegarde/rollback.

Si une décision produit ou architecture indispensable manque et changerait matériellement le résultat, arrête-toi après les vérifications sûres et pose une question précise. Sinon, fais des hypothèses minimales et explicites.

Compte rendu final attendu :
- résultat obtenu ;
- critères d'acceptation satisfaits ou restants ;
- fichiers modifiés ;
- validations exécutées et résultats ;
- validations non exécutées et pourquoi ;
- risques résiduels/migration/rollback ;
- prochaine tâche recommandée.
```

## Variante petite correction

Même pour une petite correction, conserver la fiche et les invariants. Réduire le commentaire, pas les tests pertinents.
