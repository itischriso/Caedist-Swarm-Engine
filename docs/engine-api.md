# Swarm Engine API

This document specifies the engine's public entry point contract — the operations that an orchestration layer (UI, CLI, REST handler, or daemon) calls to drive the Swarm. It is derived from the reference implementation's orchestration layer and serves as the authoritative interface specification for the Go core.

Every operation below maps to a method in `SwarmManager` (the engine's state machine). The orchestration layer owns no engine logic of its own — it validates user input, assembles parameters, and delegates.

---

## Core Concepts

| Concept | Description |
|---------|-------------|
| **Project** | Top-level namespace for all swarm state. All operations are scoped to a `projectId`. |
| **Participant** | A registered `(model, persona)` pair with a context window allocation. Participants are ephemeral per-dispatch — re-registered each run. |
| **ActionablePlan** | A unit of work: one participant assigned to one context bucket. The engine executes plans; outputs accumulate on the plan record. |
| **ContextBucket** | A write-once content snapshot (a file, a chunk, a domain region). The engine allocates one worker plan per bucket per participant. |
| **Checkpoint** | A named rollover marker. Commits the current generation as the active baseline; prior context is forensically preserved, not discarded. |
| **Harvest** | A structured synthesis pass across completed plans. Clusters buckets by semantic similarity; dispatches a Collapser per cluster. |
| **Artifact** | Output of a Harvest synthesis — promotable (published downstream) or discardable. |

---

## Participant ID Contract

All participant IDs are caller-generated UUIDs (`Guid.NewGuid().ToString()`). The engine treats them as opaque strings.

**Worker name format**: `"{personaRole} ({modelName})"`  
**Collapser name format**: `"[Collapser] {personaRole} ({modelName})"`

These name formats appear in plan labels and collapser output headers — keep them consistent.

---

## Entry Points

### 1. Register Participant

```
registerParticipant(
    participantId : string,   // caller-generated UUID
    name          : string,   // display name (see format above)
    systemPrompt  : string,   // full persona prompt text
    modelName     : string,   // model identifier, opaque to engine
    contextWindow : int,      // token budget (workers: 32000, collapsers: 128000)
    projectId     : int
) → void
```

Call once per `(model, persona)` pair before dispatch. Participants are project-scoped and reusable across dispatch runs within the same project. Re-registering with the same `participantId` is idempotent.

---

### 2. Dispatch Objective (Primary)

```
dispatchSwarmObjective(
    workerParticipantIds : List<string>,  // all registered worker IDs
    collapserParticipantId : string,      // single collapser ID
    objective : string,                   // the question / task
    projectId : int
) → List<int>                             // created plan IDs
```

Creates one `ActionablePlan` per `(worker, contextBucket)` pair, plus one blocked Collapser plan. Returns all created plan IDs. The returned list must be passed to `linkPlansToCheckpoint` immediately after.

**N×M dispatch pattern** — the orchestration layer is responsible for the cross-product:

```
foreach model in selectedModels:
    foreach persona in selectedPersonas:
        participantId = UUID()
        registerParticipant(participantId, "{persona} ({model})", prompt, model, 32000, projectId)
        workerIds.append(participantId)

collapserPartId = UUID()
registerParticipant(collapserPartId, "[Collapser] {collapserPersona} ({collapserModel})", prompt, collapserModel, 128000, projectId)

planIds = dispatchSwarmObjective(workerIds, collapserPartId, objective, projectId)
```

With 3 models and 2 personas, this produces 6 worker plans per bucket plus 1 Collapser plan per bucket-cluster.

---

### 3. Dispatch Follow-Up Generations

```
dispatchFollowUpGenerations(
    workerParticipantIds : List<string>,
    collapserParticipantId : string,
    followUps : Dictionary<int, string>,  // contextBucketId → follow-up objective
    projectId : int
) → List<int>                             // created plan IDs
```

Appends additional objective runs to specific buckets without re-dispatching the full project. `followUps` is a sparse map — only buckets that need a follow-up question are included. Returns plan IDs; append to the same checkpoint link list as the primary dispatch.

**Typical call sequence**:

```
planIds = dispatchSwarmObjective(workerIds, collapserPartId, primaryObjective, projectId)

if followUps.any():
    followUpPlanIds = dispatchFollowUpGenerations(workerIds, collapserPartId, followUps, projectId)
    planIds.addAll(followUpPlanIds)

checkpointId = createSwarmCheckpoint(0, 1, primaryObjective, projectId)
linkPlansToCheckpoint(checkpointId, planIds, projectId)
```

---

### 4. Create Checkpoint

```
createSwarmCheckpoint(
    parentCheckpointId : int,   // 0 for first generation
    generation         : int,   // monotonically increasing (start at 1)
    objective          : string,
    projectId          : int
) → int                         // new checkpointId
```

Creates a checkpoint record in `Pending` state. Does not yet become the active baseline — call `linkPlansToCheckpoint` then later `commitCheckpoint` to complete the rollover.

---

### 5. Link Plans to Checkpoint

```
linkPlansToCheckpoint(
    checkpointId : int,
    planIds      : List<int>,
    projectId    : int
) → void
```

Associates all plans created in this dispatch run with the checkpoint. Must be called before `commitCheckpoint`.

---

### 6. Prepare Checkpoint Candidate

```
prepareCheckpointCandidate(
    projectId : int
) → int   // checkpointId of the candidate
```

Elevates the most recent `Pending` checkpoint into a reviewable `Candidate` state. The orchestration layer should surface the candidate to the operator for review before committing. The operator supplies a `WhatHappened` narrative at commit time (see §7).

**WhatHappened is operator-authored.** It is not LLM-generated. It is a human-written bridge narrative describing what occurred between the previous checkpoint and this one. The engine stores it verbatim on the checkpoint record.

---

### 7. Commit Checkpoint

```
commitCheckpoint(
    checkpointId  : int,
    whatHappened  : string   // operator-supplied narrative; may be empty string
) → void
```

Promotes the candidate to `Active`, making it the new baseline. The previously active checkpoint is retained in the chain and remains accessible for forensic traversal. Prior context is not deleted.

---

### 8. Prepare Harvest Candidate

```
prepareHarvestCandidate(
    projectId : int
) → int   // harvestId, or 0 if no harvestable plans exist
```

Clusters completed plans by semantic similarity (centroid-greedy algorithm) and writes a draft `SwarmHarvest` record with candidate clusters. Returns 0 if there is nothing to harvest. The orchestration layer should check for `> 0` before proceeding.

---

### 9. Dispatch Synthesis

```
dispatchSynthesis(
    harvestId       : int,
    clusterId       : int,
    outputType      : string,   // e.g. "Summary", "ActionPlan", "RiskRegister"
    workerIds       : List<string>,   // composite keys — see format below
    collapserId     : string,         // composite key
    projectId       : int
) → void
```

Dispatches a Collapser synthesis pass over one cluster within the harvest. `workerIds` and `collapserId` here use a **composite key format**, not UUID participant IDs:

```
workerKey  = "{modelName}::{personaId}"
collapserKey = "{modelName}::{personaId}"
```

The engine resolves composite keys to participants internally. Synthesise each cluster independently; call once per cluster per output type required.

---

### 10. Promote Artifact

```
promoteArtifact(
    artifactId : int,
    target     : string,   // destination identifier (Jira ID, file path, system ref)
    projectId  : int
) → void
```

Marks the artifact as promoted and records the target. The reference implementation uses a system-generated placeholder (`"System-{ticks}"`); production integrations should pass a real destination reference.

---

### 11. Discard Artifact

```
discardArtifact(
    artifactId : int,
    projectId  : int
) → void
```

Marks the artifact as discarded. Idempotent.

---

### 12. Clone Project

Two variants:

```
// Clone from active checkpoint only — carries forward committed baseline
cloneSwarmProjectFromActiveCheckpoint(
    sourceProjectId : int,
    newProjectName  : string
) → int   // new projectId

// Full clone including all analysis state
cloneSwarmProjectWithoutAnalysis(
    sourceProjectId : int,
    newProjectName  : string
) → int   // new projectId
```

Both perform a deep copy: all context buckets, manifests, participants, and knowledge graph edges are duplicated into an independent project. The returned project ID becomes the active project in the orchestration layer.

`cloneSwarmProjectFromActiveCheckpoint` is the standard path — the clone starts from a clean committed state. `cloneSwarmProjectWithoutAnalysis` copies everything including in-progress work; use when you want to branch mid-investigation.

---

## Dispatch Lifecycle Summary

```
┌─────────────────────────────────────────────────────────────────┐
│  1. registerParticipant × (N workers + 1 collapser)             │
│  2. dispatchSwarmObjective → planIds                            │
│  3. [optional] dispatchFollowUpGenerations → append to planIds  │
│  4. createSwarmCheckpoint → checkpointId                        │
│  5. linkPlansToCheckpoint(checkpointId, planIds)                │
│                    ↓  engine executes plans asynchronously       │
│  6. prepareCheckpointCandidate → candidate for operator review  │
│  7. commitCheckpoint(id, whatHappenedText)                      │
│                    ↓  optional harvest pass                      │
│  8. prepareHarvestCandidate → harvestId                         │
│  9. dispatchSynthesis × per cluster                             │
│  10. promoteArtifact or discardArtifact × per artifact          │
└─────────────────────────────────────────────────────────────────┘
```

Steps 1–5 are atomic from the operator's perspective (one "dispatch" action). Steps 6–7 happen after plans complete. Steps 8–10 are a separate harvest session.

---

## Context Window Guidance

| Participant Type | Reference Value | Notes |
|-----------------|-----------------|-------|
| Worker | 32,000 tokens | Sized for per-file context bucket analysis |
| Collapser | 128,000 tokens | Must fit N×M worker outputs for synthesis |

These are soft limits passed to the engine for prompt assembly budgeting. The engine does not enforce them at the inference layer — the model's actual context window is the hard limit.

---

## What the Engine Owns

The orchestration layer must not implement any of the following — these are engine responsibilities:

- Compaction (outputs > 89,600 chars → `itemSummary` / `itemSummaryBullets` / `conversationDelta`)
- Thermal tracking (term extraction, Heat decay, tier transitions)
- Resolution Controller (Archive→Current resurgence detection and rehydration)
- Worker retry logic (3 attempts; permanent failure injects a `FAILED` placeholder)
- Knowledge graph extraction (structural markdown → `SwarmKnowledgeNodes` edges ≥ 0.75 confidence)
- Context assembly (orchestrator-owned: deterministic, non-LLM, never delegated to a model)
