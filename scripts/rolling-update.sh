#!/usr/bin/env bash
# Mise a jour sans interruption perceptible : nebula_comptes passe a une
# nouvelle version pendant qu'un trafic continu interroge l'API. Aucune requete ne doit echouer.
#   bash scripts/rolling-update.sh
#   NOUVEAU=v2 bash scripts/rolling-update.sh   # tag explicite
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/lab.sh

NOUVEAU=${NOUVEAU:-$(git rev-parse --short HEAD)-m$(date +%H%M%S)}
echo "== nebula_comptes -> version $NOUVEAU"

# 1. nouvelle image : meme code, nouvelle version (lue dans /health)
build_push "$REG_HOTE/nebula-comptes:$NOUVEAU" services/comptes --build-arg "APP_VERSION=$NOUVEAU"
verdict "image $NOUVEAU construite et poussee" $?

# 2. trafic continu : une ligne par requete, avec la reponse et le code HTTP
journal=$(mktemp)
trap 'kill "$charge" 2>/dev/null; rm -f "$journal"' EXIT
( while true; do curl -s -m 5 -w ' %{http_code}\n' "$API/api/health"; sleep 0.2; done ) >> "$journal" 2>/dev/null &
charge=$!
sleep 3

# 3. la mise a jour
dk service update --image "$REG_NOEUDS/nebula-comptes:$NOUVEAU" nebula_comptes >/dev/null
sleep 5
attendre "dk service inspect nebula_comptes --format '{{.UpdateStatus.State}}' | grep -qx completed" 600
verdict "mise a jour terminee (UpdateStatus = completed)" $?
sleep 3
kill "$charge" 2>/dev/null
wait "$charge" 2>/dev/null

# 4. analyse du trafic
total=$(wc -l < "$journal" | tr -d ' ')
echecs=$(awk '$NF != "200"' "$journal" | wc -l | tr -d ' ')
codes_echec=$(awk '$NF != "200" { print $NF }' "$journal" | sort | uniq -c | sed "s/^/code /")
versions=$(grep -o '"version":"[^"]*"' "$journal" | sort | uniq -c)
verdict "$total requetes pendant la mise a jour, $echecs en echec" \
  $([ "$total" -gt 0 ] && [ "$echecs" -eq 0 ] && echo 0 || echo 1) "$codes_echec"
verdict "les deux versions ont ete servies pendant la bascule" \
  $([ "$(printf '%s\n' "$versions" | grep -c .)" -ge 2 ] && echo 0 || echo 1) "$versions"

bilan
