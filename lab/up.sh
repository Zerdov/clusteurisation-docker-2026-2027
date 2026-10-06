#!/usr/bin/env bash
# Monte le lab Swarm a trois noeuds, de bout en bout (edge + Nebula).
# Idempotent : relancable sans risque. Ne supprime AUCUN volume.
#
#   bash lab/up.sh              # tag = commit courant
#   TAG=v1 bash lab/up.sh       # tag explicite
#
# Si le Swarm est absent ou degrade (noeud Down apres un redemarrage du lab),
# il est reinitialise : les services et les secrets Swarm sont recrees.
# Les donnees des volumes (base, traces) sont conservees.
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1

MANAGER=nebula-lab-manager-1
W1=nebula-lab-worker1-1
W2=nebula-lab-worker2-1
TAG=${TAG:-$(git rev-parse --short HEAD)}
REG_HOTE=localhost:5000     # vu depuis la machine hote (build, push)
REG_NOEUDS=registry:5000    # vu depuis les noeuds du lab (pull)

dk() { docker exec "$MANAGER" docker "$@"; }
attendre() { # attendre "<commande>" <secondes>
  for _ in $(seq 1 "$2"); do eval "$1" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}

echo "== 1. noeuds du lab (daemons Docker-in-Docker + registry authentifie)"
bash scripts/registry-auth.sh
docker compose -f lab/compose.dind.yml up -d >/dev/null
for c in "$MANAGER" "$W1" "$W2"; do
  attendre "docker exec $c docker info" 120 || { echo "!! daemon $c indisponible"; exit 1; }
done
REG_USER=$(cat secrets/registry_user)
REG_PW_FILE=secrets/registry_password
# Connexion de l'hote (push) et du manager (--with-registry-auth transmet ces identifiants aux workers).
attendre "docker exec $MANAGER docker info" 60 >/dev/null
docker login "$REG_HOTE" -u "$REG_USER" --password-stdin < "$REG_PW_FILE" >/dev/null
docker exec -i "$MANAGER" docker login "$REG_NOEUDS" -u "$REG_USER" --password-stdin < "$REG_PW_FILE" >/dev/null
echo "   pret, registry connecte"

echo "== 2. Swarm"
ETAT=$(dk info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo absent)
PRETS=$(dk node ls --format '{{.Status}}' 2>/dev/null | grep -c '^Ready$' || true)
if [ "$ETAT" != active ] || [ "$PRETS" != 3 ]; then
  echo "   swarm absent ou degrade (noeuds prets : $PRETS) : reinitialisation"
  for c in "$W1" "$W2" "$MANAGER"; do docker exec "$c" docker swarm leave --force >/dev/null 2>&1 || true; done
  MIP=$(docker inspect "$MANAGER" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' | awk '{print $1}')
  dk swarm init --advertise-addr "$MIP" >/dev/null
  JETON=$(dk swarm join-token -q worker)
  for c in "$W1" "$W2"; do docker exec "$c" docker swarm join --token "$JETON" "$MIP:2377" >/dev/null; done
  attendre "[ \$(docker exec $MANAGER docker node ls --format '{{.Status}}' | grep -c '^Ready\$') = 3 ]" 60 \
    || { echo "!! les trois noeuds ne sont pas Ready"; dk node ls; exit 1; }
fi
dk node update --label-add tier=data worker1 >/dev/null
dk node update --label-add tier=app worker2 >/dev/null
dk node ls --format '   {{.Hostname}} {{.Status}} {{.Availability}}'

echo "== 3. images de base recopiees dans le registry du lab"
for img in postgres:18-alpine redis:7-alpine rabbitmq:4-management-alpine; do
  docker pull -q "$img" >/dev/null
  docker tag "$img" "$REG_HOTE/$img"
  docker push -q "$REG_HOTE/$img" >/dev/null
  echo "   $img"
done

echo "== 4. images des services (tag $TAG)"
if ! git diff --quiet; then echo "   !! modifications non commitees : le tag $TAG ne les identifie pas"; fi
REGISTRY=$REG_HOTE bash scripts/build-push.sh "$TAG" >/dev/null

echo "== 5. secrets et config (crees une seule fois)"
for s in pg_password bus_password; do
  if ! dk secret inspect "$s" >/dev/null 2>&1; then
    openssl rand -hex 16 | docker exec -i "$MANAGER" docker secret create "$s" - >/dev/null
    echo "   secret $s cree"
  fi
done
# Une config est immuable : si db/init.sql change, il faut un nouveau nom.
dk config inspect nebula_db_init >/dev/null 2>&1 || dk config create nebula_db_init /repo/db/init.sql >/dev/null

echo "== 6. edge (dashboard protege par basicauth)"
mkdir -p secrets && chmod 700 secrets
if [ ! -f secrets/dashboard_password.txt ]; then
  openssl rand -base64 18 | tr -d '/+=' > secrets/dashboard_password.txt
  chmod 600 secrets/dashboard_password.txt
  echo "   mot de passe genere : secrets/dashboard_password.txt (login : admin)"
fi
HASH=$(docker run --rm httpd:2 htpasswd -nbB admin "$(cat secrets/dashboard_password.txt)")
docker exec -e DASHBOARD_USERS="$HASH" "$MANAGER" docker stack deploy -c /repo/swarm/stack.edge.yml edge >/dev/null 2>&1
echo "   deploye"

echo "== 7. Nebula"
docker exec -e REGISTRY="$REG_NOEUDS" -e TAG="$TAG" "$MANAGER" \
  docker stack deploy -c /repo/swarm/stack.nebula.todo.yml --with-registry-auth nebula >/dev/null 2>&1
echo "   deploye"

echo "== 7b. mot de passe de la base aligne sur le secret (le volume est conserve)"
# Si le Swarm a ete reinitialise, le secret a change mais la base garde l'ancien
# mot de passe. On le realigne ; la commande est sans effet si tout est deja a jour.
attendre "docker exec $W1 docker ps -q --filter name=nebula_db | grep -q ." 120 \
  || { echo "!! base pas demarree"; exit 1; }
DB=$(docker exec "$W1" docker ps -q --filter name=nebula_db | head -1)
attendre "docker exec $W1 docker exec $DB pg_isready -U nebula -d nebula" 60 \
  || { echo "!! base pas prete"; exit 1; }
docker exec "$W1" docker exec "$DB" sh -c \
  'echo "ALTER USER nebula PASSWORD '"'"'$(cat /run/secrets/pg_password)'"'"';" | psql -q -U nebula -d nebula -v ON_ERROR_STOP=1'
echo "   aligne"

echo "== 8. convergence (jusqu'a 3 min)"
attendre "docker exec $MANAGER docker service ls --format '{{.Replicas}}' | awk -F'/' '\$1!=\$2{f=1} END{exit f}'" 180 \
  || echo "   !! services pas tous prets : docker exec $MANAGER docker service ls"
dk service ls --format '   {{.Name}} {{.Replicas}}'

echo "== 9. test (Traefik rafraichit ses routes toutes les 10 s : on attend la route)"
test_creation() { curl -fsS -m 5 -X POST http://localhost:8080/api/comptes \
  -H 'content-type: application/json' -d "{\"pseudo\":\"lab-$RANDOM\"}"; }
if attendre test_creation 60 >/dev/null; then
  test_creation && echo
else
  echo "!! echec : verifier 'docker exec $MANAGER docker service ps nebula_comptes'"
fi
