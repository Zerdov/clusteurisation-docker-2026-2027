# Nebula : squelette de projet

**Les trois services applicatifs sont écrits et ils fonctionnent.** Vous ne
touchez pas à leur code. Tout ce qui est noté est de l'infrastructure.

```
services/comptes/         POST /comptes, GET /comptes/:id
services/publications/    POST /publications (appelle comptes, publie un
                          événement), GET /fil (cache Redis 30 s)
services/worker-medias/   consomme les événements, écrit une trace par
                          publication (traitement volontairement lent : 1,5 s)
```

Les quatre démonstrations exigées par le cahier des charges sont déjà dans
le code : route de santé, flux entre services, écriture persistante,
traitement asynchrone. À vous de les faire tourner **en cluster**.

---

## Vérifier en 5 minutes que tout marche, hors Swarm

```bash
make dev
curl -X POST localhost:3001/comptes -H 'content-type: application/json' -d '{"pseudo":"moi"}'
curl -X POST localhost:3002/publications -H 'content-type: application/json' -d '{"auteur_id":1,"titre":"salut"}'
curl localhost:3002/fil
docker compose -f compose.dev.yml logs worker-medias
```

Vous devez voir le worker écrire un objet. Le worker écrit un fichier de trace par publication, dans son volume.
Interface RabbitMQ : `http://localhost:15672` (nebula / nebula12345).

**Ce n'est pas le livrable.** C'est juste la preuve que le code n'est pas en
cause quand quelque chose cassera en cluster.

---

## Commandes

```bash
make dev        # local, hors Swarm
make build      # construit et pousse les 3 images
make edge       # deploie Traefik (fourni)
make deploy     # deploie VOTRE stack
make smoke      # verifie la chaine complete
```

Ajoutez sur votre poste : `<IP_NŒUD>  nebula.local`

---

## Les ressources sont comptées

Six services et trois machines virtuelles sur un seul poste. Déclarez des
limites, sinon le noyau tue des conteneurs au hasard et vous chercherez une
cause applicative qui n'existe pas.

```yaml
deploy:
  resources:
    limits: { memory: 256M }
```

Trois réplicas suffisent partout pour démontrer la répartition.
