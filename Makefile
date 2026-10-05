SHELL    := /bin/bash
REGISTRY ?= registry.local:5000
TAG      ?= v1
HOST     ?= nebula.local

.DEFAULT_GOAL := help
.PHONY: help dev dev-down build edge deploy smoke clean

help: ## Affiche cette aide
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-10s\033[0m %s\n",$$1,$$2}'

dev: ## Lance les 7 services en local, hors Swarm (verification rapide)
	docker compose -f compose.dev.yml up --build -d && docker compose -f compose.dev.yml ps
dev-down: ## Arrete l'environnement local
	docker compose -f compose.dev.yml down
build: ## Construit et pousse les 3 images
	REGISTRY=$(REGISTRY) ./scripts/build-push.sh $(TAG)
edge: ## Deploie le point d'entree Traefik (fourni)
	docker network create --driver overlay --attachable edge_public || true
	docker stack deploy -c swarm/stack.edge.yml edge
deploy: ## Deploie Nebula (votre stack completee)
	REGISTRY=$(REGISTRY) TAG=$(TAG) docker stack deploy \
	  -c swarm/stack.nebula.todo.yml --with-registry-auth nebula
smoke: ## Verifie la chaine complete
	./scripts/smoke.sh $(HOST)
clean: ## Retire la stack
	docker stack rm nebula
