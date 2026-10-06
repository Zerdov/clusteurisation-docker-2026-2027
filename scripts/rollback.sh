#!/usr/bin/env bash
# Version defectueuse puis retour arriere. On deploie une image qui demarre
# puis plante. Swarm doit constater l'echec, revenir a la version precedente, et l'API
# doit repondre a nouveau. Le temps de detection et de retour est affiche.
#   bash scripts/rollback.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/lab.sh

ACTUELLE=$(dk service inspect nebula_comptes --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')
CASSEE="$REG_NOEUDS/nebula-comptes:casse-$(date +%H%M%S)"
echo "== version defectueuse. Version en service : $ACTUELLE"

# 1. image defectueuse : la version actuelle, dont le code est casse (module absent).
#    On casse le CODE et non la commande : la stack definit sa propre 'command' qui
#    remplace la CMD de l'image.
ctx=$(mktemp -d)
trap 'rm -rf "$ctx"' EXIT
printf 'FROM %s\nUSER root\nRUN rm -f /app/src/index.js\nUSER node\n' "${ACTUELLE/$REG_NOEUDS/$REG_HOTE}" > "$ctx/Dockerfile"
build_push "${CASSEE/$REG_NOEUDS/$REG_HOTE}" "$ctx"
verdict "image defectueuse construite et poussee" $?

# 2. deploiement de la version defectueuse, chronometre
t0=$(date +%s)
dk service update --image "$CASSEE" nebula_comptes >/dev/null
sleep 5
attendre "dk service inspect nebula_comptes --format '{{.UpdateStatus.State}}' | grep -qE '^(rollback_completed|paused)$'" 300
t1=$(date +%s)

# 3. constat
etat=$(dk service inspect nebula_comptes --format '{{.UpdateStatus.State}}')
verdict "echec constate et retour arriere effectue (etat : $etat)" \
  $([ "$etat" = rollback_completed ] && echo 0 || echo 1)
apres=$(dk service inspect nebula_comptes --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')
verdict "version precedente de nouveau en service" $([ "$apres" = "$ACTUELLE" ] && echo 0 || echo 1) "$apres"
attendre api_ok 60
verdict "API disponible apres le retour arriere" $?
echo "   temps de detection et de retour arriere : $((t1 - t0)) s"

bilan
