#!/usr/bin/env bash
# Deploie Nebula sur les trois VM, depuis TON POSTE.
#
# Regle : tout ce qui touche au registry (login, pull, push, stack deploy avec
# --with-registry-auth) s'execute SUR LE MANAGER, via ssh. Le poste ne voit pas le
# registry : un push lance depuis le client local echoue (connection refused).
# Les builds et les operations Swarm passent par le client local en ssh (docker -H).
# Le SSH passe par le rebond defini dans ~/.ssh/config (ProxyJump).
#
#   SSH_USER=manager bash scripts/vm-up.sh
#
# Prerequis : acces SSH par cle aux trois VM (BatchMode), Docker sur le poste,
# registry en service Swarm (swarm/stack.registry.yml) sur le manager.
#
# Ce script NE REINITIALISE JAMAIS le Swarm : un Swarm degrade se diagnostique,
# il ne s'efface pas.
set -euo pipefail
cd "$(dirname "$0")/.."

SSH_USER=${SSH_USER:-manager}
MANAGER_IP=${MANAGER_IP:-10.96.238.1}
W1_IP=${W1_IP:-10.96.238.2}
W2_IP=${W2_IP:-10.96.238.3}
REGISTRY=${REGISTRY:-$MANAGER_IP:5000}
MANAGER=clusteurisation-docker-manager
W1=clusteurisation-docker-worker1
W2=clusteurisation-docker-worker2
TAG=${TAG:-$(git rev-parse --short HEAD)}
REMOTE_DIR='~/nebula'                              # copie de swarm/ et db/ sur le manager

D="docker -H ssh://$SSH_USER@$MANAGER_IP"         # Swarm, builds (contexte envoye par ssh)
DW1="docker -H ssh://$SSH_USER@$W1_IP"
mgr() { ssh -o BatchMode=yes "$SSH_USER@$MANAGER_IP" "$@"; }   # commandes sur le manager
export MSYS_NO_PATHCONV=1

echo "== 1. acces aux VM et identifiants"
for ip in "$MANAGER_IP" "$W1_IP" "$W2_IP"; do
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$ip" true \
    || { echo "!! SSH impossible vers $ip (cle absente ? rebond ?)"; exit 1; }
done
bash scripts/registry-auth.sh
REG_USER=$(cat secrets/registry_user)
echo "   ok"

echo "== 2. Swarm (jamais reinitialise ici)"
ETAT=$($D info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo absent)
if [ "$ETAT" != active ]; then
  echo "   init sur $MANAGER_IP"
  $D swarm init --advertise-addr "$MANAGER_IP" >/dev/null
  JETON=$($D swarm join-token -q worker)
  for ip in "$W1_IP" "$W2_IP"; do
    ssh -o BatchMode=yes "$SSH_USER@$ip" "docker swarm join --token $JETON $MANAGER_IP:2377" >/dev/null
  done
fi
PRETS=$($D node ls --format '{{.Status}}' | grep -c '^Ready$' || true)
[ "$PRETS" = 3 ] || { echo "!! $PRETS noeud(s) Ready sur 3 : $D node ls"; exit 1; }
$D node update --label-add tier=data "$W1" >/dev/null
$D node update --label-add tier=app "$W2" >/dev/null
echo "   3 noeuds Ready, labels tier=data ($W1) et tier=app ($W2)"

echo "== 3. fichiers de stack sur le manager, puis registry"
tar -cf - swarm db | mgr "mkdir -p $REMOTE_DIR && tar -xf - -C $REMOTE_DIR"
echo "   swarm/ et db/ copies sur le manager"

if ! $D secret inspect registry_htpasswd >/dev/null 2>&1; then
  $D secret create registry_htpasswd secrets/registry_htpasswd >/dev/null
  echo "   secret registry_htpasswd cree"
fi
mgr "cd $REMOTE_DIR && docker stack deploy -c swarm/stack.registry.yml registry" >/dev/null 2>&1

# Le registry repond 401 sans identifiants : c'est la preuve qu'il est en marche.
attendre_registry() {
  for _ in $(seq 1 60); do
    c=$(mgr 'curl -s -o /dev/null -w "%{http_code}" -m 5 http://localhost:5000/v2/' 2>/dev/null || true)
    if [ "$c" = 401 ] || [ "$c" = 200 ]; then return 0; fi
    sleep 2
  done
  return 1
}
attendre_registry || { echo "!! registry injoignable sur le manager : $D service ps registry_registry"; exit 1; }
mgr "docker login $REGISTRY -u $REG_USER --password-stdin" < secrets/registry_password >/dev/null \
  || { echo "!! login registry refuse (sur le manager)"; exit 1; }
echo "   registry en marche, login reussi (sur le manager)"

echo "== 4. images : base puis services, poussees depuis le manager"
for img in postgres:18-alpine redis:7-alpine rabbitmq:4-management-alpine; do
  mgr "docker pull -q $img && docker tag $img $REGISTRY/$img && docker push -q $REGISTRY/$img" >/dev/null
  echo "   $img"
done
for s in comptes publications worker-medias; do
  $D build -q --build-arg "APP_VERSION=$TAG" -t "$REGISTRY/nebula-$s:$TAG" "services/$s" >/dev/null
  mgr "docker push -q $REGISTRY/nebula-$s:$TAG" >/dev/null
  echo "   nebula-$s:$TAG"
done

echo "== 5. secrets et config (crees une seule fois)"
for s in pg_password bus_password; do
  if ! $D secret inspect "$s" >/dev/null 2>&1; then
    openssl rand -hex 16 | $D secret create "$s" - >/dev/null
    echo "   secret $s cree"
  fi
done
$D config inspect nebula_db_init >/dev/null 2>&1 || $D config create nebula_db_init db/init.sql >/dev/null

echo "== 6. dashboard Traefik : identifiants hors Git"
mkdir -p secrets && chmod 700 secrets
if [ ! -f secrets/dashboard_password.txt ]; then
  openssl rand -base64 18 | tr -d '/+=' > secrets/dashboard_password.txt
  chmod 600 secrets/dashboard_password.txt
  echo "   mot de passe genere : secrets/dashboard_password.txt (login : admin)"
fi
DASHBOARD_USERS="$(docker run --rm httpd:2 htpasswd -nbB admin "$(cat secrets/dashboard_password.txt)")"
# Le hash est transmis par stdin et stocke sur le manager : pas de quoting dans la commande ssh.
printf '%s' "$DASHBOARD_USERS" | mgr "cat > $REMOTE_DIR/.dashboard_users"

echo "== 7. edge puis Nebula (deployes sur le manager)"
mgr "cd $REMOTE_DIR && DASHBOARD_USERS=\$(cat .dashboard_users) docker stack deploy -c swarm/stack.edge.yml edge" >/dev/null 2>&1
mgr "cd $REMOTE_DIR && REGISTRY=$REGISTRY TAG=$TAG docker stack deploy -c swarm/stack.nebula.todo.yml --with-registry-auth nebula" >/dev/null 2>&1
echo "   deployes"

echo "== 8. mot de passe de la base aligne sur le secret (volume conserve)"
DB=""
for _ in $(seq 1 60); do
  DB=$($DW1 ps -q --filter name=nebula_db | head -1)
  [ -n "$DB" ] && $DW1 exec "$DB" pg_isready -U nebula -d nebula >/dev/null 2>&1 && break
  sleep 2
done
[ -n "$DB" ] || { echo "!! base pas demarree sur $W1"; exit 1; }
$DW1 exec "$DB" sh -c \
  'echo "ALTER USER nebula PASSWORD '"'"'$(cat /run/secrets/pg_password)'"'"';" | psql -q -U nebula -d nebula -v ON_ERROR_STOP=1' >/dev/null
echo "   aligne"

echo "== 9. test via le point d'entree (depuis le manager, port 80)"
sleep 20
$D service ls --format '   {{.Name}} {{.Replicas}}'
mgr "curl -fsS -m 10 -X POST http://localhost/api/comptes -H 'content-type: application/json' -d '{\"pseudo\":\"vm-'\$RANDOM'\"}'" \
  && echo || echo "!! echec : $D service ps nebula_comptes"
