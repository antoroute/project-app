# Documentation Trust Circle

Cette documentation est la source de contexte pour le produit, l'architecture, la sécurité, l'exploitation et le travail assisté par IA. Le README racine décrit l'intention historique du projet mais n'est plus la référence technique.

## Point d'entrée

- [Contexte condensé](PROJECT_CONTEXT.md)
- [Audit initial](audit/AUDIT-2026-08-23.md)
- [Roadmap](roadmap/ROADMAP.md)
- [Tâches](tasks/README.md)
- [Règles pour assistants](../AGENTS.md)

## Références par domaine

- Produit : [vision](product/PRODUCT.md), [périmètre V1](product/V1_SCOPE.md), [décisions V1](product/V1_DECISIONS.md), [décision de nom](product/NAME_DECISION.md)
- Architecture : [système](architecture/SYSTEM.md), [modèle de données](architecture/DATA_MODEL.md), [compatibilité plateformes](architecture/PLATFORM_COMPATIBILITY.md)
- Sécurité : [menaces](security/THREAT_MODEL.md), [invariants](security/SECURITY_INVARIANTS.md), [protocole cryptographique](security/CRYPTO_PROTOCOL.md)
- Décisions : [registre ADR](adr/README.md)
- API : [contrats](api/README.md)
- Exploitation : [inventaire historique](operations/PRODUCTION_INVENTORY.md), [inventaire staging](operations/STAGING_INVENTORY.md), [archive du code initial](operations/CODE_ARCHIVE.md), [environnements](operations/ENVIRONMENTS.md), [déploiement](operations/DEPLOYMENT.md), [sauvegarde/restauration](operations/BACKUP_RESTORE.md), [incidents](operations/INCIDENT_RESPONSE.md)
- Qualité : [stratégie de test](quality/TEST_STRATEGY.md), [checklist de release](quality/RELEASE_CHECKLIST.md)
- Conformité : [cartographie des données](compliance/DATA_MAP.md), [matrice stores](compliance/STORE_MATRIX.md)
- Prompts : [implémentation](prompts/IMPLEMENT_TASK.md), [revue](prompts/REVIEW_TASK.md), [diagnostic](prompts/DEBUG_TASK.md)

## Entretien

Chaque document indique son statut et sa date de mise à jour. Toute tâche qui rend un document inexact doit le corriger dans la même livraison. Les exigences des stores, SDK et réglementations sont temporelles : elles doivent être revérifiées avant chaque soumission.
