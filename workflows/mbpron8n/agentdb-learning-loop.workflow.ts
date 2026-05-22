import { workflow, node, links } from '@n8n-as-code/transformer';

/*
 * <workflow-map>
 * Workflow : AgentDB Decision Transformer Learning Loop
 * Nodes    : 6  |  Connections: 5
 *
 * NODE INDEX
 * Property name                 Node type          Flags
 * EveryDayTrigger                scheduleTrigger
 * BuildPayload                  code               [Run Once For All Items]
 * LogExperience                 httpRequest        [authentication: none]
 * TrainModel                    httpRequest        [authentication: none]
 * GetRecommendation             httpRequest        [authentication: none]
 * NotifyDecision                code
 *
 * ROUTING MAP
 * EveryDayTrigger
 *   -> BuildPayload -> LogExperience -> TrainModel -> GetRecommendation -> NotifyDecision
 *
 * AI CONNECTIONS
 * </workflow-map>
 *
 * Integration service
 * ───────────────────────────────────────────────────────────────────────────────
 * Repo  : /Users/laolufayese/dev/n8n-agentdb-integration/
 * URL   : http://localhost:4010   (set to real service URL when deployed)
 *
 *   POST /experience
 *     body: { domain?, state, action, reward, next_state?, done?, meta? }
 *
 *   POST /train
 *     body: { domain?, epochs?, batchSize? }
 *
 *   GET  /recommend
 *     ?state=<json-string>&domain=<optional>&k=<optional>
 *
 *   GET  /health
 */

const AGENTDB = { serviceUrl: 'http://localhost:4010' };

@workflow({
  name: 'AgentDB Decision Transformer Learning Loop',
  description:
    'Every 24 h this workflow (1) compresses the past 24 h of execution metrics into a '
    + 'state/action/reward experience tuple, (2) POSTs it to the local AgentDB service for '
    + 'long-term storage, (3) triggers a 50-epoch Decision Transformer training pass, '
    + '(4) asks AgentDB for the best-learned action for today\'s state context, and '
    + '(5) emits a human-readable decision summary as workflow output.',
  active: false,
})
export class AgentdbLearningLoop {
  /* ─────────────────── 1. Daily trigger ───────────────────┐
   * Fires once every 24 h at 04:00 local to start the        │
   * learning cycle.                                           │
   * Map: scheduleTrigger →                                   │
   *   field: 'days' | daysInterval: 1 | triggerAtDay: ['0'] │
   *   triggerAtHour: 4 | triggerAtMinute: 0                  │
   * Valid values per node-info: field is 'days',             │
   *   triggerAtDay accepts '0'..'6' (Sun..Sat, 0=Sunday),   │
   *   triggerAtHour 0..23, triggerAtMinute 0..59.            │ */

  @node({
    name: 'Every-Day Trigger',
    description: 'Fires once every 24 h at 04:00 local to start the learning cycle.',
    type: 'n8n-nodes-base.scheduleTrigger',
    version: 1.3,
    position: [220, 100],
  })
  EveryDayTrigger = {
    rule: {
      interval: [
        {
          field: 'days',
          daysInterval: 1,
          triggerAtDay: ['0'],
          triggerAtHour: 4,
          triggerAtMinute: 0,
          notice: 'Every 24 h · 04:00',
          expression: '',
        },
      ],
    },
  };

  /* ─────────────── 2. Build observation payload ────────────┐
   * Compress last-24-h workflow metrics into a                │
   * state/action/reward tuple for AgentDB logging.            │
   * Replace reward heuristic with a real KPI.                 │ */

  @node({
    name: 'Build Today Payload',
    description:
      'Compresses the last 24 h of workflow metrics into a state/action/reward tuple '
      + 'for AgentDB logging. Inject real metrics and replace the reward placeholder.',
    type: 'n8n-nodes-base.code',
    typeVersion: 2,
    position: [500, 100],
  })
  BuildPayload = {
    language: 'javascript',
    runOnceForAllItems: true,
    jsCode: `// ── Hook your real metrics here ────────────────────────────────────
// const errorRate = $json.allItems.filter(i => i.json.status >= 400).length
//                    / $json.allItems.length;
// const reward    = errorRate < 0.01 ? 1.0 : errorRate < 0.05 ? 0.5 : -1.0;

const today  = new Date().toISOString().slice(0, 10);
const state  = JSON.stringify({ date: today /* , errorRate */ });
const reward = 1.0;                                             // TODO: real signal

return [{
  json: {
    date,          // carried through the flow for NotifyDecision
    state,
    action: 'auto-run',
    reward,
    domain: 'daily-workflow-summary',
  },
}];`,
  };

  /* ─────────────────── 3. Log to AgentDB ──────────────────┐
   * POST state/action/reward → /experience.                   │
   * Each HTTP node: authentication: none, jsonBody uses        │
   *   n8n expression syntax {{ $json.<field> }}.               │ */

  @node({
    name: 'Log Experience to AgentDB',
    description:
      "POSTs today's state/action/reward tuple to the local AgentDB REST service for long-term storage.",
    type: 'n8n-nodes-base.httpRequest',
    version: 4.4,
    position: [780, 100],
  })
  LogExperience = {
    method: 'POST',
    url:    AGENTDB.serviceUrl + '/experience',
    authentication: 'none',
    sendBody: true,
    contentType: 'json',
    jsonBody: {
      domain: '={{ $json.domain }}',
      state:  '={{ $json.state }}',
      action: '={{ $json.action }}',
      reward: '={{ $json.reward }}',
    },
    options: [],
  };

  /* ────────────────────── 4. Train DT ──────────────────────┐
   * Trigger Decision Transformer training pass.                │ */

  @node({
    name: 'Train Decision Transformer',
    description: 'Triggers a 50-epoch training pass on all experiences accumulated so far.',
    type: 'n8n-nodes-base.httpRequest',
    version: 4.4,
    position: [1040, 100],
  })
  TrainModel = {
    method: 'POST',
    url:    AGENTDB.serviceUrl + '/train',
    authentication: 'none',
    sendBody: true,
    contentType: 'json',
    jsonBody: { epochs: 50, batchSize: 32 },
    options: [],
  };

  /* ──────────────────── 5. Recommendation ──────────────────┐
   * Query /recommend with the state from BuildPayload.         │
   * $("Build Today Payload") cross-references by property      │
   * name — not by node display name.                           │ */

  @node({
    name: 'Get Recommended Action',
    description:
      "Queries AgentDB for the best-learned action for today's state context, with similarity scores.",
    type: 'n8n-nodes-base.httpRequest',
    version: 4.4,
    position: [1310, 100],
  })
  GetRecommendation = {
    method: 'GET',
    url:
      AGENTDB.serviceUrl
      + '/recommend?state={{ $("Build Today Payload").item.json.state }}&k=5'
      + '&domain=daily-workflow-summary',
    authentication: 'none',
    sendQuery: true,
    queryParameters: { parameters: [] },
    options: [],
  };

  /* ──────────────────── 6. Decision summary ─────────────────┐
   * Formats the learner's recommendation as workflow output.  │
   * date is sourced from BuildPayload (carried through HTTP   │
   * nodes as the upstream item field).                        │ */

  @node({
    name: 'Decision Summary',
    description:
      "Formats the learner's top recommendation and confidence into a human-readable workflow output.",
    type: 'n8n-nodes-base.code',
    typeVersion: 2,
    position: [1580, 100],
  })
  NotifyDecision = {
    language: 'javascript',
    runOnceForAllItems: true,
    jsCode: `const recommended = $json.data?.recommended || null;
const candidates   = $json.data?.candidates   || [];

const action     = recommended?.action     ?? 'none';
const similarity = recommended?.similarity ?? 0;
const reward     = recommended?.reward     ?? 0;
const n          = candidates.length;

// date comes from BuildPayload, flowed through the HTTP chain
const date = $json.date || new Date().toISOString().slice(0, 10);

const summary = [
  '=== AgentDB Decision Transformer Report ===',
  '  Recommended action : ' + action,
  '  Confidence (sim)   : ' + similarity.toFixed(4),
  '  Learned reward     : ' + reward.toFixed(4),
  '  Candidates checked : ' + n,
  ...candidates.slice(0, 3).map((c, i) =>
    '    #' + (i + 1) + '  action=' + JSON.stringify(c.pattern?.action)
      + '  sim=' + c.similarity.toFixed(4)
  ),
  '  Service OK         : ' + ($json.ok ? 'yes' : 'no'),
]
.join('\\n');

return [{
  json: {
    date,              // ISO date string from BuildPayload
    recommendedAction: action,
    confidence:        similarity,
    learnedReward:     reward,
    candidateCount:    n,
    topCandidates:     candidates.slice(0, 5),
    summary,
  },
}];`,
  };

  /* ─────────────────── Route nodes ────────────────────┐ */
  @links()
  defineRouting() {
    this.EveryDayTrigger.out(0).to(this.BuildPayload.in(0));
    this.BuildPayload.out(0).to(this.LogExperience.in(0));
    this.LogExperience.out(0).to(this.TrainModel.in(0));
    this.TrainModel.out(0).to(this.GetRecommendation.in(0));
    this.GetRecommendation.out(0).to(this.NotifyDecision.in(0));
  }
}
