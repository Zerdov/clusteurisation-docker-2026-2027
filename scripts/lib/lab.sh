#!/usr/bin/env bash
# Outils communs aux scripts de test. A sourcer depuis un script de scripts/ :
#   source "$(dirname "$0")/lib/lab.sh"
# N'execute rien a l'import : uniquement des variables et des fonctions.
export MSYS_NO_PATHCONV=1

MANAGER=nebula-lab-manager-1
W1=nebula-lab-worker1-1
W2=nebula-lab-worker2-1
API=${API:-http://localhost:8080}
DASH=${DASH:-http://localhost:8088}
REG_HOTE=localhost:5000      # vu depuis l'hote : build et push
REG_NOEUDS=registry:5000     # vu depuis les noeuds : pull

ECHECS=0

dk() { docker exec "$MANAGER" docker "$@"; }

# attendre "<commande>" <secondes> : reussit des que la commande reussit
attendre() {
  for _ in $(seq 1 "$2"); do
    eval "$1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

conteneur_db() { docker exec "$W1" docker ps -q --filter name=nebula_db | head -1; }

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
