#!/usr/bin/env bash
# Deploie Nebula sur les trois VM (annexe D), depuis TON POSTE.
# Aucun fichier n'est copie sur les VM : le client docker local parle au manager
# en SSH (DOCKER_HOST=ssh://...) et lit les fichiers de stack localement.
#
#   SSH_USER=<user> REGISTRY=<ip4>:5000 bash scripts/vm-up.sh
#
# Prerequis :
#   - acces SSH par cle aux trois VM, et docker installe localement
#   - le registry (4e VM) joignable par les trois VM ET par ce poste
#   - ce poste et les VM declarent le registry en "insecure-registries"
#     (HTTP) dans daemon.json
#
# Contrairement a lab/up.sh, ce script NE REINITIALISE JAMAIS le Swarm : sur de
# vraies VM, un Swarm degrade se diagnostique, il ne s'efface pas.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SSH_USER:?definir SSH_USER}"
: "${REGISTRY:?definir REGISTRY (ex. 10.96.238.4:5000)}"
MANAGER_IP=${MANAGER_IP:-10.96.238.1}
W1_IP=${W1_IP:-10.96.238.2}
W2_IP=${W2_IP:-10.96.238.3}
MANAGER=clusteurisation-docker-manager
W1=clusteurisation-docker-worker1
W2=clusteurisation-docker-worker2
TAG=${TAG:-$(git rev-parse --short HEAD)}

D="docker -H ssh://$SSH_USER@$MANAGER_IP"                 # tout le swarm passe par le manager
DW1="docker -H ssh://$SSH_USER@$W1_IP"
export MSYS_NO_PATHCONV=1

echo "== 1. acces aux VM et au registry"
bash scripts/registry-auth.sh
REG_USER=$(cat secrets/registry_user)
# Un registry authentifie repond 401 sur /v2/ : c'est la preuve qu'il est joignable.
REG_OK='c=$(curl -s -o /dev/null -w "%{http_code}" -m 5 http://'"$REGISTRY"'/v2/); [ "$c" = 200 ] || [ "$c" = 401 ]'
for ip in "$MANAGER_IP" "$W1_IP" "$W2_IP"; do
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$ip" true || { echo "!! SSH impossible vers $ip"; exit 1; }
  ssh -o BatchMode=yes "$SSH_USER@$ip" "$REG_OK" \
    || { echo "!! $ip ne voit pas le registry $REGISTRY (insecure-registries ? pare-feu ?)"; exit 1; }
done
# Connexion du poste : pour le build/push, et pour --with-registry-auth (transmis aux noeuds).
docker login "$REGISTRY" -u "$REG_USER" --password-stdin < secrets/registry_password >/dev/null \
  || { echo "!! login registry refuse"; exit 1; }
echo "   ok"

echo "== 2. Swarm (jamais reinitialise ici)"
ETAT=$($D info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo absent)
if [ "$ETAT" != active ]; then
  echo "   init sur $MANAGER_IP"
  ssh "$SSH_USER@$MANAGER_IP" "docker swarm init --advertise-addr $MANAGER_IP" >/dev/null
  JETON=$(ssh "$SSH_USER@$MANAGER_IP" "docker swarm join-token -q worker")
  for ip in "$W1_IP" "$W2_IP"; do
    ssh "$SSH_USER@$ip" "docker swarm join --token $JETON $MANAGER_IP:2377" >/dev/null
  done
fi
PRETS=$($D node ls --format '{{.Status}}' | grep -c '^Ready$' || true)
[ "$PRETS" = 3 ] || { echo "!! $PRETS noeud(s) Ready sur 3 : $D node ls"; exit 1; }
$D node update --label-add tier=data "$W1" >/dev/null
$D node update --label-add tier=app "$W2" >/dev/null
echo "   3 noeuds Ready, labels tier=data (worker1) et tier=app (worker2)"

echo "== 3. images de base et services dans le registry"
for img in postgres:18-alpine redis:7-alpine rabbitmq:4-management-alpine; do
  docker pull -q "$img" >/dev/null
  docker tag "$img" "$REGISTRY/$img"
  docker push -q "$REGISTRY/$img" >/dev/null
  echo "   $img"
done
REGISTRY=$REGISTRY bash scripts/build-push.sh "$TAG" >/dev/null
echo "   services tag $TAG"

echo "== 4. secrets et config (crees une seule fois)"
for s in pg_password bus_password; do
  if ! $D secret inspect "$s" >/dev/null 2>&1; then
    openssl rand -hex 16 | $D secret create "$s" - >/dev/null
    echo "   secret $s cree"
  fi
done
$D config inspect nebula_db_init >/dev/null 2>&1 || $D config create nebula_db_init db/init.sql >/dev/null

echo "== 5. dashboard Traefik : identifiants hors Git"
mkdir -p secrets && chmod 700 secrets
if [ ! -f secrets/dashboard_password.txt ]; then
  openssl rand -base64 18 | tr -d '/+=' > secrets/dashboard_password.txt
  chmod 600 secrets/dashboard_password.txt
  echo "   mot de passe genere : secrets/dashboard_password.txt (login : admin)"
fi
DASHBOARD_USERS="$(docker run --rm httpd:2 htpasswd -nbB admin "$(cat secrets/dashboard_password.txt)")"
export DASHBOARD_USERS

echo "== 6. edge puis Nebula"
$D stack deploy -c swarm/stack.edge.yml edge >/dev/null 2>&1
REGISTRY=$REGISTRY TAG=$TAG $D stack deploy -c swarm/stack.nebula.todo.yml --with-registry-auth nebula >/dev/null 2>&1
echo "   deployes"

echo "== 7. mot de passe de la base aligne sur le secret (volume conserve)"
for _ in $(seq 1 60); do
  DB=$($DW1 ps -q --filter name=nebula_db | head -1)
  [ -n "$DB" ] && $DW1 exec "$DB" pg_isready -U nebula -d nebula >/dev/null 2>&1 && break
  sleep 2
done
$DW1 exec "$DB" sh -c \
  'echo "ALTER USER nebula PASSWORD '"'"'$(cat /run/secrets/pg_password)'"'"';" | psql -q -U nebula -d nebula -v ON_ERROR_STOP=1' >/dev/null
echo "   aligne"

echo "== 8. test via le point d'entree"
sleep 20
$D service ls --format '   {{.Name}} {{.Replicas}}'
curl -fsS -m 10 -X POST "http://$MANAGER_IP/api/comptes" -H 'content-type: application/json' \
  -d "{\"pseudo\":\"vm-$RANDOM\"}" && echo || echo "!! echec : $D service ps nebula_comptes"
