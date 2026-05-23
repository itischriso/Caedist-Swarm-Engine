# AT_MODULE_SPEC.md
# Swarm Analysis Tool Module Specification

**Version**: 1.0.0  
**Status**: Draft — canonical interface for all Swarm AT modules  
**Stability**: This document describes a stable interface. The `SwarmAnalysis` JSON
contract will not have breaking changes within a major version. New optional fields
may be added. Required fields will not be removed or renamed without a major version bump.

---

## What Is an AT Module?

An Analysis Tool (AT) module is a standalone CLI executable that accepts a source file
and returns a structured `SwarmAnalysis` JSON document on stdout.

AT modules are the language intelligence layer of Swarm. The Swarm core is
language-agnostic — it orchestrates workers, manages context, tracks thermal terms, and
synthesises outputs, but it does not parse source code. AT modules provide the
structured analysis that makes the Swarm's context assembly precise rather than
approximate.

The interface is deliberately minimal: a file path in, JSON out, non-zero exit on
failure. Nothing else is required. Any executable that honours this contract is a
valid AT module.

---

## Invocation

Every AT module is invoked as a CLI tool by the Swarm core during corpus ingestion:

```bash
swarm-at-dotnet analyze --file ./caedistRoundTable.cs
swarm-at-python analyze --file ./cvdl.py
swarm-at-go     analyze --file ./main.go
```

### Rules

1. **Input**: A single `--file <path>` argument. The path is absolute. The file exists
   and is readable — the Swarm core verifies this before invoking the module.

2. **Output**: A single `SwarmAnalysis` JSON document written to stdout. Nothing else
   is written to stdout. Log output, warnings, and diagnostic information go to stderr.

3. **Exit codes**:
   - `0` — Analysis completed. Output on stdout is valid JSON.
   - `1` — Analysis failed. Reason on stderr. Swarm core injects a `FAILED` placeholder
     for this file and continues — a failed AT module does not abort the ingestion run.
   - Any non-zero exit is treated as failure.

4. **Timeout**: The Swarm core enforces a per-file timeout (default: 120 seconds,
   configurable). Modules that exceed this are terminated and treated as exit code 1.

5. **No side effects**: AT modules are read-only. They must not write files, modify
   the input file, or contact external services. Analysis is purely local and
   deterministic — the same file must produce equivalent output on repeated invocations.

### Version query

AT modules must support `--version` returning a single line:
```
swarm-at-dotnet 1.0.0
```

The Swarm core records the module name and version in `ActionablePlans` for every
analysis run. This enables reproducibility auditing — if an AT module is updated, the
version difference is visible in the run history.

---

## Output Contract: SwarmAnalysis

The following JSON schema is the complete AT module output contract. Fields marked
**Required** must always be present. Fields marked **Recommended** should be present
when the language and file type support them. Fields marked **Optional** may be omitted.

```json
{
  "file":       "<string: absolute path of the analysed file>",
  "language":   "<string: canonical language identifier — see Language Identifiers>",
  "at_module":  "<string: module name, e.g. swarm-at-dotnet>",
  "at_version": "<string: semver of the AT module that produced this output>",

  "summary": "<string>",

  "chunk_boundaries": [ "<ChunkBoundary>" ],

  "behavioral_spec": "<BehavioralSpec | null>",

  "mermaid": "<string | null>",

  "security_risks": [ "<SecurityRisk>" ],

  "errors":   [ "<string>" ],
  "warnings": [ "<string>" ]
}
```

---

### Top-Level Fields

#### `file` — Required
Absolute path of the file that was analysed. Reproduced from the `--file` argument.
Used by the Swarm core to correlate output with the `ContextBucket` record.

#### `language` — Required
Canonical language identifier string. See [Language Identifiers] below.

#### `at_module` — Required
The name of the AT module that produced this output (e.g. `swarm-at-dotnet`).
Stored verbatim in `ActionablePlans` for audit purposes.

#### `at_version` — Required
Semantic version of the AT module (e.g. `1.0.0`). Stored verbatim. Enables
reproducibility auditing across ingestion runs.

---

### `summary` — Required

A prose summary of the file: what it does, what its primary responsibility is, and
what a sibling worker in a different domain needs to know about it.

**This is the most important field in the contract.** Every worker who does not own
this file's domain receives this summary as their only window into the file's content.
The quality of cross-domain analysis is bounded by the quality of this summary.

Write it as if you are handing it to a senior engineer who has never seen the file
and needs to understand what it does in 30 seconds. Name the key concepts, the
primary operations, and any architectural role the file plays.

```json
"summary": "The RoundTable component manages multi-LLM debate sessions within Caedist.
            It intercepts and bifurcates the command stream — routing non-mutating RAG
            commands synchronously on the UI thread while queuing state-mutating commands
            to the async backend pipeline. Key operations: SendMessage (dispatches user
            input to N×M model/role combinations), BuildSystemPrompt (assembles role
            prompt from Boilerplate + RolePrompt + Phase), ProcessCommand (routes parsed
            opcodes to sync or async execution)."
```

**Length**: 50–300 words. Long enough to be useful. Short enough to fit inside every
sibling worker's context budget.

---

### `chunk_boundaries` — Required

An array of semantic boundaries within the file. Each boundary defines a named region
that the Swarm core will use as a separate `ContextBucket` — a distinct domain with
its own worker plan.

```json
"chunk_boundaries": [
  {
    "name":       "SendMessage",
    "type":       "method",
    "start_line": 120,
    "end_line":   280,
    "summary":    "Dispatches user input to all selected model/role combinations,
                   collects streamed responses, and routes any embedded commands to
                   the synchronous or asynchronous execution pipeline."
  },
  {
    "name":       "BuildSystemPrompt",
    "type":       "method",
    "start_line": 355,
    "end_line":   410,
    "summary":    "Assembles the final system prompt: Boilerplate + RolePrompt + Phase.
                   Exception: The Guy receives RolePrompt + Phase only. Injects Intercom
                   opcodes at assembly time."
  }
]
```

#### ChunkBoundary fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | ✅ | Identifier for this chunk — method name, class name, section heading, etc. Must be unique within the file. |
| `type` | string | ✅ | Chunk type. See [Chunk Types] below. |
| `start_line` | integer | ✅ | 1-indexed line number where this chunk begins. |
| `end_line` | integer | ✅ | 1-indexed line number where this chunk ends (inclusive). |
| `summary` | string | ✅ | One-paragraph prose summary of this chunk specifically. Same quality bar as the file-level summary. |

#### Chunk Types

| Value | Meaning |
|-------|---------|
| `method` | A method or function definition |
| `class` | A class, struct, or interface definition |
| `function` | A top-level function (for languages without classes) |
| `module` | A module or namespace block |
| `section` | A logical section of a non-code file (e.g. a heading in Markdown, a clause in YAML) |
| `other` | Any boundary that does not fit the above categories |

**Chunking guidance:**

- Chunk at semantic boundaries — where responsibility changes, not at arbitrary line counts.
- For large files, prefer more smaller chunks over fewer large ones. A worker with 200
  lines of focused content reasons better than a worker with 2,000 lines of mixed content.
- For small files where no meaningful internal boundary exists, return a single chunk
  spanning the whole file (`start_line: 1`, `end_line: <total_lines>`).
- Files with no parseable structure (e.g. binary, minified, generated) should return
  a single chunk with an appropriate summary noting the file type.

---

### `behavioral_spec` — Recommended

A machine-readable behavioural specification of the file's components. Used by the
Swarm core to seed the knowledge graph and thermal term tracking, and surfaced to the
Validator as structured evidence against which LLM claims can be checked.

```json
"behavioral_spec": {
  "name":       "RoundTable",
  "namespace":  "Caedist.Web",
  "is_static":  false,
  "steps": [
    {
      "name":        "SendMessage",
      "return_type": "Task",
      "is_async":    true,
      "guards": [
        {
          "expression":    "string.IsNullOrWhiteSpace(userInput)",
          "returns_early": true,
          "is_null_check": false
        }
      ],
      "resources":     [],
      "side_effects":  [],
      "security_risks": [],
      "async_flow": {
        "await_count":           14,
        "has_cancellation_token": false,
        "fire_and_forget_risks": []
      }
    }
  ]
}
```

#### BehavioralSpec fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | ✅ | Name of the primary component (class, module, package) |
| `namespace` | string | — | Namespace, package, or module path |
| `is_static` | boolean | — | Whether the component is static/singleton |
| `steps` | FlowStep[] | ✅ | One entry per method, function, or significant operation |

#### FlowStep fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | ✅ | Method or function name |
| `return_type` | string | — | Return type as it appears in source |
| `is_async` | boolean | — | Whether the operation is asynchronous |
| `guards` | Guard[] | — | Early-exit conditions at the top of the method |
| `resources` | string[] | — | External resources accessed (DB, file, network, vault) |
| `side_effects` | string[] | — | Observable state changes outside the method |
| `security_risks` | SecurityRisk[] | — | OWASP-aligned risks identified in this method |
| `async_flow` | AsyncFlow | — | Async-specific analysis |

#### Guard fields

| Field | Type | Description |
|-------|------|-------------|
| `expression` | string | The guard condition as it appears in source |
| `returns_early` | boolean | True if the guard returns, throws, or exits before the main body |
| `is_null_check` | boolean | True if this guard is a null/empty check |

#### AsyncFlow fields

| Field | Type | Description |
|-------|------|-------------|
| `await_count` | integer | Number of await points in the method |
| `has_cancellation_token` | boolean | Whether a CancellationToken is accepted and used |
| `fire_and_forget_risks` | string[] | Descriptions of any unawaited Task launches |

---

### `mermaid` — Recommended

A Mermaid `graph TD` diagram representing the architectural structure or operational
flow of the file. Stored as a single escaped string. Used by the Swarm core as the
**architectural compression representation** — injected into global context for workers
whose domain is not this file, giving them a visual map without the raw content.

```json
"mermaid": "graph TD\n    subgraph RoundTable\n    SendMessage --> ParseCommands\n    ParseCommands -->|sync opcode| ExecuteSync\n    ParseCommands -->|state-mutating opcode| QueueAsync\n    QueueAsync --> HistoryTable[(history)]\n    end"
```

**Requirements:**
- Must be valid Mermaid syntax renderable by the standard Mermaid library.
- Use `graph TD` (top-down). Left-right (`LR`) is acceptable for wide horizontal flows.
- Keep node labels concise — they appear in LLM context and verbose labels waste tokens.
- Aim for 10–30 nodes. A diagram with 60 nodes conveys less than one with 20.

**When to omit:**
- Configuration files, data files, or files with no meaningful flow to diagram.
- Files where the chunk boundary summary already conveys the structure adequately.

---

### `security_risks` — Optional

OWASP-aligned security risks identified in the file. May be present at the file level
(risks that span multiple methods) or at the `FlowStep` level (method-specific risks).
Surfaced to the Validator and Collapser as structured evidence.

```json
"security_risks": [
  {
    "owasp_id":  "LLM01",
    "category":  "Prompt Injection",
    "severity":  "Medium",
    "method":    "BuildSystemPrompt",
    "line":      360,
    "evidence":  "User input concatenated directly into system prompt without structural
                  delimiters. An adversarial input could escape the user turn and inject
                  instructions into the system context.",
    "fix":       "Wrap user input in XML tags (e.g. <user_input>...</user_input>) before
                  concatenation. Do not rely on newline separation alone."
  }
]
```

#### SecurityRisk fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `owasp_id` | string | ✅ | OWASP identifier (e.g. `A03:2021`, `LLM01`, `CWE-89`) |
| `category` | string | ✅ | Human-readable category (e.g. `SQL Injection`, `Prompt Injection`) |
| `severity` | string | ✅ | One of: `Critical`, `High`, `Medium`, `Low`, `Info` |
| `method` | string | — | Method or function where the risk is located |
| `line` | integer | — | 1-indexed line number of the risk location |
| `evidence` | string | ✅ | Specific description of the risk with reference to the code |
| `fix` | string | — | Recommended remediation |

**Severity definitions:**

| Level | Meaning |
|-------|---------|
| `Critical` | Exploitable with no preconditions; direct path to data loss or RCE |
| `High` | Exploitable with low-privilege access or common conditions |
| `Medium` | Exploitable with specific conditions or attacker-controlled input |
| `Low` | Defence-in-depth concern; no direct exploit path identified |
| `Info` | Observation worth noting; not a vulnerability |

---

### `errors` — Optional

An array of strings describing errors encountered during analysis that did not prevent
the module from producing output. Distinguished from a fatal error (which produces a
non-zero exit and no JSON) — these are partial failures where the module completed
analysis but some fields may be missing or incomplete.

```json
"errors": [
  "Failed to parse method GetTokenMetadata at line 892: unexpected preprocessor directive.
   FlowStep for this method is omitted from behavioral_spec."
]
```

### `warnings` — Optional

Non-fatal observations about the analysis. Does not indicate incomplete output.

```json
"warnings": [
  "File contains 4,200 lines. Chunk boundaries have been set at class level rather than
   method level to keep chunk count below 20. Method-level granularity is available
   by running with --granularity=method."
]
```

---

## How the Swarm Core Uses Each Field

Understanding the downstream use of each field helps module authors prioritise quality
where it matters most.

| Field | How Swarm uses it |
|-------|------------------|
| `summary` | Becomes the compacted sibling context injected into every worker whose domain is not this file. Every worker in the run reads this. **Highest impact field.** |
| `chunk_boundaries` | Each boundary becomes a separate `ContextBucket` with its own worker plan. The boundary `summary` becomes that bucket's compacted representation for siblings. |
| `behavioral_spec` | Parsed into `SwarmKnowledgeNodes` (one node per step). Method names, guards, and side effects become thermal term seeds — they are tracked for resurgence across the run. |
| `mermaid` | Stored as the Mermaid compression of the bucket. Injected into global context for all workers in the run as architectural overview. |
| `security_risks` | Stored with the `ContextBucket`. Surfaced to the Validator as pre-computed structured evidence. Reduces the chance that the Validator misses a known risk pattern. |
| `errors` | Logged against the `ContextBucket`. Surfaced in the Swarm status report. Does not affect execution. |
| `warnings` | Logged. Not surfaced to workers. |

---

## Capability Levels

Not all AT modules need to produce every field. Swarm supports graceful degradation.

| Capability | Required | Effect if absent |
|------------|----------|-----------------|
| `summary` + `chunk_boundaries` | ✅ Yes | Minimum viable module. Full Swarm workflow operates. |
| `behavioral_spec` | Recommended | Knowledge graph not seeded. Thermal terms not pre-seeded from structure. Validator operates on LLM-extracted claims only. |
| `mermaid` | Recommended | No architectural diagram in global context. Workers receive sibling summaries only. |
| `security_risks` | Optional | Validator and Collapser receive no pre-computed risk evidence. LLM-identified risks only. |

A module that produces only `summary` and `chunk_boundaries` enables the full Swarm
workflow for any language. Richer output enables richer analysis. Start with the
minimum and add capabilities incrementally.

---

## Language Identifiers

Use the following canonical identifiers in the `language` field:

| Language | Identifier |
|----------|-----------|
| C# | `csharp` |
| Python | `python` |
| Go | `go` |
| TypeScript | `typescript` |
| JavaScript | `javascript` |
| Java | `java` |
| Rust | `rust` |
| C | `c` |
| C++ | `cpp` |
| Ruby | `ruby` |
| Markdown | `markdown` |
| YAML | `yaml` |
| JSON | `json` |
| SQL | `sql` |
| Shell | `shell` |
| Unknown | `unknown` |

For languages not in this list, use a lowercase identifier without spaces. Raise an
issue in the Swarm repository to have the identifier standardised.

---

## Writing a New AT Module

An AT module is any executable that honours the invocation interface and produces valid
`SwarmAnalysis` JSON. The implementation language does not matter.

### Minimum viable implementation

```
1. Accept --file <path> and --version arguments
2. Read the file at <path>
3. Produce:
   - summary:           A prose description of what the file does
   - chunk_boundaries:  Semantic boundaries within the file, each with a summary
4. Write SwarmAnalysis JSON to stdout
5. Exit 0 on success, non-zero on failure
```

### Recommended implementation steps

```
1. Parse the file using your language's native AST or parsing library
   - .NET:   Roslyn (Microsoft.CodeAnalysis)
   - Python: tree-sitter or the built-in ast module
   - Go:     go/ast
   - Other:  tree-sitter has grammars for 100+ languages

2. Identify semantic boundaries
   - For OO languages: class → method hierarchy
   - For functional languages: module → function hierarchy
   - For config/data files: top-level keys or sections

3. Generate summaries
   - File-level: what the component's primary responsibility is
   - Chunk-level: what each method/function/section does

4. Optionally extract:
   - behavioral_spec: guards, return types, async patterns, side effects
   - mermaid:         control flow or component relationship diagram
   - security_risks:  OWASP-aligned patterns for your language

5. Write SwarmAnalysis JSON to stdout
6. Write any errors or warnings to stderr (not stdout)
```

### Testing your module

```bash
# Basic output check
swarm-at-mymodule analyze --file ./testfile.ext | jq .

# Validate required fields are present
swarm-at-mymodule analyze --file ./testfile.ext | jq '
  {
    has_file:             (.file != null),
    has_language:         (.language != null),
    has_at_module:        (.at_module != null),
    has_at_version:       (.at_version != null),
    has_summary:          (.summary != null and .summary != ""),
    has_chunks:           (.chunk_boundaries | length > 0),
    chunks_have_summaries: ([.chunk_boundaries[].summary | . != null and . != ""] | all)
  }
'

# Check exit code on a non-existent file
swarm-at-mymodule analyze --file ./does_not_exist.ext
echo "Exit code: $?"

# Version check
swarm-at-mymodule --version
```

### Registering your module

AT modules are registered in `swarm.yaml` under the `at_modules` section:

```yaml
at_modules:
  - extension: [".cs", ".csproj"]
    module: swarm-at-dotnet

  - extension: [".py"]
    module: swarm-at-python

  - extension: [".go"]
    module: swarm-at-go

  - extension: [".ts", ".tsx", ".js", ".jsx"]
    module: swarm-at-typescript   # community module
```

Multiple extensions can map to the same module. Files with no registered extension
are ingested as raw text without AT module analysis — `summary` and `chunk_boundaries`
are generated by the Swarm core using simple heuristics (line count based splitting,
no semantic boundary detection).

---

## Reference Implementations

| Module | Language analysed | Analysis engine | Repository |
|--------|-----------------|----------------|------------|
| `swarm-at-dotnet` | C# / .NET | Roslyn (Microsoft.CodeAnalysis) | `github.com/itischriso/Caedist-Swarm-Engine/at-dotnet` |
| `swarm-at-python` | Python | tree-sitter / ast | `github.com/itischriso/Caedist-Swarm-Engine/at-python` |
| `swarm-at-go` | Go | go/ast | `github.com/itischriso/Caedist-Swarm-Engine/at-go` |

`swarm-at-dotnet` is derived from FlowSpec, the static analysis component of
[Caedist](https://github.com/itischriso/caedist). It is the reference implementation and
the most complete — it produces all optional fields including `behavioral_spec`,
`mermaid`, and `security_risks`.

`swarm-at-python` and `swarm-at-go` target the minimum viable capability level
initially and add richer fields incrementally.

---

## Versioning and Stability

This specification follows semantic versioning.

| Change type | Version bump |
|------------|-------------|
| New optional field added to SwarmAnalysis | Patch (1.0.x) |
| New optional field added to a nested type | Patch (1.0.x) |
| New optional CLI flag added | Patch (1.0.x) |
| New required field added to SwarmAnalysis | Major (2.0.0) |
| Any existing field renamed or removed | Major (2.0.0) |
| Exit code semantics changed | Major (2.0.0) |

AT modules should specify the spec version they implement. The Swarm core will log a
warning if an AT module's declared spec version differs from the version it expects,
but will not abort — backwards-compatible changes are handled gracefully.

AT modules declare their target spec version in the `--version` output:

```
swarm-at-dotnet 1.2.0 (spec: 1.0.0)
```
