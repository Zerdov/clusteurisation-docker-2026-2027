# Démonstration de soutenance

Ce document donne l'ordre de démonstration des dix scénarios du cahier des charges, avec la commande à lancer et le résultat attendu. Les scénarios 6 à 10 sont automatisés ; les scénarios 1 à 5 se montrent à la main, avec les commandes ci-dessous.

Toutes les commandes se lancent depuis le poste de travail, dans le dépôt, sauf indication contraire.

## 0. Avant la soutenance

```bash
make vm-tunnel                                          # API sur localhost:18080, dashboard sur 18088
curl -s -m 5 http://localhost:18080/api/health; echo    # attendu : {"service":"comptes",...}
ssh manager@10.96.238.1 'docker node ls && docker service ls'
```

Vérifier :
- trois nœuds `Ready`, dont un `Leader` ;
- les sept services à leur nombre de réplicas ;
- le mot de passe du dashboard disponible dans `secrets/dashboard_password.txt`.

Retirer le service `statut` s'il est déjà déployé, pour que le scénario 10 parte de zéro :

```bash
ssh manager@10.96.238.1 'docker stack rm statut'
```

## 1. Trois machines, un seul cluster

```bash
ssh manager@10.96.238.1 'docker node ls'
```

Attendu : trois lignes, toutes `Ready`, `Active`, avec un `Leader` sur le manager.

Montrer aussi la version des moteurs : `docker node ls` affiche la colonne `ENGINE VERSION`.

## 2. Arrêt puis redémarrage complet

Avant d'arrêter, créer un compte témoin et noter son `id` dans la réponse :

```bash
curl -s -m 5 -X POST http://localhost:18080/api/comptes -H 'content-type: application/json' -d '{"pseudo":"soutenance-'"$RANDOM"'"}'; echo
```

Attendu : `{"id":...,"pseudo":"soutenance-...","cree_le":...}`. C'est cet `id` qui sert à la relecture après redémarrage, plus bas.

Arrêter les VM, dans l'ordre inverse du démarrage : workers d'abord, manager ensuite.

```bash
ssh manager@10.96.238.2 'sudo poweroff'   # worker1
ssh manager@10.96.238.3 'sudo poweroff'   # worker2
ssh manager@10.96.238.1 'sudo poweroff'   # manager, en dernier
```

Ou depuis Proxmox : arrêt de chaque VM.

Redémarrer dans l'ordre : manager, puis workers. Attendre une minute, puis vérifier :

```bash
ssh manager@10.96.238.1 'docker node ls && docker service ls'
curl -s -m 5 http://localhost:18080/api/health; echo
```

Attendu : les nœuds reviennent `Ready`, les services reviennent à leur nombre de réplicas (le registry compris), et l'API répond. Vérifier aussi qu'une donnée existante est toujours là : créer un compte avant l'arrêt, puis le relire après.

```bash
curl -s -m 5 http://localhost:18080/api/comptes/<id>; echo
```

## 3. Déploiement depuis zéro

Ce scénario se démontre en suivant le guide `docs/vm-installation.md`, étape par étape. Pour le déploiement applicatif, la commande est :

```bash
SSH_USER=manager make vm-up
```

Attendu : les étapes 1 à 9 de `scripts/vm-up.sh` s'enchaînent, avec le test final `{"id":...,"pseudo":"vm-..."}`.

Ne pas faire ce scénario en direct pendant la soutenance : il prend du temps. Le montrer à partir des notes de `docs/vm-installation.md`, ou le réaliser avant, sur des VM propres.

## 4. Contrôle de l'exposition

Un seul port répond depuis l'extérieur, la base et le bus ne répondent pas.

```bash
ssh manager@10.96.238.1 'docker service inspect edge_traefik --format "{{json .Endpoint.Ports}}"'
ssh manager@10.96.238.1 'for s in nebula_db nebula_bus nebula_cache; do echo "$s : $(docker service inspect $s --format "{{json .Endpoint.Ports}}")"; done'
```

Attendu pour la base, le bus et le cache : `[]`, aucun port publié. Pour l'edge, le port 80 est publié.

**Point à annoncer franchement** : deux autres ports sont publiés, ce qui contredit l'exigence « un seul port publié » :
- le **8088**, pour le dashboard Traefik (protégé par mot de passe, documenté dans `CHOIX.md`) ;
- le **5000**, pour le registry, nécessaire aux démons des workers (documenté dans `CHOIX.md`).

## 5. Placement cohérent

La base doit être sur le worker étiqueté `tier=data`.

```bash
ssh manager@10.96.238.1 'docker service ps nebula_db --filter desired-state=running --format "{{.Name}} {{.Node}} {{.CurrentState}}"'
ssh manager@10.96.238.1 'docker service inspect nebula_db --format "{{json .Spec.TaskTemplate.Placement}}"'
ssh manager@10.96.238.1 'docker node inspect clusteurisation-docker-worker1 --format "{{.Spec.Labels}}"'
awk '/^  db:/,/^  cache:/' swarm/stack.nebula.todo.yml | grep constraints
```

Attendu :
- la base tourne sur `clusteurisation-docker-worker1` (`Running`) ;
- Swarm affiche la contrainte `{"Constraints":["node.labels.tier == data"]}` pour `nebula_db`, c'est-à-dire la configuration déployée, pas seulement le fichier ;
- ce nœud porte `tier=data` ;
- le bloc `db` du fichier de stack contient la même contrainte (une seule ligne `constraints`).

Montrer aussi les services sans état : `nebula_comptes` tourne sur les nœuds qui ne sont pas `tier=data` (contrainte `node.labels.tier != data`), donc sur worker2 et, si Swarm le place là, sur le manager.

**Point à annoncer franchement** : la contrainte fixe la base sur worker1, mais elle ne déplace pas les données. Le volume `db_data` reste local à worker1. Si ce nœud tombe, Swarm peut relancer la base ailleurs, mais sans son volume, donc sans les données. La réponse est la sauvegarde du scénario 9, pas la contrainte seule.

## 6. Montée en charge d'un service sans état

```bash
TARGET=vm make scale-out
```

Attendu : `TEST REUSSI`, avec 4 instances de `nebula_comptes` et une répartition d'environ 75 requêtes par instance sur 300.

## 7. Mise à jour sans interruption perceptible

```bash
TARGET=vm make rolling-update
```

Attendu : `TEST REUSSI`, avec 0 requête en échec sur environ 350, et les deux versions servies pendant la bascule.

## 8. Version défectueuse puis retour arrière

```bash
TARGET=vm make rollback
```

Attendu : `TEST REUSSI`. L'échec est constaté, Swarm revient à la version précédente, et le temps de retour est affiché (environ 45 s sur les VM).

## 9. Panne du plan de données

```bash
TARGET=vm make data-restore-test
```

Attendu : `TEST REUSSI`. Le compte de test survit au redémarrage de la base, puis une perte simulée est annulée par la restauration.

Pour montrer la sauvegarde et la restauration séparément :

```bash
TARGET=vm make backup-db
TARGET=vm make restore-db FILE=backups/nebula-AAAAMMJJ-HHMMSS.sql.gz
```

Le fichier de sauvegarde est sur le poste, dans `backups/`, ignoré par Git.

## 10. Ajout d'un huitième service pendant la soutenance

```bash
TARGET=vm make add-service
```

Attendu : `TEST REUSSI`. Le service `statut` est construit, poussé sur le registry, déployé dans le cluster existant, et joint par l'edge sur `/api/statut`.

Ne pas modifier l'edge ni la stack Nebula : le routage est déclaré dans les labels du service. Montrer le fichier `swarm/stack.statut.yml`, qui ne contient que ces labels.

## Après la soutenance

Retirer le service ajouté, pour remettre le cluster dans son état :

```bash
ssh manager@10.96.238.1 'docker stack rm statut'
```
