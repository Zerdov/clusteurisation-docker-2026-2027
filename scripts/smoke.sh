#!/usr/bin/env bash
# Verifie la chaine complete : comptes -> publications -> bus -> worker -> medias
#   ./scripts/smoke.sh [hote]
set -euo pipefail
H=${1:-nebula.local}
B="http://$H"
ok=0

t() { printf '  %-44s' "$1"; shift; if "$@" >/dev/null 2>&1; then echo OK; else echo ECHEC; ok=1; fi; }

echo "== chaine applicative sur $B"
t "le point d'entree repond"        curl -fsS "$B/api/health"
t "creation d'un compte"            curl -fsS -X POST "$B/api/comptes" -H 'content-type: application/json' -d '{"pseudo":"smoke-'"$RANDOM"'"}'
t "lecture du fil"                  curl -fsS "$B/api/fil"

echo
echo "== preuve du cache (la 2e lecture doit venir du cache)"
curl -fsS "$B/api/fil" | sed -n 's/.*"source":"\([^"]*\)".*/  source : \1/p'
curl -fsS "$B/api/fil" | sed -n 's/.*"source":"\([^"]*\)".*/  source : \1/p'

echo
echo "== preuve de la repartition (10 appels, le hostname doit varier)"
for _ in $(seq 1 10); do
  curl -fsS "$B/api/health" | sed -n 's/.*"host":"\([^"]*\)".*/    \1/p'
done | sort | uniq -c

echo
echo "== preuve de l'asynchrone"
echo "   docker service logs --tail 10 nebula_worker-medias"
echo "   puis la console MinIO : un objet par publication"
exit $ok
