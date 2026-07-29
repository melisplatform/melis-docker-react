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
#   make doctor STACK=install    # verify the host bind mounts are really attached
#                                #   (Rancher Desktop/WSL loses them on restart)
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
        proxy-up proxy-down adminer adminer-stop env doctor

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
	@# Drop a sentinel inside the bind-mount source. It can only be visible from
	@# inside a container if the bind is actually live, which is how entrypoint.sh
	@# step 0 proves the mount before touching anything. Best-effort: once the stack
	@# has booted, install/melis is owned by www-data and unwritable from here — by
	@# then composer.json proves the mount just as well, so a failure is harmless.
	@test "$(STACK)" != "install" || touch install/melis/.melis-mount 2>/dev/null || true

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

doctor: ## Check the host bind mounts are really attached in the running containers
	@# On Rancher Desktop/WSL a bind mount is staged by a helper in your WSL distro at
	@# container-CREATE time and is lost on a WSL shutdown / Rancher restart; a container
	@# dockerd brings back on its own then silently sees an EMPTY dir. Each container is
	@# staged INDEPENDENTLY, so php and vite can disagree — check both.
	@# Write the probe from inside the container and look for it on the host: the host
	@# dir is www-data-owned once the stack has booted, so the reverse direction would
	@# fail on permissions rather than on mount state. Comparing st_dev:st_ino does NOT
	@# work — a detached staging dir reports the same inode as the host (verified).
	@# The probe is written with a `for` loop, not `touch /var/www/*/<marker>`: a glob
	@# only expands to paths that ALREADY exist, so that pattern stays literal, the
	@# touch fails and every check reports BROKEN.
	@set -e; \
	case "$(STACK)" in \
	  install)    host="$(CURDIR)/install/melis"; svcs="php vite";; \
	  app/latest) host="$(CURDIR)/.."; svcs="php";; \
	  *) echo "[doctor] $(STACK) keeps its app dir in a named volume — immune, nothing to check."; exit 0;; \
	esac; \
	rc=0; \
	for s in $$svcs; do \
	  c="$$(cd $(STACK) && $(COMPOSE) ps -q $$s 2>/dev/null || true)"; \
	  if [ -z "$$c" ] || [ "$$(docker inspect -f '{{.State.Running}}' $$c 2>/dev/null)" != "true" ]; then \
	    echo "[doctor] $$s: not running — skipped"; continue; fi; \
	  m=".melis-doctor-$$$$"; \
	  docker exec -u root "$$c" sh -c "for d in /var/www/*/; do touch \"\$$d$$m\" 2>/dev/null || true; done" >/dev/null 2>&1 || true; \
	  if [ -e "$$host/$$m" ]; then echo "[doctor] $$s: OK — shares $$host with the host"; \
	  else echo "[doctor] $$s: BROKEN — bind mount detached; the container is NOT looking at $$host"; rc=1; fi; \
	  docker exec -u root "$$c" sh -c "for d in /var/www/*/; do rm -f \"\$$d$$m\"; done" >/dev/null 2>&1 || true; \
	done; \
	if [ $$rc -ne 0 ]; then \
	  echo "[doctor] Your code on the host is fine. Re-create the containers to re-stage the mounts:"; \
	  echo "[doctor]     cd $(STACK) && docker compose down && docker compose up -d"; \
	  exit 1; \
	fi; \
	echo "[doctor] all mounts good."

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
