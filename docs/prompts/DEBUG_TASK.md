# Prompt — Diagnostiquer un défaut

```text
Tu travailles dans /root/Projets/Trust-Circle. Commence en diagnostic ; ne modifie pas le code tant que la cause n'est pas étayée, sauf si je demande explicitement diagnostic + correction.

Symptôme : <ce qui se passe>
Comportement attendu : <ce qui devrait se passer>
Plateforme/environnement : <local, staging, Android, iOS, Windows, macOS>
Version/commit : <si connu>
Étapes de reproduction : <étapes minimales>
Erreur assainie : <sans secret ni donnée personnelle>
Première version touchée : <si connue>

Lis AGENTS.md, docs/PROJECT_CONTEXT.md et les documents liés au domaine. Vérifie l'état Git. Reproduis avec la méthode la plus petite et non destructive. Construis des hypothèses classées, puis cherche des preuves pour les confirmer ou les éliminer. Distingue cause racine, facteurs aggravants et symptômes.

Pour auth/crypto/synchronisation, crée une reproduction avec comptes et données synthétiques. Ne demande ni `.env`, jeton, clé, dump ou logs bruts de production. Si un constat VM est nécessaire, prépare uniquement des commandes de lecture et une méthode d'assainissement ; attends mon autorisation avant toute action externe.

Résultat attendu :
- cause racine prouvée ou meilleur diagnostic avec niveau de confiance ;
- chemin d'exécution et fichiers/lignes concernés ;
- reproduction minimale ;
- impact et versions/plateformes affectées ;
- correctif minimal proposé (ou implémenté si demandé) ;
- test de non-régression ;
- validations et inconnues restantes.
```
