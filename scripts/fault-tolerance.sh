#!/usr/bin/env bash
# Tolerance de panne : tue le conteneur d'une replique en pleine charge (pas le
# service), verifie que Swarm le reprogramme automatiquement et que le trafic
# ne s'interrompt pas pendant l'operation.
#   SERVICE=nebula_comptes bash scripts/fault-tolerance.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/lab.sh

SERVICE=${SERVICE:?definir SERVICE (nom du service a tester, ex. nebula_comptes)}

# 1. une tache en cours d'execution, sur n'importe quel noeud
# --no-trunc : l'ID de tache doit etre complet pour correspondre au label
# com.docker.swarm.task.id pose sur le conteneur (sinon aucune correspondance).
ligne=$(dk service ps "$SERVICE" --no-trunc --filter desired-state=running --format '{{.Node}} {{.ID}}' | head -1)
NOEUD=$(printf '%s\n' "$ligne" | awk '{print $1}')
TACHE=$(printf '%s\n' "$ligne" | awk '{print $2}')
[ -n "$NOEUD" ] && [ -n "$TACHE" ] || { echo "!! aucune tache en marche pour $SERVICE"; exit 1; }
echo "== $SERVICE : tache choisie sur $NOEUD"

NOEUD_IP=$(dk node inspect "$NOEUD" --format '{{.Status.Addr}}')
CONTENEUR=$(dknode "$NOEUD_IP" ps -q --filter "label=com.docker.swarm.task.id=$TACHE" | head -1)
[ -n "$CONTENEUR" ] || { echo "!! conteneur introuvable sur $NOEUD ($NOEUD_IP)"; exit 1; }

# 2. trafic continu pendant toute la manipulation
journal=$(mktemp)
trap 'kill "$charge" 2>/dev/null; rm -f "$journal"' EXIT
( while true; do curl -s -m 5 -w ' %{http_code}\n' "$API/api/health"; sleep 0.2; done ) >> "$journal" 2>/dev/null &
charge=$!
sleep 2

# 3. on tue le conteneur (pas "docker service" / "docker stop") : simule un vrai crash
t0=$(date +%s)
dknode "$NOEUD_IP" kill "$CONTENEUR" >/dev/null
echo "   conteneur $CONTENEUR tue sur $NOEUD"

# 4. Swarm doit constater l'echec et reprogrammer une nouvelle tache Running
attendre "dk service ps '$SERVICE' --filter desired-state=running --format '{{.CurrentState}}' | grep -q '^Running'" 60
reprogramme=$?
t1=$(date +%s)
verdict "nouvelle tache reprogrammee et en marche ($((t1 - t0))s)" "$reprogramme"

sleep 3
kill "$charge" 2>/dev/null
wait "$charge" 2>/dev/null

# 5. analyse du trafic pendant la coupure : c'est la preuve de la continuite de service
total=$(wc -l < "$journal" | tr -d ' ')
echecs=$(awk '$NF != "200"' "$journal" | wc -l | tr -d ' ')
codes_echec=$(awk '$NF != "200" { print $NF }' "$journal" | sort | uniq -c | sed "s/^/code /")
verdict "$total requetes pendant la panne, $echecs en echec" \
  $([ "$total" -gt 0 ] && [ "$echecs" -eq 0 ] && echo 0 || echo 1) "$codes_echec"

echo
echo "== etat final"
dk service ps "$SERVICE" --filter desired-state=running

bilan
