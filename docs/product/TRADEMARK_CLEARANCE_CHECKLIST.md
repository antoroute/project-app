# Checklist de validation de marque CircleHaven

Statut : action externe requise avant réservation coordonnée et publication
Dernière mise à jour : 2026-08-24
Tâche : `TC-001`

## But et limite

Cette checklist transforme la recherche de marque restante en contrôle reproductible et archivable. Elle ne constitue pas un avis juridique et une absence de résultat ne garantit pas la disponibilité d'un signe.

Les interfaces officielles ne permettent pas ici de produire automatiquement une recherche de similarité complète et auditable : l'API INPI et les API EUIPO demandent un compte, tandis que WIPO recommande de compléter sa base mondiale par les registres nationaux et régionaux. Le contrôle doit donc être effectué manuellement dans les interfaces officielles ou confié à un conseil en propriété industrielle.

## Périmètre à contrôler

- Territoires de lancement : France et Union européenne.
- Marques internationales : enregistrements visant la France ou l'Union européenne.
- Classes de Nice indicatives : 9, 38 et 42 ; classe 45 à confirmer selon les services réellement commercialisés.
- Signe principal : `CircleHaven`.
- Titre public : `CircleHaven — Trust Circle`.

Requêtes minimales, en recherche exacte puis par similarité :

1. `CircleHaven`
2. `Circle Haven`
3. `Circle-Haven`
4. `Circle Heaven`
5. `CircleHaven Trust Circle`
6. `Trust Circle`

Examiner également les variantes visuelles ou phonétiques proposées par chaque moteur, les titulaires liés au logiciel, à la messagerie, aux réseaux sociaux, à la cybersécurité et aux services en ligne.

## Registres officiels

- [INPI Data — recherche avancée de marques](https://data.inpi.fr/recherche_avancee/marques) : marques françaises, de l'Union européenne actives et internationales disponibles dans le fonds INPI.
- [EUIPO — Search IP](https://www.euipo.europa.eu/en/search-ip) et [TMview](https://www.tmdn.org/tmview/) : marques de l'Union européenne et offices participants.
- [WIPO — Global Brand Database](https://www.wipo.int/en/web/global-brand-database) : marques internationales et collections participantes ; compléter impérativement avec INPI/EUIPO.

## Journal de résultats

Créer une ligne par résultat exact ou similaire pertinent. Ne jamais versionner d'identifiant de compte, de coordonnées privées ni de document confidentiel.

| Champ | Valeur à enregistrer |
|---|---|
| Date et heure | fuseau Europe/Paris |
| Base | INPI, EUIPO/TMview ou WIPO |
| Requête et filtres | signe, territoire, classes, statut |
| Résultat | nom, numéro public, statut, titulaire public |
| Produits/services pertinents | résumé factuel, sans longue copie |
| Similarité | exacte, visuelle, phonétique ou conceptuelle |
| Risque initial | faible, à examiner, élevé |
| Preuve | lien public et export/capture sans donnée privée |
| Décision | poursuivre, demander conseil, changer de nom |

Les exports ou captures contenant des informations de compte restent hors Git. Le dépôt ne reçoit qu'une synthèse et les liens publics.

## Porte de décision

Avant tout investissement significatif dans la marque, le propriétaire choisit et documente l'une de ces voies :

- recherche d'antériorités et avis d'un conseil en propriété industrielle ; ou
- acceptation explicite du risque résiduel après recherches officielles manuelles complètes.

La réservation de `circlehaven.app`, `circlehaven.fr`, des comptes stores et des principaux identifiants sociaux est ensuite effectuée de façon coordonnée, avec renouvellement et récupération de compte documentés hors Git.

Une fois cette porte franchie, mettre à jour `NAME_DECISION.md`, `ADR-0004-nom-produit.md` et `TC-001`, puis autoriser les tâches de remplacement des package/bundle IDs et des anciennes URLs.
