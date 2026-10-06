#!/usr/bin/env bash
# Demonstration de tolerance a la panne, sur le lab a trois noeuds :
#   1. on arrete brutalement worker2 ;
#   2. le point d'entree doit rester disponible ;
#   3. les taches de worker2 doivent etre reprogrammees ailleurs ;
#   4. on relance worker2 : le noeud doit revenir Ready.
# worker2 est relance dans tous les cas (fin normale, erreur ou Ctrl+C).
# Relancable : si worker2 tourne deja, les etapes sont sans effet.
#
#   bash scripts/demo-panne.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1

MANAGER=nebula-lab-manager-1
W2=nebula-lab-worker2-1
API=${API:-http://localhost:8080}
dk() { docker exec "$MANAGER" docker "$@"; }

relance_worker2() { docker start "$W2" >/dev/null 2>&1 || true; }
trap relance_worker2 EXIT INT TERM

api_ok() { curl -fsS -m 5 "$API/api/fil" >/dev/null; } # /api/health n'est pas encore route par l'edge
attendre() { # attendre "<commande>" <secondes>
  for _ in $(seq 1 "$2"); do eval "$1" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}

echo "== 0. etat initial"
api_ok || { echo "!! API indisponible : lance d'abord 'make lab-up'"; exit 1; }
dk node ls --format '   {{.Hostname}} {{.Status}}'

echo "== 1. arret brutal de worker2"
docker stop "$W2" >/dev/null
attendre "dk node ls --filter name=worker2 --format '{{.Status}}' | grep -qx Down" 90 \
  && echo "   worker2 : Down" || echo "   !! worker2 pas encore Down"

echo "== 2. le point d'entree reste disponible pendant la panne"
attendre api_ok 30 && echo "   API OK" || { echo "!! API KO pendant la panne"; exit 1; }

echo "== 3. reprogrammation des taches"
attendre "dk service ls --format '{{.Replicas}}' | awk -F'/' '\$1!=\$2{f=1} END{exit f}'" 180 \
  && echo "   services de nouveau complets" \
  || { echo "   !! services pas tous complets :"; dk service ls --format '     {{.Name}} {{.Replicas}}'; }
echo "   placement de nebula_comptes :"
dk service ps nebula_comptes --filter desired-state=running --format '     {{.Name}} sur {{.Node}} ({{.CurrentState}})'

echo "== 4. retour de worker2"
docker start "$W2" >/dev/null
attendre "dk node ls --filter name=worker2 --format '{{.Status}}' | grep -qx Ready" 120 \
  && echo "   worker2 : Ready" || echo "   !! worker2 pas Ready"
attendre api_ok 30 && echo "   API OK apres retour" || echo "   !! API KO apres retour"
