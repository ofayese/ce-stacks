# AgentDB Memory Patterns — Integration Plan

## Project

**Repo**: `n8n-agentdb-integration` (Node.js / Express / n8n-as-code)
**Service**: Express REST app, default `localhost:4010`
**Database**: `.agentdb/learning.db` (SQLite via `agentdb` npm package / ruvnet)
**Existing n8n workflow**: `agentdb-learning-loop.workflow.ts` — linear chain `EveryDayTrigger → BuildPayload → LogExperience → TrainModel → GetRecommendation → NotifyDecision`

## Goal

Layer all five AgentDB memory-pattern families onto the existing service. No existing endpoints removed or changed.

| Pattern family | New REST endpoint(s) | API used |
|---|---|---|
| Session memory | `GET/POST /memory/session/:id`, `POST /memory/session/:id/message` | `agentic-flow` session store via reflexion controller |
| Long-term (facts) | `GET /memory/facts?category=`, `POST /memory/facts` | `agentic-flow` reflexion controller |
| Pattern learning | `GET /memory/patterns/:trigger`, `POST /memory/patterns` | `agentic-flow` reflexion controller |
| Hierarchical memory | `POST /memory/hierarchy/:sessionId` | agentDB native HNSW |
| Memory consolidation | `POST /memory/consolidate` | agentDB native batch ops |

---

## 1. Dependencies

### 1a. Already present — no change

```json
"agentic-flow": "^2.0.13",   // brings reasoningbank + 9 learning plugins
"agentdb": "…",             // installed transitively by agentic-flow
"express": "^5.1.0",
"ulid": "^3.0.1",
"cors": "^2.8.5",
```

### 1b. No new packages required

All patterns use `agentic-flow` (already in `dependencies`). `agentic-flow` v2 is 100 % backward-compatible with `agentdb` v1 APIs.

### 1c. New env vars — add to `.env.example`

```dotenv
AGENTDB_PATH=.agentdb/learning.db          # existing
AGENTDB_DIMENSION=384                      # existing alignment with makeEmbedding()
AGENTDB_QUANTIZATION=scalar                # NEW — 4× memory reduction (binary | scalar | product | none)
AGENTDB_CACHE_SIZE=1000                    # NEW — in-memory LRU cache, <1 ms lookup
AGENTDB_HNSW_M=16                          # NEW — HNSW graph width (speed vs accuracy trade-off)
AGENTDB_HNSW_EF_SEARCH=100                 # NEW — HNSW search beam
AGENTDB_CONSOLIDATE_INTERVAL_H=24          # NEW — throttle consolidation to ≤1×/24 h
```

---

## 2. Library layer — new file `src/memory-patterns.ts`

Ship five concise classes. Each embeds `getDB()` singleton pointing at the same DB so no new connections are opened.

### 2a. SessionMemory

```ts
import { AgentDB } from 'agentdb';
import { ulid } from 'ulid';

export class SessionMemory {
  constructor(private db: AgentDB, public readonly sessionId?: string) {}
  id(): string { return this.sessionId ?? ulid(); }

  async store(role: 'user'|'assistant'|'system', content: string) {
    const id = ulid();
    const c = this.db.getController('reflexion');
    await c.storeEpisode({ sessionId: id, task: this.id(), input: content, output: content, reward: 0, success: true, metadata: { role, ts: Date.now() } });
    return id;
  }

  async getHistory(limit = 20) {
    const c = this.db.getController('reflexion');
    return (await c.retrieveRelevant({ task: this.id(), k: limit }))
      .map(r => ({ role: r.metadata?.role, content: r.output ?? r.input, ts: r.metadata?.ts }));
  }
}
```

### 2b. LongTermMemory

```ts
export class LongTermMemory {
  constructor(private db: AgentDB) {}

  async storeFact(category: string, key: string, value: unknown, confidence = 1.0) {
    const id = ulid();
    const c  = this.db.getController('reflexion');
    await c.storeEpisode({
      sessionId: id, task: `fact:${category}:${key}`,
      input: JSON.stringify(value), output: JSON.stringify(value),
      reward: confidence, success: confidence > 0.5,
      metadata: { category, key, type: 'fact' },
    });
    return id;
  }

  async getFacts(category?: string) {
    const c = this.db.getController('reflexion');
    const prefix = category ? `fact:${category}` : 'fact:';
    const all = await c.retrieveRelevant({ task: prefix, k: 500 });
    return all
      .filter((r: any) => r.metadata?.type === 'fact')
      .filter((r: any) => !category || r.metadata?.category === category)
      .map((r: any) => ({ category: r.metadata.category, key: r.metadata.key, value: safeParse(r.input), confidence: r.reward }));
  }
}
function safeParse(s: string) { try { return JSON.parse(s); } catch { return s; } }
```

### 2c. PatternLearning

```ts
export class PatternLearning {
  constructor(private db: AgentDB) {}

  async store(trigger: string, correctAction: string, success = true, context?: Record<string, unknown>) {
    const id = ulid();
    const c  = this.db.getController('reflexion');
    await c.storeEpisode({
      sessionId: id, task: trigger, input: JSON.stringify(context ?? {}),
      output: correctAction, reward: success ? 1.0 : -1.0, success,
      metadata: { pattern: true, trigger },
    });
  }

  async match(trigger: string, k = 5) {
    const c = this.db.getController('reflexion');
    return c.retrieveRelevant({ task: trigger, k });
  }
}
```

### 2d. HierarchicalMemory

```ts
export class HierarchicalMemory {
  constructor(private db: AgentDB, private windowSize = 10) {}

  async organize(sessionId: string) {
    const c = this.db.getController('reflexion');
    const all = (await c.retrieveRelevant({ task: sessionId, k: 1_000 })) ?? [];
    const newest = [...all].reverse();

    return {
      immediate: newest.slice(0, this.windowSize),
      shortTerm: newest.slice(0, 50),
      longTerm:  newest.filter((r: any) => (r.reward ?? 0) > 0.8).slice(0, 100),
      semantic:  all,   // full history — searchable by HNSW
    };
  }
}
```

### 2e. MemoryConsolidation

```ts
export class MemoryConsolidation {
  constructor(private db: AgentDB, private minScore = 0.5) {}

  async run(opts: { strategy?: 'importance'; maxPatterns?: number; minScore?: number }) {
    const c    = this.db.getController('reflexion');
    const all  = (await c.retrieveRelevant({ task: '', k: 10_000 })) ?? [];
    const min  = opts.minScore ?? this.minScore;
    const kept = all.filter((r: any) => (r.reward ?? 0) >= min);
    const final = kept.slice(0, opts.maxPatterns ?? 10_000);
    // prune() not yet exposed in agentic-flow v2 — log retention count for operator visibility
    return { totalScanned: all.length, retained: final.length, strategy: opts.strategy ?? 'importance' };
  }
}
```

---

## 3. REST endpoint handlers — `src/server.ts`

Insert block *after* `getDB()` definition and *before* `process.on('SIGINT')`.

```ts
// ─── memory-patterns imports ───────────────────────────────────────────
import { SessionMemory, LongTermMemory, PatternLearning, HierarchicalMemory, MemoryConsolidation } from './memory-patterns.js';

// ─── helpers ──────────────────────────────────────────────────────────
const withDB = <T>(fn: (db: AgentDB) => Promise<T>): express.RequestHandler =>
  async (req, res) => {
    try { res.json(ok(await fn(await getDB()))); }
    catch (e: any) { res.status(500).json(err(e.message ?? e)); }
  };

// ─── Session memory ──────────────────────────────────────────────────
app.get(    '/memory/session/:sessionId',     withDB(db => new SessionMemory(db, req.params.sessionId).getHistory(+req.query.limit ?? 20)));
app.post(   '/memory/session/:sessionId',                          async (req, res) => {
  try {
    const role    = req.body?.role    ?? 'user';
    const content = req.body?.content ?? '';
    const id = await new SessionMemory(await getDB(), req.params.sessionId).store(role, content);
    res.status(201).json(ok({ id }));
  } catch (e: any) { res.status(500).json(err(e.message)); }
});

// ─── Long-term facts ────────────────────────────────────────────────
app.get(    '/memory/facts',          withDB(async db =>
  (await new LongTermMemory(db).getFacts(req.query.category as string | undefined))));
app.post(   '/memory/facts',           async (req, res) => {
  try {
    const { category, key, value, confidence } = req.body ?? {};
    const id = await new LongTermMemory(await getDB()).storeFact(category, key, value, confidence ?? 1);
    res.status(201).json(ok({ id }));
  } catch (e: any) { res.status(500).json(err(e.message)); }
});

// ─── Pattern learning ──────────────────────────────────────────────
app.get(    '/memory/patterns/:trigger',  withDB(async db =>
  await new PatternLearning(db).match(req.params.trigger, +req.query.k ?? 5)));
app.post(   '/memory/patterns',           async (req, res) => {
  try {
    const { trigger, action, success, context } = req.body ?? {};
    const id = await new PatternLearning(await getDB()).store(trigger, action, success ?? true, context);
    res.status(201).json(ok({ id }));
  } catch (e: any) { res.status(500).json(err(e.message)); }
});

// ─── Hierarchical memory ───────────────────────────────────────────
app.post(   '/memory/hierarchy/:sessionId',  withDB(async db =>
  await new HierarchicalMemory(db).organize(req.params.sessionId)));

// ─── Memory consolidation ───────────────────────────────────────────
app.post(   '/memory/consolidate', async (req, res) => {
  try {
    const result = await new MemoryConsolidation(await getDB()).run(
      req.body ?? { strategy: 'importance', scoreKey: 'enrichment_score' }
    );
    res.json(ok(result));
  } catch (e: any) { res.status(500).json(err(e.message)); }
});
```

`/health` enriched:
```ts
app.get('/health', (_req, res) => {
  res.json({ ...ok({ service: 'n8n-agentdb-learning', status: 'ok', port: PORT }),
    features: { sessionMemory: true, facts: true, patterns: true, hierarchy: true, consolidation: true } });
});
```

---

## 4. n8n workflow — `agentdb-learning-loop.workflow.ts`

Append **4 parallel sub-chains** after the existing `NotifyDecision` node. Each sub-chain starts from `NotifyDecision` (not `EveryDayTrigger`) so they fire on the same cadence as the daily learning run.

### Routing summary (augments existing `defineRouting()`)

```ts
defineRouting() {
  // ── existing linear chain ─────────────────────────────────────────
  this.EveryDayTrigger.out(0).to(this.BuildPayload.in(0));
  this.BuildPayload.out(0).to(this.LogExperience.in(0));
  this.LogExperience.out(0).to(this.TrainModel.in(0));
  this.TrainModel.out(0).to(this.GetRecommendation.in(0));
  this.GetRecommendation.out(0).to(this.NotifyDecision.in(0));

  // ── new parallel sub-chains ───────────────────────────────────────;
  this.NotifyDecision.out(0).to(this.StoreSessionMessage.in(0));
  this.NotifyDecision.out(0).to(this.StoreUserFact.in(0));
  this.NotifyDecision.out(0).to(this.LogNewPattern.in(0));
  this.NotifyDecision.out(0).to(this.CheckHierarchySkip.in(0));

  // ── formatters ────────────────────────────────────────────────────;
  this.StoreSessionMessage.out(0).to(this.FormatSessionSummary.in(0));
  this.StoreUserFact.out(0).to(this.FormatFactNotice.in(0));
  this.LogNewPattern.out(0).to(this.FormatPatternLog.in(0));
  this.CheckHierarchySkip.out(0).to(this.ReviewSessionHierarchy.in(0));
  this.ReviewSessionHierarchy.out(0).to(this.FormatHierarchySummary.in(0));
}
```

### New node definitions (workflow annotation)

```
[Filter] Check Hierarchy Skip            code@2   → passes _skipHierarchy flag
[HTTP Request] Store Session Message     n8n-nodes-base.httpRequest@4.4  POST /memory/session/{{ $json.date }}/message
[Code]         Format Session Summary    n8n-nodes-base.code@2
[HTTP Request] Store User Fact           n8n-nodes-base.httpRequest@4.4  POST /memory/facts
[Code]         Format Fact Notice        n8n-nodes-base.code@2
[HTTP Request] Log New Pattern           n8n-nodes-base.httpRequest@4.4  POST /memory/patterns
[Code]         Format Pattern Log        n8n-nodes-base.code@2
[HTTP Request] Review Session Hierarchy  n8n-nodes-base.httpRequest@4.4  POST /memory/hierarchy/{{ $json.date }}
[Code]         Format Hierarchy Summary  n8n-nodes-base.code@2
```

**Check Hierarchy Skip** — Code node execs once per run; routes via n8n `if` output:

```js
// Check Hierarchy Skip
const skip = ($json.learnedReward ?? 0) < 0.5 && Math.random() < 0.8;
return [{ json: { ...$json, _skipHierarchy: skip } }];
```

Wiring `CheckHierarchySkip` has **two** outputs:
- output `0` → `true` → `ReviewSessionHierarchy`
- output `1` → `false` → no-op

---

## 5. Implementation order

| # | File | What | Lines |
|---|---|---|---|
| 1 | `src/memory-patterns.ts` | 5 classes: SessionMemory, LongTermMemory, PatternLearning, HierarchicalMemory, MemoryConsolidation | ~200 |
| 2 | `src/server.ts` | 10 new route handlers + import block + health enrichment | ~80 |
| 3 | `agentdb-learning-loop.workflow.ts` | 4 parallel sub-chains + 4 Code format nodes + filter node | ~120 |
| 4 | `.env.example` | Add 4 new env vars | +4 |
| 5 | `README.md` | Memory-patterns section + curl smoke tests + architecture diagram | +80 |
| 6 | Build → test | `npm run build && npm start` + smoke-test all 10 routes | — |

---

## 6. Build & verification checklist

```bash
npm install
npm run build
npm start                        # starts on :4010

# ─── existing endpoints still work ───────────────────────
curl http://localhost:4010/health
curl -X POST http://localhost:4010/experience \
     -H 'Content-Type: application/json' \
     -d '{"domain":"test","state":"s=1","action":"run","reward":1}'
curl -X POST http://localhost:4010/train
curl 'http://localhost:4010/recommend?state=s=1&k=5'

# ─── new memory-pattern endpoints ─────────────────────────
SESSION=v1
curl -X POST http://localhost:4010/memory/session/$SESSION/message \
     -H 'Content-Type: application/json' \
     -d '{"role":"user","content":"hello"}'
curl http://localhost:4010/memory/session/$SESSION
curl -X POST http://localhost:4010/memory/facts \
     -H 'Content-Type: application/json' \
     -d '{"category":"prefs","key":"theme","value":"dark","confidence":1}'
curl http://localhost:4010/memory/facts?category=prefs
curl http://localhost:4010/memory/patterns/user_asks_price?k=3
curl -X POST http://localhost:4010/memory/patterns \
     -H 'Content-Type: application/json' \
     -d '{"trigger":"user_asks_price","action":"fetch_price","success":true}'
curl -X POST http://localhost:4010/memory/hierarchy/$SESSION
curl -X POST http://localhost:4010/memory/consolidate \
     -H 'Content-Type: application/json' \
     -d '{"strategy":"importance","maxPatterns":5000,"minScore":0.5}'
```

---

## 7. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `agentic-flow` surface grows unexpectedly between minor bumps | Low | Low | Pin `"agentic-flow": "^2.0.13"` until v2.1 ships |
| Consolidation calls `prune()` before it exists in v2 | N/A | Low | Handler only *reports* counts now — no delete path yet |
| HNSW `M=16` too coarse on &lt;100 patterns | Low | Low | Drop to `M=4` in code guard when DB file size &lt; 100 KB on start-up |
| `/memory/consolidate` called faster than once per 24 h | Low | Low | Env var `AGENTDB_CONSOLIDATE_INTERVAL_H` + check timestamp table |
| `/memory/hierarchy` may return &lt;10 `immediate` items on a fresh session | None | Info | Document as expected; not an error |
| n8n workflow node positions may need manual repositioning after merge | Medium | Medium | `npx --yes n8nac workspace status --json` resolves canonical positions |

---

## 8. No database migration required

All new patterns reuse the **same** `agentdb` binary tables (reflexion / episode). Existing `/experience` rows become visible through `/memory/session`, `/memory/hierarchy`, and `/memory/patterns` at 100 % backward-compatibility.

---

## 9. Open questions (flagged for implementation-phase confirmation)

1. **HNSW config guidance**: `M=16 / efSearch=100` is a starting-point. For production HNSW hyperparameter tuning against a representative workload, I recommend measuring recall@k before and after.
2. **`agentic-flow` caching**: the skill says `cacheSize: 1000` → <1ms retrieval. Should the service lazy-initialise this cache on first `getDB()` call or on an explicit `POST /admin/reload-cache`? Answer determines if one more admin endpoint is needed.
3. **Consolidation trigger**: the workflow currently calls `/memory/consolidate` on every daily run. Enable `AGENTDB_CONSOLIDATE_INTERVAL_H` guard or move to a dedicated weekly cron sub-workflow?
4. **Docker-scale dimension**: `vectorDimension: 384` matches the xlm-roberta embedding model. If future agents switch to `text-embedding-3-small` (1536-d), do we re-index from scratch or run dual-dimension stores?
