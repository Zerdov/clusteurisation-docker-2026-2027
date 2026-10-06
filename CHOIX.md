# Choix d'architecture Nebula

## Cluster

- **1 manager + 2 workers**, sur les trois VM de l'annexe D.
- Le manager héberge l'edge (Traefik, seul port publié) et le plan de contrôle.
- Le quorum Raft d'un seul manager est de 1 : perdre ce nœud arrête la gestion du cluster, mais les services déjà lancés continuent de tourner.
- Trois managers tolèrent la perte d'un nœud, mais demandent trois VM de gestion et ne sont pas possibles avec trois VM seulement.

## Placement

| Machine | Rôle | Services |
|---|---|---|
| manager | gestion, point d'entrée | edge |
| worker1 | données | db (PostgreSQL), bus (RabbitMQ) |
| worker2 | applicatif | comptes, publications, worker-medias, cache (Redis) |

- La base et le bus sont contraints sur `worker1` par label (`node.labels`), pour que leur volume reste sur une machine.
- Les services sans état peuvent être répliqués librement sur `worker2` et, si besoin, sur le manager.

## Réseaux

- `public` : relie l'edge aux services qu'il route.
- `internal` : échanges entre services, base et bus.
- La base et le bus ne sont joignables que par `internal`.

## Exposition

- Un seul port publié sur le cluster : l'edge. **Écart assumé** : le tableau de bord Traefik est aussi publié sur le port 8088 (mode `host`, manager uniquement). Il est protégé par basicauth. Le cahier demande un accès « restreint » : la restriction par pare-feu (ufw sur le manager, accès limité au poste d'admin) reste à appliquer sur les VM.
- Les services déclarent leur routage dans leurs propres labels. Ajouter un service ne demande aucune modification de l'edge.

## Secrets et configuration

- Mots de passe de la base et du bus en secrets Swarm, montés en fichiers.
- Les images officielles lisent `*_FILE` ; les services applicatifs aussi.
- Aucun secret dans le dépôt : le dossier `secrets/` est ignoré par Git.

## Versions

- Images taguées par version et empreinte de commit, jamais `latest`.
- Le registry tourne hors du cluster, sur une machine à part.

## Limites

- Chaque service déclare une limite mémoire (`deploy.resources.limits`).
- La base et le bus ont les plus gros budgets, cohérents avec les RAM de l'annexe D.

## Non décidé

- Procédure de sauvegarde et de restauration de la base.
- Stratégie de mise à jour progressive (`update_config`) et de retour arrière.
- Choix exact du registry.
