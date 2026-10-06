#!/usr/bin/env bash
# Arrete le lab (manager, workers, registry) SANS supprimer les volumes.
# Le Swarm, la base et les traces sont conserves : lab/up.sh les retrouve.
#
#   bash lab/down.sh
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose -f lab/compose.dind.yml down
echo "lab arrete, volumes conserves. Relance : bash lab/up.sh"
