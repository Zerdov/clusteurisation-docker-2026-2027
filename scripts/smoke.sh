#!/usr/bin/env bash
# Verifie la chaine complete : comptes -> publications -> bus -> worker -> medias
#   ./scripts/smoke.sh <hote>   (ex. 192.168.56.11, IP du manager)
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/lab.sh

H=${1:?donner l adresse a tester, ex. 192.168.56.11}
B="http://$H"
ok=0

t() { printf '  %-44s' "$1"; shift; if "$@" >/dev/null 2>&1; then echo OK; else echo ECHEC; ok=1; fi; }

# preuve_async : cree un compte et une publication, puis attend que worker-medias
# ecrive sa trace. Le volume "traces" est local au noeud qui traite le message
# (round-robin RabbitMQ entre les 2 replicas) : on ne sait pas d'avance lequel,
# donc on verifie sur tous les noeuds ou une tache nebula_worker-medias tourne.
preuve_async() {
  local auteur pub fichier noeud tache ip conteneur
  auteur=$(curl -fsS -m 10 -X POST "$B/api/comptes" -H 'content-type: application/json' \
    -d '{"pseudo":"async-'"$RANDOM"'"}' | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  [ -n "$auteur" ] || return 1
  pub=$(curl -fsS -m 10 -X POST "$B/api/publications" -H 'content-type: application/json' \
    -d '{"auteur_id":'"$auteur"',"titre":"preuve async"}' | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  [ -n "$pub" ] || return 1
  fichier="/data/publication-$pub.json"
  for _ in $(seq 1 30); do
    while read -r noeud tache; do
      [ -n "$noeud" ] || continue
      ip=$(dk node inspect "$noeud" --format '{{.Status.Addr}}')
      conteneur=$(dknode "$ip" ps -q --filter "label=com.docker.swarm.task.id=$tache" | head -1)
      [ -n "$conteneur" ] || continue
      dknode "$ip" exec "$conteneur" test -f "$fichier" 2>/dev/null && return 0
    done < <(dk service ps nebula_worker-medias --no-trunc --filter desired-state=running --format '{{.Node}} {{.ID}}')
    sleep 1
  done
  return 1
}

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
echo "== preuve de l'asynchrone (comptes -> publications -> bus -> worker-medias)"
t "trace ecrite par worker-medias apres une publication"   preuve_async

exit $ok
