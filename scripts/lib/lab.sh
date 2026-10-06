#!/usr/bin/env bash
# Outils communs aux scripts de test. A sourcer depuis un script de scripts/ :
#   source "$(dirname "$0")/lib/lab.sh"
# N'execute rien a l'import : uniquement des variables et des fonctions.
export MSYS_NO_PATHCONV=1

# TARGET=lab (defaut) : les noeuds sont des conteneurs Docker-in-Docker.
# TARGET=vm           : les noeuds sont les VM, joignables en SSH (rebond dans ~/.ssh/config).
TARGET=${TARGET:-lab}

MANAGER=nebula-lab-manager-1
W1=nebula-lab-worker1-1
W2=nebula-lab-worker2-1
API=${API:-http://localhost:8080}      # en VM : tunnel SSH vers le port 80 du manager
DASH=${DASH:-http://localhost:8088}    # en VM : tunnel SSH vers le port 8088 du manager

if [ "$TARGET" = vm ]; then
  SSH_USER=${SSH_USER:-manager}
  MANAGER_IP=${MANAGER_IP:-10.96.238.1}
  W1_IP=${W1_IP:-10.96.238.2}
  W2_IP=${W2_IP:-10.96.238.3}
  REG_HOTE=$MANAGER_IP:5000    # vu depuis l'hote : le registry est sur le manager
  REG_NOEUDS=$MANAGER_IP:5000  # vu depuis les noeuds : le meme point d'entree
else
  REG_HOTE=localhost:5000      # vu depuis l'hote : build et push
  REG_NOEUDS=registry:5000     # vu depuis les noeuds : pull
fi

ECHECS=0

# dk <args...> : client docker du manager ; dkw1 <args...> : client docker du worker1.
if [ "$TARGET" = vm ]; then
  dk()   { docker -H "ssh://$SSH_USER@$MANAGER_IP" "$@"; }
  dkw1() { docker -H "ssh://$SSH_USER@$W1_IP" "$@"; }
else
  dk()   { docker exec "$MANAGER" docker "$@"; }
  dkw1() { docker exec -i "$W1" docker "$@"; }
fi

# attendre "<commande>" <secondes> : reussit des que la commande reussit
attendre() {
  for _ in $(seq 1 "$2"); do
    eval "$1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

conteneur_db() { dkw1 ps -q --filter name=nebula_db | head -1; }

# build_push <image:tag> <contexte> [args de build...] : construit puis pousse dans le registry.
# En VM, le build part vers le manager ; le push doit aussi partir du manager (le poste ne voit pas le registry).
build_push() {
  local img=$1 ctx=$2
  shift 2
  if [ "$TARGET" = vm ]; then
    dk build -q "$@" -t "$img" "$ctx" >/dev/null \
      && ssh -o BatchMode=yes "$SSH_USER@$MANAGER_IP" "docker push -q $img" >/dev/null
  else
    docker build -q "$@" -t "$img" "$ctx" >/dev/null && docker push -q "$img" >/dev/null
  fi
}

api_ok() { curl -fsS -m 5 "$API/api/health" >/dev/null 2>&1; }

# hotes <n> : une ligne par reponse reussie de /api/health, avec le hostname de l'instance.
# Le parsing se fait DANS chaque processus : une seule ecriture par ligne, donc pas de
# reponses collees entre elles quand xargs tourne en parallele.
hotes() {
  seq "$1" | xargs -P 10 -I{} sh -c \
    'curl -fsS -m 5 -w "\n" "$1" 2>/dev/null | sed -n "s/.*\"host\":\"\([^\"]*\)\".*/\1/p"' _ "$API/api/health"
}
# repartition <n> : nombre de requetes servies par instance
repartition() { hotes "$1" | sort | uniq -c | sort -rn; }
# hotes_distincts <n> : nombre d'instances differentes ayant repondu
hotes_distincts() { hotes "$1" | sort -u | grep -c . || true; }

# verdict "<libelle>" <0|1> [detail] : affiche le resultat et compte les echecs (0 = reussi)
verdict() {
  if [ "$2" -eq 0 ]; then
    printf '  OK     %s\n' "$1"
  else
    printf '  ECHEC  %s\n' "$1"
    ECHECS=$((ECHECS + 1))
  fi
  if [ -n "${3:-}" ]; then printf '         %s\n' "$3"; fi
  return 0
}

# bilan : resume le test, renvoie 1 si un controle a echoue
bilan() {
  echo
  if [ "$ECHECS" -eq 0 ]; then
    echo "TEST REUSSI"
    return 0
  fi
  echo "TEST ECHOUE ($ECHECS controle(s) en echec)"
  return 1
}
