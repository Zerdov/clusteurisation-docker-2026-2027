#!/usr/bin/env bash
# Ajout d'un service imprevu pendant la soutenance : le service "statut"
# est construit, pousse, deploye dans le cluster existant, puis joint par l'edge.
# Ni l'edge ni la stack Nebula ne sont modifies. Relancable : deploiement idempotent.
#   bash scripts/add-service.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/lab.sh

TAG=${TAG:-$(git rev-parse --short HEAD)}
echo "== ajout du service statut (tag $TAG)"

build_push "$REG_HOTE/nebula-statut:$TAG" services/statut --build-arg "APP_VERSION=$TAG"
verdict "image nebula-statut:$TAG construite et poussee" $?

sortie=$(REGISTRY="$REG_NOEUDS" TAG="$TAG" stack_deploy statut swarm/stack.statut.yml 2>&1)
verdict "stack statut deployee" $? "$sortie"

attendre "dk service ls --format '{{.Name}} {{.Replicas}}' | grep -qx 'statut_statut 2/2'" 180
verdict "statut_statut : 2 instances en marche" $?

attendre "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -m 5 $API/api/statut)\" = 200 ]" 120
verdict "GET /api/statut repond via l'edge" $?

echo "   repartition sur les instances de statut :"
for _ in $(seq 1 10); do curl -s -m 5 "$API/api/statut"; echo; done |
  sed -n 's/.*"host":"\([^"]*\)".*/\1/p' | sort | uniq -c | sed 's/^/     /'

bilan
