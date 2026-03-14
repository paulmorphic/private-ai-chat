.DEFAULT_GOAL := help

# Model used by this stack (override: make ollama-pull OLLAMA_MODEL=...). A non-thinking
# preset of it is created in Open WebUI, see docs/open-webui-setup.md
OLLAMA_MODEL ?= jaahas/qwen3.5-uncensored:4b

# Embedding model, must match RAG_EMBEDDING_MODEL in docker-compose.yml. `make setup`
# downloads it once through sentence-transformers, which fetches only the files it needs
# (~0.5 GB instead of the full ~2.2 GB repo with ONNX/OpenVINO copies);
# Open WebUI itself always runs with Hugging Face offline.
EMBED_MODEL := intfloat/multilingual-e5-small
EMBED_CACHE := data/open-webui/cache/embedding/models/models--$(subst /,--,$(EMBED_MODEL))

# ─────────────────────────────────────────
# private-ai-chat
# ─────────────────────────────────────────

.PHONY: help setup start stop uninstall ollama-up wait-webui env up down restart logs logs-webui logs-searxng status ollama-start ollama-stop ollama-list ollama-pull ollama-rm ollama-ps clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

setup: ## One-time install: Ollama, the model, first start (safe to re-run)
	@echo "→ Checking requirements"
	@command -v brew >/dev/null 2>&1 || { echo "✗ Homebrew not found. Install it from https://brew.sh, then run make setup again."; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo "✗ Docker not found. Install Docker Desktop (https://www.docker.com/products/docker-desktop/), then run make setup again."; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "✗ Docker is not running. Start Docker Desktop, then run make setup again."; exit 1; }
	@command -v ollama >/dev/null 2>&1 || { echo "→ Installing Ollama"; brew install ollama; }
	@$(MAKE) --no-print-directory ollama-up
	@if ollama list | awk 'NR>1 {print $$1}' | grep -qxF "$(OLLAMA_MODEL)"; then \
		echo "✓ Model $(OLLAMA_MODEL) already pulled"; \
	else \
		echo "→ Pulling $(OLLAMA_MODEL) (~3.5 GB)"; ollama pull $(OLLAMA_MODEL); \
	fi
	@$(MAKE) --no-print-directory env
	@if [ -d "$(EMBED_CACHE)" ]; then \
		echo "✓ Embedding model $(EMBED_MODEL) already downloaded"; \
	else \
		echo "→ Downloading embedding model $(EMBED_MODEL) from Hugging Face (once, ~0.5 GB)"; \
		docker compose run --rm --no-deps -e HF_HUB_OFFLINE=0 --entrypoint python open-webui -c \
			"from sentence_transformers import SentenceTransformer; SentenceTransformer('$(EMBED_MODEL)', cache_folder='/app/backend/data/cache/embedding/models', device='cpu')" \
			|| { echo "✗ Embedding model download failed"; exit 1; }; \
		docker compose restart open-webui >/dev/null 2>&1 || true; \
	fi
	@$(MAKE) --no-print-directory up
	@$(MAKE) --no-print-directory wait-webui
	@echo ""
	@echo "✓ Setup done. Finish in the browser (one time, ~2 minutes):"
	@echo "  1. Open http://localhost:3000 and create your account (the first one becomes the admin)"
	@echo "  2. Create the 4b-fast preset: docs/open-webui-setup.md, step 1"
	@echo "  Daily use from now on: make start / make stop"

start: ## Start work: make sure Ollama runs, then start the containers
	@$(MAKE) --no-print-directory ollama-up
	@ollama list | awk 'NR>1 {print $$1}' | grep -qxF "$(OLLAMA_MODEL)" || { echo "✗ Model $(OLLAMA_MODEL) not found. Run make setup first."; exit 1; }
	@[ -d "$(EMBED_CACHE)" ] || { echo "✗ Embedding model not downloaded yet. Run make setup first."; exit 1; }
	@$(MAKE) --no-print-directory up
	@echo "✓ Open WebUI: http://localhost:3000 (the model loads on the first question)"

stop: ## Stop work: stop the containers and unload the model from RAM
	docker compose down
	@ollama stop $(OLLAMA_MODEL) 2>/dev/null || true
	@echo "✓ Containers stopped, model unloaded (Ollama itself idles at ~15 MB; quit Docker Desktop to free its VM)"

ollama-up: # Start the Ollama brew service if it is down and wait until it answers
	@curl -s http://localhost:11434/ > /dev/null || brew services start ollama
	@for i in $$(seq 1 20); do curl -s http://localhost:11434/ > /dev/null && exit 0; sleep 1; done; \
		echo "✗ Ollama did not start. Check: brew services list"; exit 1

wait-webui: # Wait until the Open WebUI container reports healthy (first start can take a few minutes)
	@echo "→ Waiting for Open WebUI to be ready"
	@for i in $$(seq 1 120); do \
		[ "$$(docker inspect -f '{{.State.Health.Status}}' open-webui 2>/dev/null)" = healthy ] && exit 0; sleep 5; \
	done; echo "✗ Open WebUI is not healthy after 10 minutes. Check: make logs-webui"; exit 1

env: ## Create .env with random secrets if it does not exist
	@if [ -f .env ]; then \
		echo "✓ .env already exists"; \
	else \
		cp .env.example .env; \
		sed -i '' "s|^SEARXNG_SECRET=.*|SEARXNG_SECRET=$$(openssl rand -hex 32)|" .env; \
		sed -i '' "s|^WEBUI_SECRET_KEY=.*|WEBUI_SECRET_KEY=$$(openssl rand -hex 32)|" .env; \
		echo "✓ Created .env with random secrets"; \
	fi

up: env ## Start all containers (SearXNG + Open WebUI)
	docker compose up -d

down: ## Stop all containers
	docker compose down

restart: ## Restart all containers
	docker compose restart

logs: ## Follow logs from all containers
	docker compose logs -f

logs-webui: ## Follow logs from Open WebUI only
	docker compose logs -f open-webui

logs-searxng: ## Follow logs from SearXNG only
	docker compose logs -f searxng

status: ## Show running containers and resource usage
	docker compose ps
	@echo ""
	docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

# ─────────────────────────────────────────
# Ollama (native, not Docker)
# ─────────────────────────────────────────

ollama-start: ## Start Ollama in background (native, localhost only; Docker Desktop reaches it via host.docker.internal)
	OLLAMA_HOST=127.0.0.1:11434 ollama serve &

ollama-stop: ## Stop Ollama
	pkill ollama

ollama-list: ## List downloaded models
	ollama list

ollama-pull: ## Download the model ($(OLLAMA_MODEL))
	ollama pull $(OLLAMA_MODEL)

ollama-rm: ## Remove a model (usage: make ollama-rm MODEL=model-name)
	ollama rm $(MODEL)

ollama-ps: ## Show models currently loaded in RAM
	ollama ps

ollama-status: ## Check if Ollama is running and reachable
	@curl -s http://localhost:11434/ > /dev/null && echo "✓ Ollama is up" || echo "✗ Ollama is down"
	@pgrep -l ollama || echo "✗ Ollama process not found"

# ─────────────────────────────────────────
# Maintenance
# ─────────────────────────────────────────

clean: ## Delete all local data: chats, account, settings (CAUTION). Keeps images and the model
	@echo "Close all Open WebUI browser tabs first (a stale tab retries in a loop)."
	@read -p "Delete ./data with all chats, the account and settings? Type yes: " ans && [ "$$ans" = yes ] || { echo "Aborted."; exit 1; }
	docker compose down -v
	rm -rf ./data
	@echo "✓ Data deleted. Next start: make setup"

uninstall: ## Remove everything this project installed: containers, images, data, .env, the model
	@echo "Close all Open WebUI browser tabs first (a stale tab retries in a loop)."
	@read -p "Remove containers, images, ./data (all chats), .env and $(OLLAMA_MODEL)? Type yes: " ans && [ "$$ans" = yes ] || { echo "Aborted."; exit 1; }
	docker compose down -v --rmi all
	rm -rf ./data .env
	-ollama rm $(OLLAMA_MODEL)
	@echo "✓ Removed. Ollama itself is still installed; to remove it too:"
	@echo "  brew services stop ollama && brew uninstall ollama"
