# Open WebUI setup for a small thinking model

Open WebUI settings live in its database (`data/open-webui/webui.db`), not in this repo. On a fresh `data/`, `docker-compose.yml` pre-seeds most of them (web search via SearXNG, OpenAI off, community sharing off, task model and default model `4b-fast`, follow-ups and tags off, context compaction). The `4b-fast` preset itself can only be created in the UI. This page lists everything needed to get fast, working, private web search with a small local model (tested with `jaahas/qwen3.5-uncensored:4b` on an M1 with 16 GB; full fresh-install run verified 2026-10-24).

## Why this is needed

With default settings, a small reasoning model is slow and web search silently does nothing:

1. **Thinking on every background task.** Open WebUI calls the chat model for web-search query generation, title, tags and follow-ups. A thinking model spends ~1200 tokens reasoning on each one. Measured on the 4B model (~12 tok/s): query generation takes **~100 s with thinking, ~3 s without**. Ollama runs the calls one after another, and the reasoning is hidden in the UI, so the chat just hangs for minutes before the first token.
2. **Native function calling.** In the default mode, web search is exposed as a tool the model has to call by itself. A 4B model does not, so it answers without sources (often claiming it only has calendar or reminder tools). **Legacy** mode makes Open WebUI search first and paste the results into the prompt.

## Steps

Fresh install (empty `data/`): run `make setup` (installs Ollama, pulls the model, downloads the embedding model once, starts everything), then create the admin account at http://localhost:3000 (the first account becomes the admin). Only step 1 is required; steps 2, 3, 3a and 3b are already applied from `docker-compose.yml` and only need checking. On an existing database the env vars are ignored, so do all steps.

### 1. Create the `4b-fast` preset (required)

1. **Workspace → Models → Create** (`/workspace/models/create`).
2. **Model Name**: `4b-fast`. The Model ID below it must also be `4b-fast` (it is what `TASK_MODEL` and `DEFAULT_MODELS` in `docker-compose.yml` point to).
3. **Base Model (From)**: `jaahas/qwen3.5-uncensored:4b`.
4. Expand **Advanced Params** and set:
   - **think (Ollama)** → `Off`. The value cycles on each click: `Default → On → Custom → Off` (three clicks). `Custom` shows a text field; keep clicking until it reads `Off`.
   - **Function Calling** → `Legacy`. Cycles `Default → Native → Legacy` (two clicks).
   - **num_ctx (Ollama)** → `16384`. Clicking `Default` shows a slider with a number field preset to `2048`; type `16384` into the number field (do not save `2048`, that halves Ollama's default 4096). Costs only ~0.2-0.4 GB extra RAM with this model; check with `make ollama-ps` (CONTEXT column).
5. **Default Features** → turn on **Web Search** ("Start enabled in new chats").
6. **Save & Create**.

To change it later: **Workspace → Models → 4b-fast** (edit), then **Save & Update**.

### 1b. Optional `4b-think` preset (same model, thinking on)

For harder questions where a slower, reasoned answer is worth it. **Workspace → Models → `⋯` next to 4b-fast → Clone**, set Model Name and Model ID to `4b-think`, switch **think (Ollama)** to `On` (from `Off`: `Default → On`), **Save & Create**. Everything else (Legacy function calling, `num_ctx` 16384, web search on by default) is copied. Background tasks still run on `4b-fast`, so only the answer itself is slow: on a 16 GB M1 a simple math question took over 3 minutes of "Thinking…" before the first word.

Context with thinking: the reasoning of the answer being written counts against `num_ctx` (history + search results + reasoning + answer must fit in 16384), but reasoning from earlier answers is dropped. Measured: the same history was 90 prompt tokens with or without ~2000 tokens of earlier reasoning (Open WebUI passes it to Ollama as `thinking`, and Ollama's `qwen3.5` renderer discards it).

Don't chat with the bare `jaahas/qwen3.5-uncensored:4b`: it thinks, has a 4096-token context and uses native function calling, so web search silently does nothing.

### 2. Background tasks (pre-seeded on a fresh DB)

**Admin Panel → Settings → Interface** (`/admin/settings/interface`):

- **Local Task Model** → `4b-fast`.
- **Follow Up Generation** → off.
- **Tags Generation** → off.
- Leave **Title Generation**, **Retrieval Query Generation** and **Web Search Query Generation** on (they are fast once thinking is off).

Click **Save**.

### 3. Privacy settings (pre-seeded on a fresh DB)

- **Admin Panel → Settings → Connections** (`/admin/settings/connections`): **OpenAI API** → off (saves immediately). Leave **Ollama API** on with `http://host.docker.internal:11434`. Left on, Open WebUI keeps calling `api.openai.com` to list models.
- **Admin Panel → Settings → General** (`/admin/settings/general`): **Community Sharing** → off, then **Save**.
- **Workspace → Models**: delete any preset whose base model is not installed (`⋯ → Delete → Confirm`). Only `4b-fast` should remain.

### 3a. Multilingual embedding model (pre-seeded on a fresh DB)

Web search fetches pages, splits them into chunks, and an embedding model picks the chunks closest to the question; only those reach the chat model. The default `sentence-transformers/all-MiniLM-L6-v2` is English-only and picks the wrong chunks on Polish pages. `intfloat/multilingual-e5-small` (~470 MB, runs locally on CPU) is trained for question→passage retrieval in many languages; on a small Polish test it picked the right passage 6/6 times vs 3/6 (`paraphrase-multilingual-MiniLM-L12-v2` also scored 3/6, `multilingual-e5-base` 6/6 but slower).

- **Admin Panel → Settings → Documents** (`/admin/settings/documents`) → **Embedding Model**: `intfloat/multilingual-e5-small`, click the download icon next to it, then **Save**.
- The model must already be in `data/open-webui/cache` because Open WebUI runs with Hugging Face offline. `make setup` downloads it (only the files sentence-transformers needs, ~0.5 GB; Open WebUI's own download button would fetch the whole ~2.2 GB repo with ONNX/OpenVINO copies, and with `HF_HUB_OFFLINE=1` it can't download at all).
- e5 needs `query: ` / `passage: ` prefixes; they come from `RAG_EMBEDDING_QUERY_PREFIX` / `RAG_EMBEDDING_CONTENT_PREFIX` in `docker-compose.yml` (applied on every start, no UI setting).

### 3b. Context compaction (pre-seeded on a fresh DB)

Long chats would otherwise overflow `num_ctx` 16384, and Ollama silently drops the oldest messages. With compaction on, once a chat passes the token threshold, Open WebUI asks `4b-fast` to summarize the older messages and sends the summary instead of them (the chat in the UI still shows everything). The newest 40% of messages are kept as they are.

**Admin Panel → Settings → Interface** (`/admin/settings/interface`), section **Chat**:

- **Context Compaction** → on.
- **Context Compaction Model** → `4b-fast`.
- **Token Threshold** → `11000`, **Token Cap** → `11000`.

Click **Save**.

- Why 11000 and not 16384: the check runs before web search results are added (~1-3k tokens with 3 results), and the answer and the summary also need room. Keep the threshold at about two thirds of `num_ctx`; if you raise `num_ctx` in the preset, raise both values too.
- The count is the last answer's real token usage reported by Ollama (prompt + answer) plus an estimate of the new message, so it matches what Ollama sees.
- A per-chat threshold can be set in **Chat Controls → Advanced Params → Context Compaction Threshold** (capped by **Token Cap**). Handy for testing: set it to `300` in a temporary chat and send three messages.
- Cost: the summary is an extra generation of up to ~30 s, only when the threshold is crossed. A 4B model may drop details, so important facts are better kept in **Settings → Personalization → Memory** or a Knowledge file.
- Check in the logs: `docker logs open-webui 2>&1 | grep "Compacted chat context"`.

### 4. Chat

- New chats open with **4b-fast** and Web Search already on (globe icon highlighted next to `+`). If not, pick the model and toggle Web Search via the sparkles icon.
- A **Retrieved N sources** line above the answer confirms that the search ran. If it is missing, the search did not run.

The search engine side (SearXNG, Brave only) comes from `config/searxng/settings.yml` and needs no UI setup.

## Verify

Expected after the steps above, for a question with web search on: sources line after ~10-15 s, first tokens of the answer after ~25 s (up to ~45 s on the first question, while Ollama loads the model).

Check the saved settings read-only (does not touch chats):

```bash
docker exec -i open-webui python - <<'EOF'
import sqlite3, json
c = sqlite3.connect('file:/app/backend/data/webui.db?mode=ro', uri=True)
for k, v in c.execute("select key, value from config where key in ('task.model.default','ui.default_models','rag.embedding_model','task.follow_up.enable','task.tags.enable','openai.enable','ui.enable_community_sharing','web.search.enable','web.search.engine','chat.context_compaction.enable','chat.context_compaction.model','chat.context_compaction.token_threshold') order by key"):
    print(k, "=", v)
for mid, p, m in c.execute("select id, params, meta from model order by id"):
    print("model", mid, json.loads(p), "default features:", json.loads(m).get("defaultFeatureIds"))
EOF
```

Expected: `task.model.default = "4b-fast"`, `ui.default_models = "4b-fast"`, `rag.embedding_model = "intfloat/multilingual-e5-small"`, `web.search.enable = true`, `web.search.engine = "searxng"`, `task.follow_up.enable = false`, `task.tags.enable = false`, `openai.enable = false`, `ui.enable_community_sharing = false`, `chat.context_compaction.enable = true`, `chat.context_compaction.model = "4b-fast"`, `chat.context_compaction.token_threshold = 11000`, the model params contain `'think': False`, `'function_calling': 'legacy'` and `'num_ctx': 16384`, and default features `['web_search']`.

Check that SearXNG only has Brave engines:

```bash
docker exec open-webui python -c "import urllib.request,json; c=json.load(urllib.request.urlopen('http://searxng:8080/config')); print(sorted(e['name'] for e in c['engines'] if e.get('enabled')))"
```

Expected: `['brave', 'brave.images', 'brave.news', 'brave.videos']`.

Time the slow step directly against Ollama (the web search query generation, with and without thinking):

```bash
curl -s http://localhost:11434/api/chat -d '{"model":"jaahas/qwen3.5-uncensored:4b","stream":false,"think":false,"messages":[{"role":"user","content":"Return JSON {\"queries\": [...]} with a web search query for: weather in Warsaw today"}]}' | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['eval_count'], 'tokens,', r['total_duration']/1e9, 's')"
```

Drop `"think":false` to see the thinking-mode cost. `total_duration` includes model load time, so after ~5 minutes of idle (Ollama unloads the model) the first call is much slower; run it twice and read the second result.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Long silence before the answer, nothing in the logs | A background task is still thinking. Check that **Local Task Model** is the non-thinking preset. |
| Answer ignores the web, mentions calendar or reminder tools | **Function Calling** is not `Legacy`, or Web Search is off in this chat. |
| No "Retrieved N sources" line | Web Search toggle is off in this chat, or SearXNG returns 403 (see README: JSON format). |
| `ollama ps` shows `Stopping...` and the model reloads | Another model or different options were requested; keep chat and task model on the same base model. |
| Sources are from the wrong date | Search result quality and model size, not configuration. |
| Source is right but the answer says the data is missing (e.g. train prices) | The page loads that data with JavaScript; the web loader only sees the static HTML. Not fixable by configuration. |
| Logs flooded with `401` on `/api/tasks/chat/...` and `/api/v1/channels/` (thousands per minute) | A browser tab still open from before a reset (old session, old chat id) retrying in a loop. Reload or close old Open WebUI tabs. |
| No sources at all; `docker compose logs searxng` shows `HTTP Request failed: GET https://search.brave.com/...`, and the SearXNG JSON has `unresponsive_engines: [['brave', 'Suspended: too many requests']]` | Brave rate-limited your IP (many searches in a short time, e.g. while testing). SearXNG then suspends Brave for up to an hour and search returns nothing until then. Wait, or change IP (VPN). |
| Web search disabled on a fresh install | `docker-compose.yml` must use `ENABLE_WEB_SEARCH` / `WEB_SEARCH_ENGINE` (older `ENABLE_RAG_WEB_SEARCH` / `RAG_WEB_SEARCH_ENGINE` names are ignored by current Open WebUI). |

Notes:

- Ollama queues requests, so a test run while a chat is generating looks much slower than it is.
- `ollama ps` shows the context size. Ollama's default is 4096 tokens (a few pages; the whole conversation plus search results must fit, older parts are silently cut). The preset raises it to 16384; the model supports up to 262144.
- Settings are per Open WebUI database. After `make clean`, repeat the fresh-install steps.
- Expected external connections: Hugging Face only once, from `make setup` (a throwaway container), Brave via SearXNG, and the result pages Open WebUI fetches. Nothing else.
