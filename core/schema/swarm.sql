-- swarm.sql
-- Canonical SQLite schema for the Swarm engine
-- Source: Derived from CaedistSwarmManager.cs and CaedistThermalManager.cs
--         (caedist_swarm.db — verified against live implementation)
-- Version: 1.0.0
-- Compatibility: SQLite 3.35+

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
PRAGMA synchronous = NORMAL;


-- =============================================================================
-- PROJECTS
-- The top-level isolation boundary. All state is project-scoped.
-- =============================================================================

CREATE TABLE IF NOT EXISTS SwarmProjects (
    ProjectId        INTEGER PRIMARY KEY AUTOINCREMENT,
    Name             TEXT    NOT NULL,
    Description      TEXT,
    State            TEXT    NOT NULL DEFAULT 'Active',  -- Active | Archived | Cloned
    ActiveCheckpointId INTEGER,                          -- FK → SwarmCheckpoints; NULL = no accepted checkpoint
    CreatedAt        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    LastOpenedAt     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- =============================================================================
-- PARTICIPANTS
-- A Participant is one worker slot: one model assigned one role for one project.
-- N×M dispatch creates N×M participants per domain question.
-- ResponderGuid links to SwarmResponders for the provider-level identity.
-- =============================================================================

CREATE TABLE IF NOT EXISTS Participant (
    Id               TEXT    PRIMARY KEY,                -- GUID string
    ProjectId        INTEGER NOT NULL,
    ResponderGuid    TEXT,                               -- Links to SwarmResponders.ResponderGuid
    Name             TEXT,                               -- Display name (e.g. "Val — glm-4-9b")
    RoleDescription  TEXT,                               -- The llm_role value (e.g. "Validator")
    ModelName        TEXT,                               -- The model serving this participant
    MaxContextTokens INTEGER NOT NULL DEFAULT 0,
    IsActive         INTEGER NOT NULL DEFAULT 1,
    FOREIGN KEY (ProjectId) REFERENCES SwarmProjects(ProjectId)
);

-- Provider-level identity: one responder per model/endpoint combination.
-- A Participant is an assignment of a Responder to a project role.
CREATE TABLE IF NOT EXISTS SwarmResponders (
    Id               INTEGER PRIMARY KEY AUTOINCREMENT,
    ProjectId        INTEGER,
    ResponderGuid    TEXT    NOT NULL,
    DisplayName      TEXT    NOT NULL,
    RoleDescription  TEXT,
    ModelName        TEXT,
    State            TEXT    NOT NULL DEFAULT 'Active',
    CreatedAt        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    LastSeenAt       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (ProjectId, ResponderGuid),
    FOREIGN KEY (ProjectId) REFERENCES SwarmProjects(ProjectId)
);


-- =============================================================================
-- CONTEXT BUCKETS
-- Every unit of ingested content lives here. One bucket per file (Distributed),
-- or per chunk within a file when AT module analysis produces chunk boundaries.
-- Global buckets are shared across all workers in the project.
--
-- Scope values:
--   Distributed       — one file or chunk, assigned to one domain worker
--   Global            — shared context injected into every worker's prompt
--   KnowledgeSubdivision — taxonomy subdivisions; excluded from main worker UI
--
-- Compaction fields (Summary, SummaryBullets, Delta) are computed by the
-- compaction daemon when ContentText exceeds the threshold (~89,600 chars).
-- Resolution stepping: raw → Summary → SummaryBullets → Delta (in that order,
-- as token budget shrinks).
-- =============================================================================

CREATE TABLE IF NOT EXISTS ContextBucket (
    Id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    ProjectId             INTEGER NOT NULL,
    BucketGuid            TEXT    NOT NULL UNIQUE,
    Scope                 TEXT    NOT NULL DEFAULT 'Distributed',
    SourceType            TEXT,                          -- 'File', 'Subdivision', 'Manual', etc.
    ContentText           TEXT,                          -- Raw ingested content
    CharCount             INTEGER NOT NULL DEFAULT 0,
    EstimatedTokens       INTEGER NOT NULL DEFAULT 0,   -- CharCount / 3.2
    State                 TEXT    NOT NULL DEFAULT 'Unprocessed',
    -- Chunking (set by AT module analysis)
    ParentContextBucketId INTEGER,                       -- FK → ContextBucket.Id (whole-file bucket)
    ChunkIndex            INTEGER,                       -- 0 = whole file; >0 = domain chunk
    ChunkCount            INTEGER,                       -- Total chunks in parent file
    ChunkRole             TEXT,                          -- Chunk name from AT module (e.g. "SendMessage")
    BoundaryReason        TEXT,                          -- Why this boundary was chosen
    -- Source provenance
    SourceFilePath        TEXT,
    SourceFileHash        TEXT,
    FOREIGN KEY (ProjectId)             REFERENCES SwarmProjects(ProjectId),
    FOREIGN KEY (ParentContextBucketId) REFERENCES ContextBucket(Id)
);

-- Which participant is assigned to which context bucket
CREATE TABLE IF NOT EXISTS ContextAssignments (
    Id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ProjectId       INTEGER NOT NULL,
    ContextBucketId INTEGER NOT NULL,
    ParticipantId   TEXT    NOT NULL,
    AssignedRole    TEXT,
    IsActive        INTEGER NOT NULL DEFAULT 1,
    FOREIGN KEY (ProjectId)       REFERENCES SwarmProjects(ProjectId),
    FOREIGN KEY (ContextBucketId) REFERENCES ContextBucket(Id),
    FOREIGN KEY (ParticipantId)   REFERENCES Participant(Id)
);

-- Spatial relationships between sibling context buckets within a domain.
-- Used by the orchestrator to assemble sibling summaries for worker prompts.
CREATE TABLE IF NOT EXISTS SwarmContextSiblingLinks (
    Id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    ProjectId             INTEGER,
    ParentContextBucketId INTEGER,
    LeftContextBucketId   INTEGER NOT NULL,
    RightContextBucketId  INTEGER NOT NULL,
    LeftChunkIndex        INTEGER,
    RightChunkIndex       INTEGER,
    RelationKind          TEXT    NOT NULL DEFAULT 'Sibling',
    Confidence            REAL    NOT NULL DEFAULT 1.0,
    EvidencePlanId        INTEGER,
    Note                  TEXT,
    CreatedAt             DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    LastSeenAt            DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (ProjectId, ParentContextBucketId, LeftContextBucketId, RightContextBucketId, RelationKind),
    FOREIGN KEY (ProjectId)             REFERENCES SwarmProjects(ProjectId),
    FOREIGN KEY (LeftContextBucketId)   REFERENCES ContextBucket(Id),
    FOREIGN KEY (RightContextBucketId)  REFERENCES ContextBucket(Id)
);


-- =============================================================================
-- ACTIONABLE PLANS
-- Every unit of LLM work dispatched by the orchestrator. One plan per
-- participant × context bucket combination.
--
-- State machine:
--   Pending → Running → Completed
--                     → Failed (auto-retry up to 3 times, then permanent)
--
-- Compaction fields (itemSummary, itemSummaryBullets, conversationDelta) are
-- populated by the compaction daemon when ResultOutput exceeds 89,600 chars.
-- The orchestrator uses these for resolution stepping when assembling context
-- for downstream Collapser and Validator plans.
--
-- DependentOnPlanIds is a comma-separated list of PlanIds that must reach
-- Completed state before this plan can be dispatched. The Collapser plan
-- depends on all worker plans in its dispatch group.
-- =============================================================================

CREATE TABLE IF NOT EXISTS ActionablePlans (
    PlanId                  INTEGER PRIMARY KEY AUTOINCREMENT,
    ProjectId               INTEGER NOT NULL,
    PlanGuid                TEXT    NOT NULL UNIQUE,
    ParentContextBucketId   INTEGER,
    CreatedByParticipantId  TEXT,
    AssignedToParticipantId TEXT,
    Objective               TEXT,
    AcceptanceCriteria      TEXT,
    DependentOnPlanIds      TEXT,                        -- Comma-separated PlanIds
    State                   TEXT    NOT NULL DEFAULT 'Pending',
    ResultOutput            TEXT,                        -- Raw LLM response
    RetryCount              INTEGER NOT NULL DEFAULT 0,  -- Auto-retry ceiling: 3
    -- Compaction representations (populated by compaction daemon)
    itemSummary             TEXT,                        -- Prose paragraph summary
    itemSummaryBullets      TEXT,                        -- Bullet-point summary
    conversationDelta       TEXT,                        -- What changed since prior checkpoint
    CreatedAt               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CompletedAt             DATETIME,
    FOREIGN KEY (ProjectId)               REFERENCES SwarmProjects(ProjectId),
    FOREIGN KEY (ParentContextBucketId)   REFERENCES ContextBucket(Id),
    FOREIGN KEY (CreatedByParticipantId)  REFERENCES Participant(Id),
    FOREIGN KEY (AssignedToParticipantId) REFERENCES Participant(Id)
);


-- =============================================================================
-- THERMAL TERMS
-- Tracks the heat and tier of significant terms extracted from plan outputs.
-- Terms are extracted after each plan completes by CaedistKeywordAnalyzer:
--   CamelCase identifiers, snake_case names, backtick-quoted terms.
--
-- Heat model:
--   New term:     Heat = 8,  Tier = Current (2)
--   Seen again:   Heat = min(Heat + 5, 23)
--   Not seen:     Heat = max(Heat - 3, 0)
--   Tier derives from Heat:  ≥16 = Current (2), ≥8 = Recent (1), else Archive (0)
--
-- Tier values (stored as integers for decay arithmetic):
--   2 = Current   — actively appearing in recent plan outputs
--   1 = Recent    — appeared recently, cooling
--   0 = Archive   — cold; triggers ResolutionController if it resurfaces
--
-- ResolutionController monitors for Archive→Current transitions (resurgence).
-- On resurgence, it rehydrates the compacted context from the plan where the
-- term was last active and injects it into the active context with a
-- (resurged) tag.
-- =============================================================================

CREATE TABLE IF NOT EXISTS ThermalTerms (
    Id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    ProjectId            INTEGER NOT NULL,
    ThreadId             TEXT,                           -- Conversation/thread scoping
    ContextBucketId      INTEGER,
    Term                 TEXT    NOT NULL,
    Heat                 INTEGER NOT NULL DEFAULT 8,     -- Range: 0–23
    Tier                 INTEGER NOT NULL DEFAULT 2,     -- 0=Archive, 1=Recent, 2=Current
    PreviousTier         INTEGER NOT NULL DEFAULT 2,     -- Used to detect tier transitions
    FirstSeenGeneration  INTEGER,
    LastSeenGeneration   INTEGER,
    SourcePlanId         INTEGER,
    LastDelta            INTEGER,                        -- +5 (seen) or -3 (not seen)
    FOREIGN KEY (ProjectId)       REFERENCES SwarmProjects(ProjectId),
    FOREIGN KEY (ContextBucketId) REFERENCES ContextBucket(Id),
    FOREIGN KEY (SourcePlanId)    REFERENCES ActionablePlans(PlanId)
);


-- =============================================================================
-- KNOWLEDGE GRAPH
-- Opportunistically extracted from plan outputs via structural markdown parsing.
-- Nodes are concepts, components, identifiers; observations are evidence from
-- specific plans; ResponderKnowsAbout tracks which responders hold evidence.
--
-- Only edges with Confidence ≥ 0.75 are surfaced in the Swarm UI.
-- =============================================================================

CREATE TABLE IF NOT EXISTS SwarmKnowledgeNodes (
    Id                          INTEGER PRIMARY KEY AUTOINCREMENT,
    ProjectId                   INTEGER,
    NodeGuid                    TEXT    NOT NULL,
    NormalizedKey               TEXT    NOT NULL,        -- Lowercase, trimmed, used for dedup
    CanonicalLabel              TEXT    NOT NULL,        -- Display form
    NodeType                    TEXT    NOT NULL DEFAULT 'Concept',
    Description                 TEXT,
    ObservationCount            INTEGER NOT NULL DEFAULT 1,
    -- First/last provenance across projects and plans
    FirstObservedProjectId      INTEGER,
    LastObservedProjectId       INTEGER,
    FirstObservedPlanId         INTEGER,
    LastObservedPlanId          INTEGER,
    FirstObservedContextBucketId INTEGER,
    LastObservedContextBucketId  INTEGER,
    FirstObservedResponderGuid   TEXT,
    LastObservedResponderGuid    TEXT,
    SourceEvidence              TEXT,
    State                       TEXT    NOT NULL DEFAULT 'Active',
    CreatedAt                   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    LastSeenAt                  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (ProjectId, NodeGuid),
    UNIQUE (ProjectId, NormalizedKey),
    FOREIGN KEY (ProjectId) REFERENCES SwarmProjects(ProjectId)
);

-- Evidence records: one row per observation of a node in a specific plan
CREATE TABLE IF NOT EXISTS SwarmKnowledgeObservations (
    ObservationId   INTEGER PRIMARY KEY AUTOINCREMENT,
    ProjectId       INTEGER,
    NodeGuid        TEXT    NOT NULL,
    ResponderGuid   TEXT    NOT NULL,
    PlanId          INTEGER,
    ContextBucketId INTEGER,
    ObservationKind TEXT,                               -- 'Definition', 'Reference', 'Relationship', etc.
    RawText         TEXT    NOT NULL,                   -- The extracted text that produced this observation
    CreatedAt       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (ProjectId)       REFERENCES SwarmProjects(ProjectId),
    FOREIGN KEY (PlanId)          REFERENCES ActionablePlans(PlanId),
    FOREIGN KEY (ContextBucketId) REFERENCES ContextBucket(Id)
);

-- Which responders have accumulated evidence about which nodes, and how confident
CREATE TABLE IF NOT EXISTS SwarmResponderKnowsAbout (
    Id                          INTEGER PRIMARY KEY AUTOINCREMENT,
    ProjectId                   INTEGER,
    ResponderGuid               TEXT    NOT NULL,
    NodeGuid                    TEXT    NOT NULL,
    FirstEvidenceObservationId  INTEGER,
    LastEvidenceObservationId   INTEGER,
    FirstEvidencePlanId         INTEGER,
    LastEvidencePlanId          INTEGER,
    FirstEvidenceContextBucketId INTEGER,
    LastEvidenceContextBucketId  INTEGER,
    Confidence                  REAL    NOT NULL DEFAULT 0.5,  -- UI threshold: 0.75
    ObservationCount            INTEGER NOT NULL DEFAULT 1,
    FirstSeenAt                 DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    LastSeenAt                  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    State                       TEXT    NOT NULL DEFAULT 'Observed',
    UNIQUE (ProjectId, ResponderGuid, NodeGuid),
    FOREIGN KEY (ProjectId) REFERENCES SwarmProjects(ProjectId)
);


-- =============================================================================
-- CHECKPOINTS
-- A checkpoint is a context rollover, not a summary that replaces prior state.
-- Prior context is preserved forensically. The checkpoint becomes the active
-- baseline from which new work computes its delta.
--
-- State values:
--   Candidate  — created, not yet reviewed
--   Accepted   — operator-approved; becomes ActiveCheckpointId on SwarmProjects
--   Rejected   — reviewed and declined; prior checkpoint remains active
--
-- SwarmCheckpointFileManifest records the state of every known file at the
-- time the checkpoint was created:
--   Unchanged / Modified / New / Missing / Deprecated / Unknown
--
-- SwarmCheckpointPlans links all plans that were active during this checkpoint
-- window, providing the complete evidence record for forensic inspection.
-- =============================================================================

CREATE TABLE IF NOT EXISTS SwarmCheckpoints (
    CheckpointId        INTEGER PRIMARY KEY AUTOINCREMENT,
    ProjectId           INTEGER NOT NULL,
    ParentCheckpointId  INTEGER,                        -- FK → SwarmCheckpoints; NULL = genesis checkpoint
    GenerationNumber    INTEGER NOT NULL DEFAULT 0,
    Objective           TEXT,
    WhatHappened        TEXT,                           -- Narrative summary of this checkpoint window
    State               TEXT    NOT NULL DEFAULT 'Candidate',
    CreatedAt           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (ProjectId)          REFERENCES SwarmProjects(ProjectId),
    FOREIGN KEY (ParentCheckpointId) REFERENCES SwarmCheckpoints(CheckpointId)
);

-- File classification at checkpoint time
CREATE TABLE IF NOT EXISTS SwarmCheckpointFileManifest (
    ManifestId              INTEGER PRIMARY KEY AUTOINCREMENT,
    CheckpointId            INTEGER NOT NULL,
    ProjectId               INTEGER NOT NULL,
    FilePath                TEXT,
    SourceType              TEXT,
    FileHash                TEXT,
    FileLength              INTEGER,
    LastWriteTime           TEXT,
    State                   TEXT,                       -- Unchanged | Modified | New | Missing | Deprecated | Unknown
    ParentContextBucketId   INTEGER,
    CurrentContextBucketId  INTEGER,
    EvidencePlanId          INTEGER,
    Note                    TEXT,
    CreatedAt               DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (CheckpointId) REFERENCES SwarmCheckpoints(CheckpointId),
    FOREIGN KEY (ProjectId)    REFERENCES SwarmProjects(ProjectId)
);

-- Plans active during a checkpoint window (complete forensic record)
CREATE TABLE IF NOT EXISTS SwarmCheckpointPlans (
    Id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ProjectId    INTEGER NOT NULL,
    CheckpointId INTEGER NOT NULL,
    PlanId       INTEGER NOT NULL,
    FOREIGN KEY (ProjectId)    REFERENCES SwarmProjects(ProjectId),
    FOREIGN KEY (CheckpointId) REFERENCES SwarmCheckpoints(CheckpointId),
    FOREIGN KEY (PlanId)       REFERENCES ActionablePlans(PlanId)
);


-- =============================================================================
-- HARVESTS
-- A Harvest is a structured synthesis dispatch: the orchestrator clusters
-- context buckets by semantic similarity, assigns a Collapser to each cluster,
-- and collects structured output (SwarmHarvestArtifacts) per cluster.
--
-- This is the Phase 3 Synthesis dispatch (distinct from the inline Collapser
-- that runs after each worker batch). Harvests support multi-generation
-- clustering — each generation narrows the scope.
-- =============================================================================

CREATE TABLE IF NOT EXISTS SwarmHarvests (
    HarvestId           INTEGER PRIMARY KEY AUTOINCREMENT,
    ProjectId           INTEGER NOT NULL,
    ActiveCheckpointId  INTEGER,
    Title               TEXT,
    ScopeDefinition     TEXT,
    ThreadCount         INTEGER,
    GenerationFloor     INTEGER,
    SimilarityThreshold REAL,
    State               TEXT    NOT NULL DEFAULT 'Candidate',
    StructuredOutput    TEXT,
    CreatedAt           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    LastUpdatedAt       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (ProjectId)         REFERENCES SwarmProjects(ProjectId),
    FOREIGN KEY (ActiveCheckpointId) REFERENCES SwarmCheckpoints(CheckpointId)
);

-- Which context buckets are included in each harvest, and their cluster assignment
CREATE TABLE IF NOT EXISTS SwarmHarvestBuckets (
    Id               INTEGER PRIMARY KEY AUTOINCREMENT,
    HarvestId        INTEGER NOT NULL,
    ProjectId        INTEGER NOT NULL,
    ContextBucketId  INTEGER NOT NULL,
    GenerationDepth  INTEGER,
    ClusterId        INTEGER,                            -- Which cluster this bucket was assigned to
    SimilarityScore  REAL,
    CreatedAt        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (HarvestId)       REFERENCES SwarmHarvests(HarvestId),
    FOREIGN KEY (ProjectId)       REFERENCES SwarmProjects(ProjectId),
    FOREIGN KEY (ContextBucketId) REFERENCES ContextBucket(Id)
);

-- Evidence records linking plans to harvest clusters
CREATE TABLE IF NOT EXISTS SwarmHarvestEvidence (
    Id              INTEGER PRIMARY KEY AUTOINCREMENT,
    HarvestId       INTEGER NOT NULL,
    ProjectId       INTEGER NOT NULL,
    PlanId          INTEGER,
    ContextBucketId INTEGER,
    EvidenceKind    TEXT,
    Note            TEXT,
    CreatedAt       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (HarvestId)       REFERENCES SwarmHarvests(HarvestId),
    FOREIGN KEY (ProjectId)       REFERENCES SwarmProjects(ProjectId),
    FOREIGN KEY (PlanId)          REFERENCES ActionablePlans(PlanId),
    FOREIGN KEY (ContextBucketId) REFERENCES ContextBucket(Id)
);

-- Structured outputs produced by Collapser plans within a harvest cluster.
-- PromotedTarget records where the artifact was promoted (e.g. checkpoint WhatHappened,
-- knowledge graph, external document).
CREATE TABLE IF NOT EXISTS SwarmHarvestArtifacts (
    ArtifactId       INTEGER PRIMARY KEY AUTOINCREMENT,
    HarvestId        INTEGER NOT NULL,
    ClusterId        INTEGER NOT NULL,
    ProjectId        INTEGER NOT NULL,
    OutputType       TEXT    NOT NULL,
    CollapserPlanId  INTEGER,
    ArtifactContent  TEXT,
    State            TEXT    NOT NULL DEFAULT 'Draft',  -- Draft | Accepted | Rejected | Promoted
    PromotedTarget   TEXT,
    CreatedAt        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    LastUpdatedAt    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (HarvestId)      REFERENCES SwarmHarvests(HarvestId),
    FOREIGN KEY (ProjectId)      REFERENCES SwarmProjects(ProjectId),
    FOREIGN KEY (CollapserPlanId) REFERENCES ActionablePlans(PlanId)
);


-- =============================================================================
-- PERSONAS
-- Prompt configuration for the open-source Swarm.
-- In Caedist, personas live in MSSQL (dbo.prompts). In Swarm standalone,
-- they live here, loaded at init from swarm-personas.yaml.
--
-- Assembly rule:
--   Worker prompt  = Boilerplate.Prompt + Persona.Prompt
--   Exception      = SkipBoilerplate = 1 → Persona.Prompt only (The Guy)
-- =============================================================================

CREATE TABLE IF NOT EXISTS Personas (
    Id              INTEGER PRIMARY KEY AUTOINCREMENT,
    Role            TEXT    NOT NULL UNIQUE,             -- e.g. 'Validator', 'The Guy', 'Worker'
    FriendlyName    TEXT    NOT NULL,
    Prompt          TEXT    NOT NULL,
    IsBoilerplate   INTEGER NOT NULL DEFAULT 0,          -- 1 = prepended to all other personas
    SkipBoilerplate INTEGER NOT NULL DEFAULT 0,          -- 1 = receives no boilerplate
    CreatedAt       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UpdatedAt       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- =============================================================================
-- INDEXES
-- =============================================================================

-- Project scoping — nearly every query filters on ProjectId
CREATE INDEX IF NOT EXISTS idx_contextbucket_project     ON ContextBucket(ProjectId);
CREATE INDEX IF NOT EXISTS idx_actionableplans_project   ON ActionablePlans(ProjectId);
CREATE INDEX IF NOT EXISTS idx_actionableplans_state     ON ActionablePlans(ProjectId, State);
CREATE INDEX IF NOT EXISTS idx_participant_project       ON Participant(ProjectId);
CREATE INDEX IF NOT EXISTS idx_thermalterms_project      ON ThermalTerms(ProjectId);
CREATE INDEX IF NOT EXISTS idx_thermalterms_tier         ON ThermalTerms(ProjectId, Tier);
CREATE INDEX IF NOT EXISTS idx_checkpoints_project       ON SwarmCheckpoints(ProjectId);
CREATE INDEX IF NOT EXISTS idx_knowledge_nodes_project   ON SwarmKnowledgeNodes(ProjectId);
CREATE INDEX IF NOT EXISTS idx_knowledge_obs_node        ON SwarmKnowledgeObservations(NodeGuid);
CREATE INDEX IF NOT EXISTS idx_responder_knows_confidence ON SwarmResponderKnowsAbout(ProjectId, Confidence);
CREATE INDEX IF NOT EXISTS idx_harvests_project          ON SwarmHarvests(ProjectId);
CREATE INDEX IF NOT EXISTS idx_harvest_buckets_harvest   ON SwarmHarvestBuckets(HarvestId);
CREATE INDEX IF NOT EXISTS idx_harvest_artifacts_harvest ON SwarmHarvestArtifacts(HarvestId, ClusterId);

-- Compaction daemon query: completed plans with large ResultOutput
CREATE INDEX IF NOT EXISTS idx_plans_compaction
    ON ActionablePlans(ProjectId, State)
    WHERE State = 'Completed' AND itemSummary IS NULL;

-- Pending plan dispatch
CREATE INDEX IF NOT EXISTS idx_plans_pending
    ON ActionablePlans(ProjectId, State)
    WHERE State = 'Pending';

-- Thermal resurgence detection: Archive terms
CREATE INDEX IF NOT EXISTS idx_thermal_archive
    ON ThermalTerms(ProjectId, Tier)
    WHERE Tier = 0;

-- Context bucket chunking lookups
CREATE INDEX IF NOT EXISTS idx_bucket_parent
    ON ContextBucket(ParentContextBucketId);

CREATE INDEX IF NOT EXISTS idx_bucket_scope
    ON ContextBucket(ProjectId, Scope);


-- =============================================================================
-- VIEWS
-- Common query patterns exposed as views for CLI and tooling use.
-- =============================================================================

-- Active thermal terms (Current and Recent) with their source plan
CREATE VIEW IF NOT EXISTS v_active_thermal_terms AS
SELECT
    tt.ProjectId,
    tt.Term,
    tt.Heat,
    CASE tt.Tier
        WHEN 2 THEN 'Current'
        WHEN 1 THEN 'Recent'
        WHEN 0 THEN 'Archive'
    END AS TierLabel,
    tt.LastSeenGeneration,
    ap.Objective AS SourceObjective
FROM ThermalTerms tt
LEFT JOIN ActionablePlans ap ON tt.SourcePlanId = ap.PlanId
WHERE tt.Tier > 0
ORDER BY tt.Heat DESC;

-- Plans ready for dispatch (Pending with all dependencies met)
CREATE VIEW IF NOT EXISTS v_dispatchable_plans AS
SELECT
    ap.PlanId,
    ap.ProjectId,
    ap.PlanGuid,
    ap.ParentContextBucketId,
    ap.AssignedToParticipantId,
    ap.Objective,
    ap.DependentOnPlanIds
FROM ActionablePlans ap
WHERE ap.State = 'Pending'
  AND (
      ap.DependentOnPlanIds IS NULL
      OR ap.DependentOnPlanIds = ''
      OR NOT EXISTS (
          SELECT 1
          FROM ActionablePlans dep
          WHERE (',' || ap.DependentOnPlanIds || ',') LIKE ('%,' || dep.PlanId || ',%')
            AND dep.State NOT IN ('Completed', 'Failed')
      )
  );

-- Plans needing compaction (completed, large output, not yet compacted)
CREATE VIEW IF NOT EXISTS v_plans_needing_compaction AS
SELECT
    PlanId,
    ProjectId,
    PlanGuid,
    ParentContextBucketId,
    Objective,
    length(ResultOutput) AS OutputLength
FROM ActionablePlans
WHERE State = 'Completed'
  AND ResultOutput IS NOT NULL
  AND length(ResultOutput) > 89600
  AND itemSummary IS NULL
ORDER BY length(ResultOutput) DESC;

-- Knowledge nodes with high-confidence responder evidence (UI threshold)
CREATE VIEW IF NOT EXISTS v_confident_knowledge AS
SELECT
    n.ProjectId,
    n.CanonicalLabel,
    n.NodeType,
    n.Description,
    n.ObservationCount,
    r.ResponderGuid,
    r.Confidence
FROM SwarmKnowledgeNodes n
JOIN SwarmResponderKnowsAbout r
    ON n.ProjectId = r.ProjectId AND n.NodeGuid = r.NodeGuid
WHERE r.Confidence >= 0.75
  AND n.State = 'Active'
ORDER BY r.Confidence DESC;

-- Harvest artifacts that are accepted and ready for promotion
CREATE VIEW IF NOT EXISTS v_promotable_artifacts AS
SELECT
    a.ArtifactId,
    a.HarvestId,
    a.ClusterId,
    a.ProjectId,
    a.OutputType,
    a.ArtifactContent,
    h.Title AS HarvestTitle
FROM SwarmHarvestArtifacts a
JOIN SwarmHarvests h ON a.HarvestId = h.HarvestId
WHERE a.State = 'Accepted'
  AND a.PromotedTarget IS NULL;
