# Melis Platform — Docker convenience wrapper.
# Thin shortcuts over `docker compose` for the four runnable stacks. Pick a stack
# with STACK=… (default: prebuilt). Examples:
#
#   make up                      # start the pre-built stack (pulls the image)
#   make up STACK=install        # turnkey build (editable code in install/melis)
#   make up-build STACK=fpm      # build + start the nginx + php-fpm stack
#   make logs                    # follow logs of the current stack
#   make shell                   # open a shell in the php container
#   make down                    # stop (keep data)
#   make destroy                 # stop + remove volumes (full reset)
#   make proxy-up / proxy-down   # start/stop the shared local nginx-proxy
#   make up PROXY=1              # start a stack behind the shared proxy
#   make up VITE=1               # add the React (Vite) dev server (prebuilt/fpm;
#                                #   the install stack always starts it)
#   make adminer / make adminer-stop   # web DB client on http://localhost:8082
#
# PHP version is set per stack in its .env (PHP_VERSION=8.3|8.4|8.5) — change it
# there, then `make up-build`.

STACK ?= prebuilt
SERVICE ?= php
# Compose project network the DB sits on (MELIS_CONTAINER_NAME-network; default melis).
NET ?= melis-network

# Opt-in compose overrides: PROXY=1 (shared nginx-proxy), VITE=1 (React dev server).
# They stack: `make up VITE=1 PROXY=1` applies both.
COMPOSE_FILES := -f docker-compose.yml
ifeq ($(PROXY),1)
COMPOSE_FILES += -f docker-compose.proxy.yml
endif
# VITE=1 is a no-op for stacks that already ship the dev server in their base file
# (install/, where it is not optional) — hence the wildcard guard.
ifeq ($(VITE),1)
ifneq ($(wildcard $(STACK)/docker-compose.vite.yml),)
COMPOSE_FILES += -f docker-compose.vite.yml
endif
endif
COMPOSE := docker compose $(COMPOSE_FILES)

# Run a compose command inside the selected stack directory
CC = cd $(STACK) && $(COMPOSE)

.DEFAULT_GOAL := help

.PHONY: help up up-build down destroy restart logs ps shell \
        proxy-up proxy-down adminer adminer-stop env

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Current STACK=$(STACK)  (override: make <target> STACK=install|prebuilt|fpm|app/latest)"

env: ## Create the stack's .env from .env.example if missing
	@test -f $(STACK)/.env || (cp $(STACK)/.env.example $(STACK)/.env && echo "Created $(STACK)/.env")
	@# Pre-create the bind-mount source for the turnkey stack: on Rancher Desktop /
	@# WSL a missing source dir gets staged as SEPARATE empty dirs per container
	@# (php and vite then don't share it, and data silently vanishes on recreate).
	@test "$(STACK)" != "install" || mkdir -p install/melis

up: env ## Start the stack (detached)
	$(CC) up -d

up-build: env ## Build + start the stack (detached)
	$(CC) up -d --build

down: ## Stop the stack (keep data)
	$(CC) down

destroy: ## Stop the stack and remove volumes (full reset)
	$(CC) down -v

restart: ## Restart the stack
	$(CC) restart

logs: ## Follow the stack logs
	$(CC) logs -f

ps: ## Show stack containers
	$(CC) ps

shell: ## Open a shell in the php container
	$(CC) exec $(SERVICE) bash || $(CC) exec $(SERVICE) sh

proxy-up: ## Create the webproxy network + start the shared nginx-proxy
	docker network inspect webproxy >/dev/null 2>&1 || docker network create webproxy
	docker compose -f local-proxy/docker-compose.yml up -d

proxy-down: ## Stop the shared nginx-proxy
	docker compose -f local-proxy/docker-compose.yml down

adminer: ## Start Adminer (web DB client) on http://localhost:8082, on network NET
	docker run --rm -d --name melis-adminer --network $(NET) -p 8082:8080 adminer:4
	@echo "Adminer → http://localhost:8082  (System: MySQL, Server: <MELIS_CONTAINER_NAME>-db)"

adminer-stop: ## Stop Adminer
	-docker rm -f melis-adminer
