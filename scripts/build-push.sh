#!/usr/bin/env bash
# Construit les trois services et les pousse dans votre registry.
#   REGISTRY=registry.local:5000 ./scripts/build-push.sh v1
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
REGISTRY=${REGISTRY:-registry.local:5000}
TAG=${1:-v1}

for s in comptes publications worker-medias; do
  IMG="$REGISTRY/nebula-$s:$TAG"
  echo "== $IMG"
  docker build --build-arg "APP_VERSION=$TAG" -t "$IMG" "./services/$s"
  docker push "$IMG"
done
echo
echo "Tags pousses. Rappel : jamais 'latest' sur un cluster."
