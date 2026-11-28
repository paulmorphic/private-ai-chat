# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Local, private AI chat with web search. LLM runs fully locally via Ollama (native, not Docker), chat UI via Open WebUI (Docker), and private meta-search via SearXNG (Docker).

## Quick Start

```bash
make setup                      # one-time: Ollama (brew), model, .env, embedding model, containers (safe to re-run)
make start / make stop          # daily use
```

Then do the one-time Open WebUI UI setup in `docs/open-webui-setup.md` (see "Rebuild from scratch" below).

Open WebUI at http://localhost:3000

## Essential Commands

| Command | Purpose |
|---|---|
| `make setup` | One-time install, idempotent: checks brew/Docker, installs + starts Ollama, pulls `OLLAMA_MODEL`, creates `.env`, downloads `EMBED_MODEL` via a throwaway `docker compose run` (sentence-transformers, only needed files ~0.5 GB), starts containers, waits for healthy |
| `make start` | Daily start: start Ollama brew service if down, refuse if the model or embedding cache is missing (→ `make setup`), then `make up` |
| `make stop` | Daily stop: `docker compose down` + `ollama stop` the model (frees RAM) |
| `make up` | Start containers (SearXNG + Open WebUI) |
| `make down` | Stop containers |
| `make restart` | Restart containers |
| `make logs` | Tail all container logs |
| `make logs-webui` | Tail Open WebUI logs only |
| `make logs-searxng` | Tail SearXNG logs only |
| `make status` | Container status + resource usage |
| `make env` | Create `.env` with random secrets (auto-runs via `make up`) |
| `make backup` | Stops Open WebUI briefly, writes `backups/open-webui-<date>.tar.gz` (`data/open-webui` without `cache/`, plus `.env`; mode 600; `backups/` gitignored), starts it again if it was running |
| `make restore FILE=x` | ⚠️ Asks for `yes`, then `docker compose down`, replaces `data/open-webui` (keeps `cache/`) and `.env` with the backup |
| `make clean` | ⚠️ Asks for `yes`, then `docker compose down -v` + delete `./data` (chats, account, settings, embedding cache) |
| `make uninstall` | ⚠️ Asks for `yes`, then removes containers, images, `./data`, `.env` and the Ollama model (Ollama itself stays) |
| `make ollama-start` | Start Ollama daemon on 127.0.0.1 (not needed if the brew service runs) |
| `make ollama-stop` | `pkill ollama` (the brew service may respawn it; use `brew services stop ollama` to keep it off) |
| `make ollama-pull` | Build `OLLAMA_MODEL` (`qwen3.5-uncensored:9b-q4`): `ollama pull` of `HF_MODEL` (Q4_K_M GGUF on Hugging Face), then `/api/create` from its first `FROM` blob (no vision projector) with `RENDERER`/`PARSER qwen3.5` and Qwen's sampling params, then `ollama rm` of the HF tag. With `HF_MODEL=` a plain `ollama pull OLLAMA_MODEL` |
| `make ollama-list` | List downloaded models |
| `make ollama-rm MODEL=x` | Remove a model |
| `make ollama-ps` | Show models in RAM |
| `make ollama-status` | Check if Ollama is running |

## Architecture

```
┌──────────────┐    http://host.docker.internal:11434    ┌───────────┐
│   Ollama     │◄─────────────────────────────────────────│Open WebUI │
│  (native)    │                                          │ (Docker)  │
│  Apple Metal │                                          │ :3000     │
└──────────────┘                                          └─────┬─────┘
                                                               │
                                                http://searxng:8080
                                                               │
                                                         ┌─────▼─────┐
                                                         │  SearXNG  │
                                                         │ (Docker)  │
                                                         │ :8080     │
                                                         └───────────┘
```

- **Ollama** runs natively on macOS (via Homebrew) so it has Apple Metal GPU access — NOT in Docker
- **Open WebUI** connects to Ollama via `host.docker.internal:11434`
- **SearXNG** is the internal search proxy — Open WebUI sends search queries to it via the internal Docker network
- `config/` is versioned (SearXNG settings); `data/` is gitignored and holds runtime state (Open WebUI DB); `.env` is gitignored and holds secrets

## Key Details

- **Ollama port**: `11434` (native, not in docker-compose) — bound to `127.0.0.1` only. Docker Desktop forwards `host.docker.internal` to the host's localhost, so containers still reach it; do NOT use `OLLAMA_HOST=0.0.0.0` (exposes Ollama to the LAN). Ollama also runs as a brew service (`brew services list`), which binds to localhost by default.
- **Open WebUI port**: `127.0.0.1:3000` (maps to container `8080`), localhost only
- **SearXNG**: internal only (no host port mapping), reached by Open WebUI as `searxng:8080`
- **config/searxng/settings.yml**: SearXNG overrides on top of image defaults (`use_default_settings`) — `json` must stay in `search.formats` for web search to work; only DuckDuckGo engines and `mojeek` kept (`keep_only`; `mojeek` also needs `inactive: false` under `engines:`); metrics off. Mounted read-only; run `docker compose restart searxng` after editing.
- **.env**: `SEARXNG_SECRET` and `WEBUI_SECRET_KEY`, generated by `make env`; template in `.env.example`. Changing `WEBUI_SECRET_KEY` logs everyone out of Open WebUI.
- **data/open-webui/**: Open WebUI state (SQLite DB, uploads, etc.)
- **Makefile**: all targets are phony, no build step needed (everything is pulled as Docker images). macOS-only (`sed -i ''`, brew).
- **Images are pinned** (`open-webui:v0.13.5`, `searxng:2026.11.23-a7163d091`). When upgrading, `make backup` first (Open WebUI migrations are one-way; v0.13.5 moved chat messages into the `chat_message` table, so downgrading needs `make restore`), check renamed env vars in `/app/backend/open_webui/config.py` and rerun the checks in `docs/open-webui-setup.md`.
- **Model**: one model, `OLLAMA_MODEL` in the Makefile (`qwen3.5-uncensored:9b-q4`: HauhauCS uncensored Qwen 3.5 9B, Q4_K_M, a reasoning model, ~6.1 GB in RAM with 16k context). Built locally by `make ollama-pull` from `HF_MODEL` because the Ollama library (`jaahas/qwen3.5-uncensored:9b`) only has Q6_K (7.4 GB, too tight in 16 GB); packaged exactly like the library build (`RENDERER`/`PARSER qwen3.5`), which is what makes Open WebUI's think on/off work. Measurements in `docs/open-webui-setup.md` (Verify). Don't add a second model unless asked: on 16 GB Ollama keeps only one in RAM (switching ~5 s plus the prompt cache), and the task model is global in Open WebUI, so chat, tasks and compaction must all use the same model. In Open WebUI it is used through the `9b-fast` preset (thinking off, Legacy function calling), which is also the task model, compaction model and default model, plus an optional `9b-think` preset (clone of `9b-fast` with think On). The bare base model in the picker is not meant for chatting (thinks, 4096 context, native function calling → no web search).
- **Search engines**: DuckDuckGo and Mojeek via SearXNG; SearXNG sends every query to both. DuckDuckGo alone (one provider per query) was the design until 2026-11-28; Mojeek (UK, own index, no tracking, not Google-backed) was added at the user's request because DDG answered `CAPTCHA` to every query for over an hour on SearXNG 2026.11.23 (searxng/searxng#6986, open; an explicit `language=pl-PL` didn't help). After `docker compose restart searxng` DDG answered again, so a restart is worth trying first next time (SearXNG caches DDG's `vqd` token). Mojeek is `inactive` in the image defaults because it asks for a proof-of-work CAPTCHA (altcha); SearXNG solves it and caches the `chllg` cookie. DDG gets most results from Bing; Microsoft gets the query from DDG, not the IP. Brave was used until 2026-11 and dropped: Brave web now cloaks result URLs as `/go/v1/...` redirects that SearXNG can't resolve, so every URL came out as `http:///go/v1/...` and Open WebUI rejected them all (`All provided URLs were blocked or invalid`); upstream disabled the engine (searxng/searxng#6967). DDG needs SearXNG ≥ 2026.11.15 (firefox impersonation, searxng/searxng#6946); older images get `CAPTCHA` for every query. Wikipedia/Wikidata were dropped (queried on every search, rarely useful, rate-limited). Don't add other engines unless asked; never add Google or Google-backed engines (e.g. Startpage). If DDG answers `CAPTCHA` or `too many requests`, it rate-limited the IP: a few queries within seconds are enough (e.g. two quick test rounds of 3), and the block lasted over 5 minutes; wait, and test with single queries spaced out. SearXNG `outgoing.request_timeout` is 6 s (default 3 s timed out on DDG).
- **Open WebUI update check**: `ENABLE_VERSION_UPDATE_CHECK=true` (plain env, read on every start) on purpose — the "new version" banner is one anonymous GET to `api.github.com/repos/open-webui/open-webui/releases/latest`, no chat data; kept so security releases get noticed. `openwebui.com` → `127.0.0.1` in `extra_hosts` blocks only the bare domain (not the update check, not `api.openwebui.com`, which is only called with a license key or `CUSTOM_NAME`)
- **Open WebUI env in docker-compose.yml**: `ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE=searxng` (the old `ENABLE_RAG_WEB_SEARCH` / `RAG_WEB_SEARCH_ENGINE` names are ignored), `ENABLE_OPENAI_API=false`, `ENABLE_COMMUNITY_SHARING=false`, `ENABLE_AUTOMATIONS` / `ENABLE_AUTOMATION_WEBHOOKS=false` (v0.13 scheduled tasks and webhook trigger URLs, on by default, unused here), `TASK_MODEL` / `DEFAULT_MODELS=9b-fast`, follow-ups and tags off, `WEB_SEARCH_CONCURRENT_REQUESTS=1` and `QUERY_GENERATION_PROMPT_TEMPLATE` (multi-line `|-` list item; exactly one search query per question instead of the default 1-3 sent in parallel, which made DuckDuckGo answer CAPTCHA; stored as `task.query.prompt_template`), context compaction on (`ENABLE_CONTEXT_COMPACTION`, `CONTEXT_COMPACTION_MODEL=9b-fast`, `CONTEXT_COMPACTION_TOKEN_THRESHOLD=11000`: built into Open WebUI, summarizes older messages once a chat passes ~2/3 of `num_ctx`; the check runs before web search results are added, so keep headroom; Token Cap in the UI = threshold), `RAG_EMBEDDING_MODEL=intfloat/multilingual-e5-small` (multilingual; the default all-MiniLM is English-only). `RAG_EMBEDDING_QUERY_PREFIX` / `RAG_EMBEDDING_CONTENT_PREFIX` (`query: ` / `passage: `, required by e5, quoted in YAML to keep the trailing space) are, since v0.12.5, stored settings too (`rag.embedding_query_prefix` / `rag.embedding_content_prefix`, Admin Settings > Documents), seeded from env when missing in the DB (that is how the v0.12.4 → v0.12.5 upgrade picked them up). All of these are only applied when the DB is created; on an existing DB change them in the UI. Check variable names against `/app/backend/open_webui/config.py` in the container after upgrades. `HF_HUB_OFFLINE=${HF_HUB_OFFLINE:-1}` (embedding model cached in `data/open-webui/cache`). Telemetry (`ANONYMIZED_TELEMETRY`, `DO_NOT_TRACK`, `SCARF_NO_ANALYTICS`) is already off by image default.
- **Open WebUI settings live in `data/open-webui/webui.db`**, not in the repo. Key/value table `config` (e.g. `task.model.default`, `openai.enable`), presets in table `model` (`params` JSON). Read them with `sqlite3 ... ?mode=ro` via `docker exec -i open-webui python`; never read the `chat` table (private chats).

## Rebuild from scratch (for agents)

After `make clean`, a new machine, or a fresh `data/`:

0. Before `make clean` (or deleting `data/`, or changing `WEBUI_SECRET_KEY`), ask the user to close all Open WebUI browser tabs. A tab with a stale session retries in a tight loop (~18k `401` requests/min on `/api/tasks/chat/...`) until it is closed or reloaded.

1. Make sure Homebrew and Docker Desktop are installed and Docker is running.
2. `make setup` (installs/starts Ollama, downloads and builds the model, creates `.env`, downloads the embedding model once, starts the containers). Don't use Open WebUI's own embedding download button: it fetches the full ~2.2 GB repo and can't work with `HF_HUB_OFFLINE=1`.
3. The user creates the admin account at http://localhost:3000 and logs in. Never type the user's password; ask them to log in (Claude in Chrome can do the rest).
4. Create the `9b-fast` preset in the UI (e.g. via Claude in Chrome), step 1 of `docs/open-webui-setup.md`: Model ID `9b-fast`, base `qwen3.5-uncensored:9b-q4`, think Off, Function Calling Legacy, num_ctx 16384, Default Features → Web Search. Everything else (web search, task model, default model, follow-ups/tags off, OpenAI off, community sharing off, automations off, context compaction) is pre-seeded from `docker-compose.yml` on a fresh DB; on an existing DB do steps 2-3b too.
5. Verify: run the read-only DB check and the SearXNG engine check from `docs/open-webui-setup.md` (expect the DuckDuckGo engines and `mojeek`); ask a question in a new `9b-fast` chat with Web Search on and expect a "Retrieved N sources" line and an answer within about a minute; `ollama ps` must show only `qwen3.5-uncensored:9b-q4`; `curl -m 3 http://<LAN IP>:3000` and `:11434` must fail (localhost only).
