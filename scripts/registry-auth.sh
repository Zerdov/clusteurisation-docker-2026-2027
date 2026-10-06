#!/usr/bin/env bash
# Cree les identifiants du registry (une seule fois, idempotent) dans ./secrets/ :
#   secrets/registry_user        nom d'utilisateur
#   secrets/registry_password    mot de passe aleatoire
#   secrets/registry_htpasswd    fichier htpasswd (bcrypt) lu par le registry
# Rien n'est ecrit dans le depot : secrets/ est ignore par Git.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p secrets && chmod 700 secrets
[ -f secrets/registry_user ] || echo nebula > secrets/registry_user
[ -f secrets/registry_password ] || openssl rand -base64 24 | tr -d '/+=' > secrets/registry_password
chmod 600 secrets/registry_user secrets/registry_password

if [ ! -f secrets/registry_htpasswd ]; then
  # htpasswd -B : bcrypt. Le mot de passe passe par l'environnement, pas en argument visible.
  docker run --rm -e PW="$(cat secrets/registry_password)" -e U="$(cat secrets/registry_user)" \
    httpd:2 sh -c 'htpasswd -nbB "$U" "$PW"' > secrets/registry_htpasswd
  chmod 600 secrets/registry_htpasswd
  echo "identifiants registry crees (secrets/registry_user, secrets/registry_password)"
else
  echo "identifiants registry deja presents"
fi
