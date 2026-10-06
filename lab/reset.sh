#!/usr/bin/env bash
# DESTRUCTIF : supprime les conteneurs ET les volumes du lab (base, traces,
# registry, etat du Swarm). Les secrets locaux (secrets/) et le depot sont conserves.
# Apres un reset, lab/up.sh recree tout : secrets Swarm, base initialisee, images.
#
#   bash lab/reset.sh           # demande de taper RESET
#   bash lab/reset.sh --yes     # sans confirmation
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" != "--yes" ]; then
  read -r -p "Supprimer le lab ET ses volumes (base, registry, Swarm) ? Taper RESET : " reponse
  [ "$reponse" = RESET ] || { echo "annule"; exit 1; }
fi
docker compose -f lab/compose.dind.yml down -v
echo "lab supprime. Relance : bash lab/up.sh"
