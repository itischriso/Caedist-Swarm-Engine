# Swarm — README Draft

**Status**: Draft  
**Purpose**: The README is the innovation narrative. It must earn attention in the first three paragraphs.

---

# Swarm

**Horizontal context scaling for large language models.**

---

## What This Is

Three local models totalling ~80 billion parameters analysed a production codebase over sixteen hours. They found real issues — specific, evidence-grounded, cited against actual files and methods. Not summaries. Not general best-practice observations. Findings. The kind that go into a code review.

The first run of the same codebase took forty-eight hours. The next day, after optimisations, sixteen. The system ran on consumer hardware. It survived being interrupted. It resumed exactly where it stopped.

This is Swarm.

---

## The Problem

Every approach to using LLMs for large-scale analysis hits the same wall: context.

A modern LLM has a large context window — but "large" is relative when a codebase is hundreds of files, a corpus is thousands of documents, or an analysis needs to run for sixteen hours. Beyond raw size, there is a more insidious problem: **context degrades**. Content that matters in hour two becomes invisible by hour eight. Models cannot hold the whole thing. And if you try to keep everything in the window, you get the "lost in the middle" effect — quality of reasoning drops significantly for content that isn't near the beginning or end of a very large context.

The standard responses to this problem are:
- **RAG** — retrieve relevant chunks and hope you retrieved the right ones
- **Chunking** — split the corpus into pieces and process them independently, losing coherence
- **Bigger models** — wait for the next generation window size
- **Agent loops** — let the model decide what to read next, creating self-selected reality and echo chambers

None of these are satisfying. RAG retrieves what it thinks is relevant, not what actually is. Chunking loses cross-domain signal. Bigger windows still degrade. Agent loops accumulate noise and eventually lose track of the problem they were solving.

Swarm is a different approach.

---

## The Architecture

### Domain Allocation: Depth Without Sacrifice of Breadth

The corpus is divided into domains. Each LLM worker is assigned one domain as its primary responsibility. It receives the full, raw content of its domain. It also receives **compacted summaries** of every other domain — enough to know that sibling domains exist and what they broadly contain, without being overwhelmed by their detail.

Every worker has depth in one place and breadth awareness everywhere else. This is not chunking. Chunking produces isolated fragments. Domain allocation produces workers with **domain ownership** — they know their territory, and they know the map.

### BYOM — Bring Your Own Model

Swarm makes no recommendation about which models to use. This is a design position, not
an omission.

The diversity thesis: a team of heterogeneous models does not share the same blind spots.
If every worker, Validator, and Collapser runs on the same model, that model's failure
modes appear consistently across every analysis — and the Validator, running on the same
model, is least likely to catch them. A diverse set of models disagrees in useful ways.

Swarm's N×M dispatch makes this concrete. You select N models and M roles. Each
combination runs independently against the same domain content. The Collapser synthesises
across all N×M outputs. The more genuinely different your models are — in architecture,
training data, and RLHF disposition — the more independent the analyses you collect.

Configure your inference providers in `swarm.yaml`. Point them at Ollama, any
OpenAI-compatible endpoint, or a mix. Assign models to roles. Your mileage will vary —
that is the point.

```yaml
providers:
  - name: local
    endpoint: http://localhost:11434
    backend: ollama

  - name: my-cloud-provider
    endpoint: https://api.example.com/v1
    api_key_env: MY_API_KEY
    backend: openai-compatible

dispatch:
  worker_models: [llama3.1:8b, glm-4-9b]   # N models
  worker_roles:  [Worker, "Computer Scientist"]  # M roles → N×M plans per domain
  collapser_model: qwen2.5:14b
  validator_model: glm-4-flash
  compaction_model: llama3.2:3b
```

### The Orchestrator Owns Context

In most agentic frameworks, the model decides what context it needs. It queries a retrieval system, decides what to read next, self-selects its own reality. This is a problem: models retrieve what confirms their current direction. They create echo chambers. They drift.

In Swarm, **the Orchestrator owns context selection deterministically**. The Orchestrator is not an LLM — it cannot be manipulated, it does not have a direction to confirm. It assembles the prompt from a defined set of inputs: the project, the active checkpoint, global context items, thermal tier data, and operator input. Models receive what the Orchestrator decides they should receive. They do not ask for more.

### Thermal Tracking: Nothing Is Forgotten

This is the mechanism that makes long runs coherent.

As plans execute, the Swarm extracts **thermal terms** from every output — identifiers, method names, concept labels, anything that carries specific meaning. Each term has a heat value and a tier: `Current`, `Recent`, or `Archive`.

Terms that appear frequently stay hot. Terms that stop appearing cool and eventually enter `Archive`. But archived terms are not deleted — they are tracked.

When a term resurfaces — when a plan output suddenly references something that had gone cold — the **Resolution Controller** detects the resurgence. It locates the historical plan where that term was last active, extracts the compacted summary of the relevant context, and rehydrates it into the active context bucket with a `(resurged)` tag.

The term came back because it became relevant again. The system brings its history with it.

Nothing is forgotten. Things become archived. They resurface when evidence demands it.

### Checkpoints: Rollover, Not Replacement

After a significant body of work, the Swarm can commit a **checkpoint**. This is not a summary that replaces prior context. It is a **rollover** — the prior context is preserved forensically, and the new checkpoint becomes the active baseline. The checkpoint records what happened: which files changed, which were new, which were deprecated, what the collective found.

Future plans operate from the checkpoint baseline. Prior context remains available for forensic inspection and can be re-examined at any resolution — raw output, summary, bullets, or delta.

An accepted checkpoint is the Swarm's equivalent of a commit: a known-good state from which new work begins.

### The Collapser Pattern: Synthesis, Not Aggregation

After workers complete their domain analyses, a **Collapser** plan synthesises their outputs. The Collapser is not a summariser — it does not average opinions or defer to the majority. It weighs evidence by specificity. A finding with a file name, method name, and line number outweighs a finding that says "the code does X."

If a worker fails, the Collapser receives a `FAILED` placeholder and synthesises from the remaining workers. A failed worker is noise removed, not a reason to abort.

The **Validator** persona (Val) adds a quality gate before the Collapser. Val challenges claims that lack evidence, names what workers missed, and explicitly culls weak contributions. The Collapser receives a curated signal.

### Asynchronous and Persistent

Every plan, every context bucket, every thermal term, every checkpoint is stored in SQLite. The Swarm does not require LLMs to exist concurrently. A sixteen-hour run can be paused at hour seven, the machine shut down, restarted the next morning, and the run resumes from exactly where it stopped.

This is not a feature added for resilience. It is the core design assumption. Swarm was built for consumer hardware, real timescales, and the reality that long runs get interrupted.

---

## What Swarm Produces

- **Worker outputs**: Each domain worker's analysis of its assigned content
- **Collapser synthesis**: The cross-domain consensus, weighted by evidence
- **Knowledge graph**: Opportunistically extracted from plan outputs — concepts, relationships, observations, confidence-rated
- **Thermal state**: What terms are hot, recent, or archived at any point in the run
- **Checkpoints**: Accepted baselines with full manifests of what changed
- **Compacted representations**: For every large output — a delta, a summary, and a bullet list

All of this is queryable. The run is not a black box. Every decision the system made, every context it injected, every output it compacted is in the database.

---

## AT Modules: Language-Specific Analysis

The Swarm core is language-agnostic. Language-specific analysis is provided by **AT modules** (Analysis Tool modules) — standalone CLI tools that accept a source file and return a structured `SwarmAnalysis` JSON document.

AT modules handle:
- Semantic boundary detection (where to split a file into domain chunks)
- Behavioural specification extraction (methods, guards, resources, side effects)
- Security risk detection (OWASP-aligned rules for each language)
- Mermaid diagram generation (architectural compression for LLM context)

**Available AT modules:**

| Module | Language | Analysis Engine |
|--------|----------|----------------|
| `swarm-at-dotnet` | C# / .NET | Roslyn (Microsoft.CodeAnalysis) |
| `swarm-at-python` | Python | tree-sitter |
| `swarm-at-go` | Go | go/ast |

Writing a new AT module requires implementing one JSON contract over `stdin/stdout`. See [AT_MODULE_SPEC.md] for the specification.

---

## Getting Started

```bash
# Install the Swarm CLI
go install github.com/itischriso/Caedist-Swarm-Engine/cmd/swarm@latest

# Install an AT module (example: .NET)
dotnet tool install -g swarm-at-dotnet

# Initialise a new Swarm project
swarm init --name "my-project"

# Ingest a codebase
swarm ingest --project my-project --path ./src --at swarm-at-dotnet

# Ask a question across the whole codebase
swarm ask --project my-project "Which components handle authentication? What are the security risks?"

# Check run status
swarm status --project my-project

# Export results
swarm export --project my-project --output ./analysis-results.md
```

Swarm uses Ollama by default. Set `SWARM_OLLAMA_HOST` to point at your Ollama instance. For OpenAI-compatible endpoints, configure `SWARM_API_BASE` and `SWARM_API_KEY`.

---

## The Personas

Swarm ships with a set of operational personas refined through real analysis runs. The most important is the **Validator** (Val) — the quality gate that challenges claims without evidence, names what workers missed, and prevents the Collapser from synthesising noise into false confidence.

Personas are configurable. The defaults are opinionated. A weak Validator produces weak output.

See [docs/personas.md] for the full persona reference and configuration guide.

---

## Operational Evidence

The following claims are based on actual runs, not benchmarks:

- A production codebase was fully analysed in **sixteen hours** using three local models (~80B parameters total) running over Ollama on consumer hardware
- The initial run of the same codebase took **forty-eight hours**; optimisations delivered a 3× improvement the following day
- The sixteen-hour run required approximately **500 LLM invocations** — workers, Collapser, Validator, and compaction calls combined
- The Validator persona identified specific, evidence-grounded findings including: latent parser ambiguities, credential exposure via subprocess arguments, spec-to-implementation gaps, and duplicate method implementations
- All findings were grounded in actual code — not general best practice projected onto the codebase
- The run survived process interruption and resumed from the correct checkpoint

---

## Current Limitations

These are known and stated honestly:

**LLM calls are not yet parallelised.** Worker plans within a dispatch currently run sequentially. This is the primary bottleneck — the 16-hour runtime is largely sequential LLM inference time. Parallelising the worker tier is the most impactful near-term optimisation and is on the roadmap for the Go implementation.

**Swarm does not implement MCP.** The Model Context Protocol is a tool-calling interface for letting LLMs request external actions. Swarm is not that. Swarm is a context lifecycle management system — the orchestrator owns what models receive, not the models themselves. MCP and Swarm solve different problems. You could build an MCP server that exposes Swarm's query interface; that is a reasonable integration, not a missing feature.

---

## Architecture Deep-Dive

- [ARCHITECTURE.md] — Context lifecycle, thermal model, Collapser pattern, checkpoint system
- [docs/thermal-model.md] — Thermal tracking and deterministic resurrection
- [docs/collapser-pattern.md] — Worker/Collapser/Validator execution model
- [docs/checkpoint-model.md] — Why checkpoints are not summaries
- [docs/writing-an-at-module.md] — How to add a new language
- [AT_MODULE_SPEC.md] — The AT module JSON contract

---

## Licence

MIT. Use it. Build on it. Give the work a life.

---

## Origin

Swarm was extracted from [Caedist](https://github.com/itischriso/caedist) — a zero-trust AI-assisted Secure Software Development Lifecycle platform. The swarm engine is the part of Caedist with value beyond the SSDLC context. It is being open-sourced because the problem it solves — coherent LLM reasoning over large corpora across long timescales — is universal.
