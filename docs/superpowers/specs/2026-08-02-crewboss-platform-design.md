# CrewBoss Platform Design and Incremental Delivery Specification

- **Date:** 2026-08-02
- **Status:** Proposed master design
- **Target:** CrewBoss 1.0
**Purpose:** Turn CrewBoss from a small agent skill and Bash command into a durable, multi-project agent orchestration platform. It should compete with Firstmate on its core job while keeping CrewBoss's own product language and architecture.

## 1. Decision summary

CrewBoss will become a hybrid product:

- `SKILL.md` remains the agent-facing entry point. It tells an agent when and how to use CrewBoss.
- `crewboss` remains the user-facing command-line interface (CLI).
- A local Go service becomes the reliable state and coordination engine.
- SQLite becomes the source of truth for projects, jobs, runs, events, approvals, and delivery state.
- Herdr and Worktrunk remain the first supported runtime tools.
- Adapters make session managers, agent harnesses, worktree tools, and code forges replaceable.
- Any suitable agent session can attach as the active **CrewBoss**. A special cloned agent home is not required.
- Background supervision is deterministic. It consumes no model tokens while there is no work that needs reasoning.

The existing Bash version is not discarded at once. It becomes a compatibility bridge while the durable core is introduced in small releases.

## 2. Product goal

CrewBoss should let one person supervise many coding agents across many repositories without losing task state or giving agents unsafe authority.

The finished product must support this loop:

1. Register several projects.
2. Create Build or Explore jobs in plain language.
3. Turn each job into a precise, stored brief.
4. Dispatch workers into isolated worktrees and sessions.
5. Receive progress, questions, failures, and completion as durable events.
6. Resume supervision after a process, terminal, or machine restart.
7. Verify the exact code revision produced by a worker.
8. Deliver through a pull request, a local merge, or a report.
9. Require clear approval for destructive or high-impact actions.
10. Show the whole fleet from one command.

CrewBoss 1.0 is successful when it can perform that loop with at least ten concurrent workers across three projects and recover from deliberate failures without losing a job or silently repeating a dangerous action.

## 3. Competitive scope

[Firstmate's public repository](https://github.com/kunchenguid/firstmate) is the comparison point for feature coverage. This baseline was reviewed at public commit `1e24757` on 2026-08-02. Recheck its public capabilities before the 1.0 parity review. CrewBoss will match the orchestration job, not copy Firstmate's names, prompts, file formats, or internal protocols.

Core parity means:

- multi-project orchestration;
- durable job and event state;
- separate implementation and investigation workflows;
- background wake-up and supervision;
- isolated worktrees and worker sessions;
- persistent domain managers;
- several agent and terminal backends;
- verification and pull-request or local delivery;
- restart recovery;
- attended and unattended operation;
- safe authority controls;
- a stable agent-facing protocol.

Public social-media ingestion, a hosted control plane, and an exact copy of another product's user experience are not required for 1.0. They fit the later connector and remote-control roadmap.

## 4. Current baseline

This revision uses CrewBoss main commit `c165d61`, the merge commit for PR #2, as its repository baseline.

CrewBoss today is a small Bash tool published as an agent skill. It already has valuable design choices:

- The public command uses a crew name, not a pane identifier or filesystem path.
- Worktrunk owns worktrees.
- Herdr owns panes and agent processes.
- CrewBoss owns its registry, event log, and event-delivery checkpoint.
- Workers report `blocked` and `done` through `crewboss emit` with stored crew and run identities.
- `events.jsonl` is append-only and ordered by a validated sequence number.
- `event-state.json` provides a cursor and pending checkpoint for at-least-once delivery.
- `wait` accepts several crews and returns the oldest selected event in FIFO order.
- Missing endpoints are reconciled without treating terminal text as completion.
- Registry and event writes use locks.
- `close` and `open` preserve a crew across session teardown.
- The product is easy to install and understand.

These event capabilities landed on main in PR #2 and form the verified Bash migration baseline. They are current behavior, not future roadmap work.

These strengths should remain visible to users. The following limitations must not remain in the 1.0 architecture:

- one global registry keyed only by crew name;
- operations that depend on the caller's current repository;
- non-transactional worktree and pane creation;
- hard-coded unsafe agent flags;
- no durable worker transcript beyond explicit event payloads; `read` remains a visible-screen snapshot;
- no project registry, backlog, dependency graph, verification, or delivery model;
- no stable machine-readable CLI contract;
- no persistent background supervisor;
- no clear authority or approval records.

## 5. Product language

CrewBoss uses its own vocabulary throughout the CLI, database, documentation, and prompts.

| Term | Meaning |
| --- | --- |
| Operator | The human who owns the work and authority. |
| CrewBoss | The product and the currently attached coordinating agent. |
| Fleet | All projects, jobs, leads, and workers in one CrewBoss home. |
| Project | One registered source repository. |
| Job | A durable unit of requested work. |
| Run | One attempt to execute a job. A retry creates a new run. |
| Crew Worker | A task agent assigned to one run. |
| Crew Lead | A persistent manager for a domain or project scope. |
| Brief | The immutable instructions given to one run. |
| Decision | A question that needs an answer before work can continue. |
| Delivery | The controlled process that turns verified output into a PR, merge, or report. |
| CrewBoss home | One isolated local state and configuration namespace. |

Avoid competitor-specific nautical role names in shipped interfaces. Existing `crew` wording may remain as a compatibility alias where users already depend on it.

## 6. Design principles

1. **Durable before clever.** A committed event is more important than a fluent status message.
2. **Explicit state.** Completion, approval, and delivery are records, not guesses from terminal text.
3. **One writer.** The local service is the only normal writer to the SQLite database.
4. **Safe by default.** An agent cannot grant itself more authority.
5. **No idle model cost.** The service may watch processes and files, but it does not call a model until an event needs judgment.
6. **Project isolation.** Every job, worktree, endpoint, and artifact belongs to a registered project and CrewBoss home.
7. **Replaceable tools.** Herdr and Worktrunk are first-class defaults, not permanent hard dependencies in the domain model.
8. **Stable public protocol.** Human output may improve. JSON fields, event meaning, and exit codes are versioned.
9. **Evidence over claims.** Verification records the command, result, time, and exact Git commit.
10. **Graceful migration.** Existing crew names and worktrees remain usable while users move to the new core.

## 7. Non-goals for 1.0

- A hosted SaaS control plane.
- Windows support equal to macOS and Linux.
- Replacing Git, GitHub, GitLab, Worktrunk, or terminal session managers.
- A general chat application.
- Unlimited self-directed work with host-level permissions.
- Billing or model-token accounting across vendors.
- Copying Firstmate's prompts, private formats, or product language.
- A graphical interface. The CLI and protocol must be complete first.

## 8. Main user experiences

### 8.1 First setup

```bash
crewboss init
crewboss doctor
crewboss project add . --name crewboss
crewboss boss attach
```

`init` creates one named CrewBoss home, installs or updates the skill when requested, starts the local service, and writes a minimal configuration. `doctor` proves that Git and the selected adapters work. It reports unavailable optional features separately.

### 8.2 Build job

```bash
crewboss job create \
  --project crewboss \
  --type build \
  --delivery verified-pr \
  "CB-142 add retry limits to worker startup"

crewboss job dispatch cb-142
crewboss job show cb-142
```

The coordinator stores a brief, creates an isolated worktree, starts a worker, and follows durable events. When the worker completes, CrewBoss verifies the exact head commit and prepares the chosen delivery.

### 8.3 Explore job

```bash
crewboss job create \
  --project crewboss \
  --type explore \
  "Compare SQLite migration libraries and recommend one"
```

An Explore job produces a self-contained report artifact. It does not create a pull request. If the result should become code, `crewboss job promote <name>` creates a new Build job from a clean base and links the report as input.

### 8.4 Blocked worker

```bash
crewboss job list --state blocked
crewboss job answer cb-142 --decision choose-api --message-file answer.md
```

The question is stored before the worker receives an acknowledgement. An answer is also stored before delivery to the worker. Repeating the command with the same request identifier is safe.

### 8.5 Leave and return

```bash
crewboss boss mode away
# Later, from another terminal or agent session
crewboss boss attach
crewboss status
```

The service keeps watching deterministic state while the operator is away. Events remain queued. Safe policy actions can continue. Decisions that need judgment wait for the operator or the next attached CrewBoss.

## 9. Target architecture

```text
 Human or coordinating agent
            |
     SKILL.md + CLI
            |
       Unix socket
            |
  +-----------------------+
  | CrewBoss local service|
  |-----------------------|
  | command API           |
  | scheduler             |
  | event broker          |
  | policy + approvals    |
  | reconciliation        |
  | verification/delivery |
  +-----------------------+
       |             |
    SQLite         adapters
                     |
       +-------------+-------------+-------------+
       |             |             |             |
    session       worktree       harness        forge
  Herdr/tmux   Worktrunk/Git  Claude/Codex/... GitHub/...
```

### 9.1 Process model

The shipped Go binary contains both the CLI client and service command:

```bash
crewboss daemon serve
```

Normal CLI commands connect through a Unix domain socket. If the service is absent, commands may start it through the supported operating-system service manager. `--no-start` disables this behavior for scripts and diagnostics.

The service owns scheduling and deterministic state transitions. The attached coordinating agent handles work that needs language understanding, such as improving a brief, interpreting an ambiguous result, or presenting a decision. This split prevents idle model calls.

### 9.2 Coordinator lease

`crewboss boss attach` gives one agent session the active boss lease for a CrewBoss home.

- One lease is active per home.
- The holder sends heartbeats.
- A lease has a generation number and expiry.
- A newer generation makes all commands from an old holder invalid.
- Taking over a live lease needs operator confirmation unless the lease has expired.
- Detaching the boss never stops workers or loses events.
- If no boss is attached, actionable events stay queued and may trigger an OS notification.

There is no required cloned coordinator home. An agent in any terminal can attach after an operator-authorized attach flow issues a short-lived boss credential. The credential remains outside worker sandboxes. Access to the local socket or matching user ID alone is not enough.

### 9.3 Storage choice

SQLite 3 in write-ahead logging mode is authoritative. The service serializes state-changing transactions and allows concurrent read snapshots.

The database opens with foreign-key enforcement, a bounded busy timeout, and full synchronous durability. State mutations use immediate write transactions. Per-home event sequence allocation happens inside the same transaction as the domain change. Backups use SQLite's online backup mechanism or a service-owned checkpoint and snapshot; copying a live database and ignoring its WAL file is forbidden.

The reference build uses `modernc.org/sqlite` through Go's `database/sql`. It is a CGo-free SQLite implementation, so release builds can cross-compile for supported macOS and Linux targets without a platform C toolchain. Replacing it with a CGo driver requires a new architecture decision and release-pipeline proof.

JSONL may be exported for debugging or audit review. It is not a second source of truth.

Every state-changing API call must satisfy this order:

1. validate identity, generation, policy, and expected state;
2. write the domain change, event, and audit entry in one transaction;
3. commit;
4. acknowledge the caller;
5. perform or continue any external side effect through a recorded operation.

External tools cannot join a database transaction. Their work therefore uses a recorded saga: intent, attempt, observed result, compensation, and reconciliation.

## 10. Repository layout

The target repository layout is:

```text
/
├── SKILL.md
├── README.md
├── cmd/crewboss/                 # CLI and daemon entry point
├── internal/
│   ├── api/                      # Unix-socket HTTP/JSON API
│   ├── auth/                     # capability tokens and caller identity
│   ├── config/                   # TOML loading and validation
│   ├── domain/                   # states, transitions, and invariants
│   ├── store/                    # SQLite queries and migrations
│   ├── scheduler/                # dependencies, limits, and routing
│   ├── supervisor/               # watcher, wake queue, reconciliation
│   ├── policy/                   # authority and approval evaluation
│   ├── verify/                   # revision-bound checks
│   ├── deliver/                  # PR, merge, and report workflows
│   └── adapters/
│       ├── session/
│       ├── worktree/
│       ├── harness/
│       └── forge/
├── migrations/                   # embedded SQLite migrations
├── scripts/crewboss              # temporary compatibility shim
├── scripts/lib/                  # old Bash implementation during migration
├── tests/
│   ├── contract/
│   ├── integration/
│   ├── migration/
│   └── live/
└── docs/
```

`SKILL.md`, CLI help, JSON schemas, and README examples are shipped interfaces. A public behavior change must update all affected interfaces in the same commit.

## 11. Installation and local files

### 11.1 Installation channels

The full product should support:

- a signed GitHub release binary;
- Homebrew on macOS and Linux;
- `go install` for developers;
- `crewboss skill install --target codex|claude|agents` for the agent instructions.

The existing `npx skills add AhmedDaraz-Ignite/crewboss` flow remains a skill-only installation path. If the binary is absent, the skill prints exact binary installation instructions. It must not silently download and execute a binary.

Release CI publishes platform archives and a SHA-256 checksum manifest. It signs the manifest with Sigstore keyless signing through GitHub Actions OIDC. Verification pins the expected repository, workflow identity, and OIDC issuer. macOS binaries also use Apple Developer ID signing and notarization. Homebrew formulas pin the archive checksum. The self-update path verifies the same identity, signature, and checksum before it offers installation.

### 11.2 CrewBoss homes

Named homes isolate independent fleets, for example `work` and `personal`.

Use XDG paths with documented macOS and Linux fallbacks:

```text
$XDG_CONFIG_HOME/crewboss/config.toml
$XDG_STATE_HOME/crewboss/<home>/state.db
$XDG_DATA_HOME/crewboss/<home>/artifacts/
$XDG_DATA_HOME/crewboss/<home>/briefs/
$XDG_RUNTIME_DIR/crewboss/<home>/control.sock
$XDG_RUNTIME_DIR/crewboss/<home>/runs/<run-id>.sock
```

State and runtime directories use mode `0700`; databases, tokens, and sensitive configuration use `0600`. The daemon refuses a socket or state directory owned by another user. The control socket is never mounted into a worker sandbox. A run socket is removed when its capability is revoked.

### 11.3 Configuration

TOML is the human-edited configuration format. SQLite stores live and derived state.

Configuration sections are versioned:

```toml
version = 1
default_home = "default"

[service]
auto_start = true

[limits]
fleet_runs = 20
project_runs = 6
lead_runs = 4

[defaults]
session = "herdr"
worktree = "worktrunk"
harness = "codex"
delivery = "verified-pr"
permission_profile = "standard"

[forge.github]
enabled = true
```

Environment variables may select a home or override non-secret runtime values. They must not create hidden policy exceptions. `crewboss config validate` prints all effective sources and rejects unknown keys by default.

## 12. Domain model and database contract

IDs use UUIDv7. Times use UTC RFC 3339 with microseconds at API boundaries. JSON payloads carry a schema version. Each mutable aggregate has an integer `generation` used for compare-and-swap updates.

### 12.1 Required tables

#### `schema_migrations`

Fields: `version`, `name`, `checksum`, `applied_at`.

#### `homes`

Fields: `id`, `slug`, `display_name`, `config_revision`, `created_at`, `updated_at`.

`slug` is unique on the machine.

#### `projects`

Fields: `id`, `home_id`, `slug`, `display_name`, `repo_root`, `repo_identity`, `canonical_remote`, `base_branch`, `session_adapter`, `worktree_adapter`, `harness_defaults_json`, `forge_config_json`, `status`, `generation`, `created_at`, `updated_at`, `archived_at`.

`(home_id, slug)` and `(home_id, repo_identity)` are unique for active projects. `repo_identity` is derived from the canonical repository identity, not only the current path.

#### `boss_sessions`

Fields: `id`, `home_id`, `endpoint_id`, `holder_identity`, `lease_id`, `state`, `generation`, `attached_at`, `heartbeat_at`, `expires_at`, `detached_at`.

Only one unexpired active boss session may exist per home.

#### `leads`

Fields: `id`, `home_id`, `slug`, `display_name`, `scope_json`, `routing_rules_json`, `endpoint_id`, `harness_config_json`, `status`, `generation`, `created_at`, `updated_at`, `retired_at`.

`(home_id, slug)` is unique for non-retired leads.

#### `jobs`

Fields: `id`, `home_id`, `project_id`, `lead_id`, `name`, `title`, `type`, `state`, `state_reason`, `priority`, `tags_json`, `delivery_mode`, `merge_authority`, `requested_by`, `source_ref`, `objective`, `scope_json`, `acceptance_json`, `authority_json`, `current_run_id`, `generation`, `created_at`, `updated_at`, `completed_at`, `cancelled_at`.

`(project_id, name)` is unique. A globally ambiguous short name produces a clear conflict and requires `project/name`.

#### `job_dependencies`

Fields: `job_id`, `depends_on_job_id`, `kind`, `created_at`.

The service rejects self-dependencies and cycles. Initial `kind` values are `blocks` and `informs`.

#### `briefs`

Fields: `id`, `job_id`, `schema_version`, `content_sha256`, `content_json`, `rendered_artifact_id`, `created_by`, `created_at`.

A brief is immutable after its linked run starts. `runs.brief_id` is a non-null unique foreign key, so the run owns the only database relationship and exactly one run uses each brief. The service pre-generates both UUIDs, verifies that the brief and run use the same job, and inserts them in one transaction. `rendered_artifact_id` may be null until rendering finishes.

#### `runs`

Fields: `id`, `job_id`, `attempt`, `state`, `brief_id`, `base_ref`, `base_sha`, `branch`, `worktree_path`, `endpoint_id`, `worker_identity`, `capability_hash`, `capability_expires_at`, `head_sha`, `result_summary`, `failure_code`, `generation`, `created_at`, `dispatched_at`, `started_at`, `heartbeat_at`, `finished_at`.

`(job_id, attempt)` and `brief_id` are unique. A retry always creates a new run and a new brief.

#### `endpoints`

Fields: `id`, `home_id`, `adapter`, `external_id`, `kind`, `state`, `semantic_state`, `metadata_json`, `last_seen_at`, `generation`, `created_at`, `closed_at`.

`external_id` is internal. Users are never required to type it.

#### `decisions`

Fields: `id`, `job_id`, `run_id`, `key`, `question`, `choices_json`, `context_json`, `state`, `answer`, `answered_by`, `generation`, `created_at`, `answered_at`, `expires_at`.

`(run_id, key)` is unique. Repeated identical questions are idempotent.

#### `approvals`

Fields: `id`, `home_id`, `job_id`, `action`, `target_json`, `scope_json`, `requested_by`, `approved_by`, `method`, `state`, `receipt_hash`, `created_at`, `approved_at`, `expires_at`, `consumed_at`.

An approval is bound to one described action and cannot be widened after creation.

#### `events`

Fields: `home_id`, `seq`, `event_id`, `aggregate_type`, `aggregate_id`, `job_id`, `run_id`, `kind`, `severity`, `dedupe_key`, `payload_json`, `actor_type`, `actor_id`, `created_at`.

`(home_id, seq)` is the ordered stream key. `event_id` is globally unique. `(actor_id, dedupe_key)` is unique when a deduplication key is supplied.

#### `consumer_cursors`

Fields: `home_id`, `consumer_id`, `last_acked_seq`, `lease_id`, `generation`, `updated_at`.

Consumers receive events at least once. They acknowledge a sequence only after completing their local action.

#### `requests`

Fields: `home_id`, `request_id`, `actor_type`, `actor_id`, `command`, `input_sha256`, `state`, `operation_id`, `response_json`, `error_json`, `created_at`, `completed_at`.

`(home_id, request_id)` is unique. Reusing a request identifier with different input returns a conflict. Completed requests return the stored result.

#### `operations`

Fields: `id`, `home_id`, `aggregate_type`, `aggregate_id`, `kind`, `state`, `idempotency_key`, `step`, `attempt`, `next_attempt_at`, `input_json`, `observation_json`, `result_json`, `error_json`, `generation`, `created_at`, `updated_at`, `completed_at`.

This table records sagas for external work such as creating a worktree, starting an endpoint, opening a PR, or merging. `(home_id, kind, idempotency_key)` is unique.

#### `artifacts`

Fields: `id`, `job_id`, `run_id`, `kind`, `name`, `media_type`, `storage_uri`, `sha256`, `size_bytes`, `metadata_json`, `created_at`.

Artifacts are content-addressed where practical. Initial kinds include `brief`, `report`, `patch`, `log`, `diff`, and `verification`.

#### `checks`

Fields: `id`, `job_id`, `run_id`, `head_sha`, `kind`, `name`, `command_json`, `state`, `exit_code`, `evidence_artifact_id`, `started_at`, `finished_at`, `invalidated_at`.

Passing evidence is valid only for the recorded `head_sha`.

#### `deliveries`

Fields: `id`, `job_id`, `run_id`, `mode`, `state`, `head_sha`, `base_sha`, `target_branch`, `forge`, `external_ref`, `url`, `approval_id`, `evidence_json`, `generation`, `created_at`, `updated_at`, `delivered_at`.

#### `leases`

Fields: `id`, `home_id`, `resource_type`, `resource_id`, `holder`, `purpose`, `generation`, `acquired_at`, `heartbeat_at`, `expires_at`, `released_at`.

`(resource_type, resource_id)` has at most one active generation.

#### `audit_entries`

Fields: `home_id`, `seq`, `entry_id`, `request_id`, `actor_type`, `actor_id`, `action`, `target_json`, `policy_result`, `approval_id`, `before_hash`, `after_hash`, `created_at`.

Audit entries are append-only through the public service API.

### 12.2 Stored briefs

Each run has one immutable brief. The file and database record include:

- schema version and content hash;
- job and run identifiers;
- title and objective;
- relevant context;
- in-scope work;
- explicit exclusions;
- acceptance criteria;
- required verification;
- delivery mode;
- authority limits;
- dependency outputs;
- expected artifacts;
- worker event protocol;
- base revision and project identity.

Editing a job after dispatch does not edit the active brief. A small clarification creates an immutable `run.amended` event and amendment artifact; it does not create another brief row. A change to scope, authority, acceptance criteria, base revision, or delivery mode requires cancelling the run and creating a new run with a new brief.

## 13. State machines

State axes remain separate. A missing terminal pane must not automatically mean that a job failed or completed.

### 13.1 Job state

```text
draft -> queued -> dispatching -> active
active -> blocked -> active
active|blocked -> paused -> active|blocked
active -> verifying
verifying -> waiting -> verifying
verifying -> ready
ready -> waiting -> ready
ready -> complete
dispatching -> queued            (safe dispatch recovery)
active|blocked|verifying|waiting -> failed
failed -> queued                 (retry)
draft|queued|dispatching|active|blocked|paused|verifying|waiting|ready -> cancelled
```

`waiting` means CrewBoss is waiting for a named external condition, such as CI or an approval. `state_reason` identifies that condition. `ready` means required evidence is valid and delivery may proceed.

Cancelling during `dispatching` first marks the dispatch operation `cancel_requested`. The service unwinds or records every external saga step before it commits `cancelled`. If cleanup cannot finish, the job remains visible with `state_reason=cancel_cleanup`; it is never hidden as successfully cancelled.

### 13.2 Run state

```text
preparing -> dispatched -> active -> succeeded
dispatched|active -> blocked -> active
active|blocked -> suspended -> active|blocked
preparing|dispatched|active|blocked|suspended -> failed
preparing|dispatched|active|blocked|suspended -> cancelled
dispatched|active|blocked -> lost
```

`lost` means the endpoint disappeared without an authoritative worker result. Reconciliation may restore the endpoint or create a controlled retry. It must not convert `lost` to `succeeded` from screen text.

### 13.3 Endpoint state

```text
creating -> live -> idle -> closed
creating|live|idle -> missing
missing -> live|closed
any observable state -> unknown
```

`semantic_state` is adapter-specific and may include `starting`, `thinking`, `waiting_input`, `running_command`, or `exited`. It is diagnostic and routing input, not completion evidence.

### 13.4 Delivery state

```text
none -> pending -> awaiting_approval -> delivering -> delivered
pending|awaiting_approval|delivering -> failed
failed -> pending
```

### 13.5 Decision state

```text
open -> answered
open -> superseded
open -> expired
```

Expiry does not guess an answer and does not mark the run successful or failed. The run and job remain blocked with `state_reason=decision_expired`. The service emits an urgent boss event. The operator may cancel or retry the job, or provide an answer that creates a replacement decision linked to the expired one and resumes the worker if its endpoint is still usable.

All transitions are checked in the domain layer and committed with the expected generation. A stale caller receives `state_conflict`; it does not overwrite newer state.

## 14. Event and worker protocol

### 14.1 Authoritative worker events

Workers use internal commands supplied in their brief:

```bash
crewboss worker progress --message-file progress.md
crewboss worker question --key choose-api --message-file question.md
crewboss worker complete --summary-file result.md --artifact report.md
crewboss worker fail --code tests_failed --message-file failure.md
crewboss worker heartbeat
```

Each worker receives a scoped capability token through a protected file or environment variable.

The token is:

- stored only as a hash in SQLite;
- bound to one run and generation;
- limited to the worker event actions;
- short-lived and renewable only while the run is active;
- revoked when the run ends or is replaced.

An authenticated heartbeat received before expiry extends `capability_expires_at` while the run is active, capped by the configured maximum run lifetime. It renews the existing opaque token; there is no separate renewal endpoint. An expired token cannot renew itself.

The service validates the token and writes the event and state transition before acknowledging it. A worker may retry after a lost response without creating a duplicate because every mutation carries an idempotency key.

The worker CLI creates an event UUID before sending and keeps an unsent envelope in its protected runtime directory. A retry reuses that UUID. Completion and failure transitions also reject a second different terminal event for the same run generation.

### 14.2 Event delivery

Event delivery is at least once.

- Every home has a monotonic `seq`.
- Consumers read after their stored cursor.
- A consumer acknowledges only after its side effect or response is safe.
- A consumer crash may replay an event.
- All consumers must therefore be idempotent.
- Retention may archive old payloads only after every required consumer passes the sequence and audit policy allows it.

The stable event representation is:

```json
{
  "schema": "crewboss.event.v1",
  "home": "default",
  "seq": 42,
  "event_id": "0198...",
  "kind": "run.question",
  "aggregate": {"type": "run", "id": "0198...", "generation": 3},
  "job_id": "0198...",
  "run_id": "0198...",
  "severity": "action",
  "payload": {},
  "actor": {"type": "worker", "id": "0198..."},
  "created_at": "2026-08-02T12:00:00.000000Z"
}
```

### 14.3 Event kinds

The initial stable event namespace includes:

- `project.added`, `project.changed`, `project.archived`;
- `job.created`, `job.queued`, `job.blocked`, `job.suspended`, `job.resumed`, `job.ready`, `job.completed`, `job.failed`, `job.cancelled`;
- `run.preparing`, `run.started`, `run.progress`, `run.question`, `run.amended`, `run.suspended`, `run.resumed`, `run.completed`, `run.failed`, `run.lost`;
- `endpoint.changed`, `endpoint.missing`;
- `decision.opened`, `decision.answered`, `decision.expired`;
- `check.started`, `check.passed`, `check.failed`, `check.invalidated`;
- `delivery.requested`, `delivery.awaiting_approval`, `delivery.completed`, `delivery.failed`;
- `approval.requested`, `approval.granted`, `approval.denied`, `approval.expired`;
- `boss.attached`, `boss.detached`, `boss.wake_requested`;
- `lead.created`, `lead.routed`, `lead.retired`;
- `system.warning`, `system.reconciled`.

New event kinds may be added in a minor protocol version. Existing meanings must not change inside a major version.

### 14.4 Bash compatibility protocol

During migration, the Bash adapter reads the legacy `events.jsonl` records that workers append with `crewboss emit` (`blocked` and `done`). It maps `blocked` to a free-text `run.question` and `done` to `run.completed`, using the stored legacy `crew_id` and `run_id`. The legacy `event_id` becomes the deduplication key, and the raw payload is preserved. Terminal text is never consulted for completion.

## 15. Public CLI contract

### 15.1 Command groups

```text
crewboss init
crewboss doctor
crewboss status
crewboss events
crewboss config show|validate
crewboss daemon start|status|stop|serve

crewboss project add|list|show|sync|pause|archive|remove
crewboss boss attach|status|wake|mode|detach
crewboss job create|dispatch|list|show|wait|send|answer
crewboss job cancel|retry|promote|suspend|resume|remove
crewboss job diff|logs|report|verify|deliver
crewboss lead create|list|show|route|pause|resume|retire
crewboss approval list|show|grant|deny
crewboss backup create|list|verify|restore
crewboss migrate inspect|apply
crewboss skill install|status|update
```

Compatibility aliases remain during the deprecation window:

```text
spawn send wait read focus close open remove list
```

Aliases accept the old arguments, print one clear deprecation warning in human mode, and map to a project-scoped job when unambiguous. They never ask for pane IDs, worktree paths, or internal timeouts.

The compatibility alias `close` maps to `job suspend`. It records the job and run as suspended before safely closing the worker endpoint. The alias `open` maps to `job resume`. Resume restores the same run only when the harness adapter reports verified resume support; otherwise it returns `backend_unavailable` and recommends `job retry`. `remove` maps to `job remove`, safely cleans CrewBoss-owned runtime resources, and archives the logical job. It does not erase events, approvals, or audit evidence.

### 15.2 Names and selectors

- Project slugs are unique in a CrewBoss home.
- Job names are unique in a project.
- `job-name` works when globally unambiguous.
- `project/job-name` always works.
- UUIDs are accepted for automation but are not the normal user interface.
- Internal pane, process, and worktree identifiers do not appear as required arguments.

### 15.3 Naming derivation

Naming carries forward today's `scripts/lib/naming.sh` derivation rules, with one explicit normalization change: canonical job names are lowercase. Contract fixtures record both the preserved rules and that change.

1. An explicit `--name` wins after validation and lowercase normalization.
2. Otherwise CrewBoss takes the first Jira-style key matching `[A-Za-z][A-Za-z0-9]+-[0-9]+` and lowercases it for the job name, so `CB-142 add retry limits` becomes `cb-142`.
3. With no ticket, CrewBoss removes ticket-like text, lowercases the task, replaces non-alphanumeric runs with spaces, takes the first four words, and joins them with `-`.
4. Empty derived names fail with `invalid_argument`.
5. A name collision inside the project fails with `state_conflict` and asks for `--name`; CrewBoss never silently attaches to the existing job or adds a random suffix.

Branch derivation keeps the current convention:

- explicit `--branch` wins;
- otherwise the prefix comes from project `branch_prefix`, then compatibility variable `CB_PREFIX`, then normalized Git `user.name`, with `crew` as the final fallback;
- a ticket and slug produce `<prefix>-<TICKET>-<slug>`;
- a ticket alone produces `<prefix>-<TICKET>`;
- a slug alone produces `<prefix>-<slug>`;
- explicit `--base` wins, then the registered project base branch, then compatibility variable `CB_BASE` during the Bash migration window.

The ticket remains uppercase in the branch for compatibility. Imported uppercase crew names remain accepted aliases for their canonical lowercase job names. Go contract tests use the existing Bash naming fixtures before the Bash engine is frozen.

### 15.4 JSON envelope

Every command supports `--json`. Success uses:

```json
{
  "schema": "crewboss.cli.v1",
  "ok": true,
  "command": "job.show",
  "request_id": "0198...",
  "data": {},
  "warnings": []
}
```

Failure uses:

```json
{
  "schema": "crewboss.cli.v1",
  "ok": false,
  "command": "job.deliver",
  "request_id": "0198...",
  "error": {
    "code": "approval_required",
    "message": "Local merge needs operator approval.",
    "retryable": false,
    "details": {}
  }
}
```

JSON output writes only the envelope to standard output. Human diagnostics go to standard error. Commands that mutate state accept `--request-id`; retrying the same request returns the original result or its current operation record.

### 15.5 Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Reserved. CrewBoss never intentionally returns it; a shell or operating-system failure may still produce it. |
| 2 | Invalid command or arguments. |
| 3 | Requested object not found. |
| 4 | State or generation conflict. |
| 5 | Approval is required. |
| 6 | Required adapter or backend is unavailable. |
| 7 | Retryable failure or partial external operation. |
| 8 | Safety policy refused the action. |
| 9 | Internal invariant or storage failure. |

Stable error codes include `invalid_argument`, `not_found`, `ambiguous_selector`, `state_conflict`, `approval_required`, `policy_refused`, `backend_unavailable`, `external_retryable`, `invalid_capability`, `unsupported_protocol`, `integrity_failure`, and `internal`. A new code may be added in version 1, but the meaning of an existing code cannot change.

### 15.6 API boundary

The local service exposes versioned HTTP/JSON over its Unix socket. The CLI is the supported public client in 1.0. The API schema is documented and tested so later graphical or remote clients do not need database access.

Clients never write SQLite directly. Unsupported protocol versions fail clearly. A one-minor-version compatibility window is required during upgrades.

### 15.7 Local API resources

The initial resource map is:

```text
GET    /v1/health
GET    /v1/status
GET    /v1/events
GET    /v1/events/stream
POST   /v1/consumers/{id}:ack

GET    /v1/projects
POST   /v1/projects
GET    /v1/projects/{selector}
POST   /v1/projects/{selector}:sync

GET    /v1/jobs
POST   /v1/jobs
GET    /v1/jobs/{selector}
POST   /v1/jobs/{selector}:dispatch
POST   /v1/jobs/{selector}:cancel
POST   /v1/jobs/{selector}:retry
POST   /v1/jobs/{selector}:verify
POST   /v1/jobs/{selector}:deliver

POST   /v1/boss:attach
POST   /v1/boss:heartbeat
POST   /v1/boss:detach

GET    /v1/approvals
POST   /v1/approvals/{id}:grant
POST   /v1/approvals/{id}:deny

POST   /v1/worker/events
POST   /v1/worker/heartbeat
```

The two `/v1/worker/*` routes are served only through the run-specific ingress. They are not exposed by the control socket.

Mutations require `X-CrewBoss-Request-ID`. Conditional aggregate updates use `If-Match: <generation>`. Event streaming uses server-sent events and resumes with `Last-Event-ID`; `GET /v1/events` remains the durable catch-up path.

Socket ownership and operating-system peer identity prove only that a caller belongs to the local user account. They do not prove that the process is the operator, boss, or worker. Control requests therefore also require a role credential outside the worker sandbox. Approval grants require a fresh local TTY confirmation or another supported attested operator action; same-user peer credentials alone never grant approval authority.

Workers do not receive the control socket. Each run receives a separate ingress socket or inherited file descriptor that exposes only worker events and heartbeat, plus its scoped bearer capability. The harness sandbox must deny the control socket, SQLite state, configuration, other run directories, and boss or operator credentials. No API accepts a caller role from an untrusted request body.

## 16. Job types and brief creation

### 16.1 Initial job types

**Build** changes project files and can use `verified-pr`, `direct-pr`, or `local` delivery.

**Explore** investigates a question and returns a report. It uses `report` delivery and should not change the project branch.

Later types:

- **Review:** read-only findings bound to a revision;
- **Operate:** persistent or scheduled operational work.

### 16.2 Classification

The coordinating agent may suggest a type, scope, checks, dependencies, and delivery mode. The stored request always shows the final selection. Classification cannot silently increase authority.

### 16.3 Brief quality gate

A Build brief cannot dispatch until it has:

- one testable objective;
- explicit scope and exclusions;
- acceptance criteria;
- a base reference;
- verification commands or an explicit reason none apply;
- a delivery mode;
- an authority profile.

An Explore brief replaces verification commands with research questions, required sources or local evidence, and a report format.

The service validates required fields. A model may improve prose, but deterministic validation decides whether dispatch is allowed.

## 17. Scheduling, dependencies, and routing

### 17.1 Eligibility

A queued job is eligible when:

- all `blocks` dependencies are complete;
- its project and lead are not paused;
- fleet, project, lead, harness, and backend limits allow another run;
- required adapters pass health checks;
- required authority is already present or dispatch itself is safe;
- no active run already owns the job lease.

### 17.2 Order

Eligible jobs are ordered by:

1. explicit priority;
2. jobs that unblock the most downstream work;
3. oldest ready time;
4. fair sharing between projects.

The scheduler records why a job was selected or skipped. There is no hidden model decision in the deterministic scheduling loop.

### 17.3 Limits

Configuration provides separate limits for the fleet, each project, each Crew Lead, each harness, and each session backend. A value of zero pauses new dispatch without stopping active work.

### 17.4 Routing

Routing chooses, in order:

1. an explicitly named Crew Lead;
2. the most specific matching lead rule;
3. the project default;
4. the active CrewBoss.

Ties are reported as a decision instead of being guessed. Routing records the matched rule and selected harness profile.

## 18. Project and worktree lifecycle

### 18.1 Project registration

`project add` resolves and stores:

- canonical repository root;
- repository identity and remotes;
- default branch and current base SHA;
- selected worktree, session, harness, and forge adapters;
- project-specific verification and policy configuration.

Moving a checkout does not create a second project if its repository identity matches. `project sync` updates safe derived fields and reports important changes for approval.

### 18.2 Isolation rule

The coordinator and service never edit the primary checkout as part of a worker run. Build workers receive isolated worktrees. Explore workers use a read-only checkout or a disposable worktree according to adapter capability.

### 18.3 Dispatch saga

Dispatch is a recorded saga:

1. acquire the job lease;
2. freeze and hash the brief;
3. reserve branch and worktree names;
4. create the worktree;
5. create the session endpoint;
6. start the selected harness;
7. deliver the brief and capability;
8. receive a worker protocol acknowledgement;
9. mark the run active.

Every completed step is recorded. If a later step fails, the service either compensates safely or leaves a visible recoverable operation. It never forgets an orphaned worktree or pane.

### 18.4 Cleanup

Cleanup checks:

- run state is terminal;
- no uncommitted or untracked user work would be lost;
- delivery evidence is stored;
- no other active lease references the endpoint or worktree;
- branch deletion matches policy.

A force cleanup needs exact targets and operator approval. Cleanup reports what was removed and whether recovery remains possible.

## 19. Adapter contracts

Adapters expose typed operations and normalized errors. Shell output is never parsed outside the adapter that owns it.

### 19.1 Session adapter

Required operations:

- `Probe`
- `CreateEndpoint`
- `CloseEndpoint`
- `FocusEndpoint`
- `ReadVisibleOutput`
- `WakeEndpoint`
- `ObserveEndpoint`
- `ListOwnedEndpoints`

Herdr is the reference adapter. Tmux reaches parity before 1.0. Other backends may ship as experimental only when capability reporting is honest.

`ReadVisibleOutput` is diagnostic. It never represents a full transcript or authoritative completion.

### 19.2 Worktree adapter

Required operations:

- `Probe`
- `ResolveRepository`
- `CreateWorktree`
- `InspectWorktree`
- `Diff`
- `Merge`
- `RemoveWorktree`
- `ListOwnedWorktrees`

Worktrunk is the reference adapter. A native Git adapter is optional but useful for portability. The domain layer owns lifecycle policy; an adapter owns tool syntax.

### 19.3 Harness adapter

Required operations:

- `Probe`
- `Capabilities`
- `Start`
- `Resume`
- `Send`
- `ObserveSemanticState`
- `RequestStop`
- `Version`

Each adapter declares support for resume, non-interactive input, structured hooks, permission controls, model selection, reasoning-effort selection, and worker filesystem isolation. CrewBoss must not claim a capability that has not passed a live test.

Claude and Codex are required for 1.0. OpenCode is the next supported harness. Additional harnesses use the same contract.

### 19.4 Forge adapter

Required operations:

- `Probe`
- `FindOrCreatePullRequest`
- `ReadChecks`
- `ReadReviews`
- `MergePullRequest`
- `ClosePullRequest`
- `ResolveRevisionURL`

GitHub through `gh` is the reference adapter. GitLab follows after the GitHub contract is stable.

### 19.5 Capability negotiation

Every adapter returns a versioned capability document. A workflow fails before side effects if required capabilities are missing. Experimental support appears in `doctor` and JSON output; it is never described as verified support.

Harness capability documents report `worker_isolation` as `enforced`, `advisory`, or `none`. `enforced` requires a live conformance probe proving that the worker cannot open the control socket, state database, config, boss credentials, or another run directory while it can still use its own worktree and event ingress. `doctor` runs this probe for every supported harness and profile. A version change invalidates the cached result until the probe passes again.

## 20. Supervision, wake-up, and recovery

### 20.1 Supervisor

The local service runs a deterministic supervisor that watches:

- committed worker events;
- adapter endpoint state;
- worker and boss heartbeats;
- worktree existence and Git state;
- pull-request checks and review state;
- lease expiry;
- scheduled retry times.

The supervisor writes a durable event before waking an agent. It uses bounded backoff and jitter for external polling. An idle fleet causes zero model calls.

### 20.2 Wake queue

Events that need coordinator judgment enter a durable boss queue. Examples are an ambiguous worker question, repeated verification failure, or a policy conflict.

The queue:

- coalesces compatible low-priority events;
- preserves urgent decisions;
- records delivery attempts;
- retries a failed wake safely;
- never drops an event because no boss is attached.

### 20.3 Turn-end guard

The skill instructs an attached coordinating agent to run `crewboss boss status --json` before ending a supervision turn. Harness adapters may also install a supported turn-end hook. The guard reports unacknowledged urgent events and expiring leases.

The guard is a safety net, not the source of truth. A missed hook leaves events durable.

### 20.4 Restart reconciliation

At startup the service:

1. verifies database and migration integrity;
2. expires stale leases;
3. lists owned endpoints and worktrees through adapters;
4. compares them with recorded resources;
5. restores live observations;
6. marks unresolved resources `missing` or recoverable;
7. resumes pending external operations by idempotency key;
8. emits one reconciliation summary.

It never infers success only because an endpoint exited or a branch exists.

### 20.5 Away and autonomous modes

Boss modes are:

- `attended`: ask promptly for operator decisions;
- `away`: continue only actions already allowed by policy and queue decisions;
- `autonomous`: allow the configured autonomous permission profile, still respecting approval boundaries.

Mode changes are audited. `autonomous` does not mean unrestricted host access or self-approved merges.

## 21. Authority and security model

### 21.1 Actors

The policy engine distinguishes:

- operator;
- attached CrewBoss;
- Crew Lead;
- Crew Worker;
- local service;
- adapter;
- external forge or hook.

Each action records its actor and effective authority.

### 21.2 Permission profiles

| Profile | Intended behavior |
| --- | --- |
| `safe` | Use an enforced sandbox to read allowed repository data and prepare plans or reports. No source mutation or network delivery. |
| `standard` | Use an enforced sandbox and isolated worktree, run declared checks, and prepare delivery. Merge and destructive cleanup need approval. |
| `autonomous` | Use an enforced sandbox to perform pre-approved project actions, including selected delivery operations, within exact policy limits. |
| `unsafe-host` | Run without a verified same-user isolation boundary. Intended only for controlled environments. Requires explicit operator activation and expires. |

No harness receives a dangerous bypass flag merely because it is installed. The harness adapter translates a CrewBoss permission profile to supported vendor controls and reports any gap.

`safe`, `standard`, and `autonomous` require `worker_isolation=enforced`. Their sandbox denies the CrewBoss control socket, state and configuration roots, operator and boss credentials, unrelated worktrees, and other run directories. It exposes only the run's worktree, declared tool paths, and per-run event ingress. Dispatch fails closed if any required denial cannot be proved.

`unsafe-host` is the compatibility escape hatch for a harness that cannot enforce these denials. In that profile, scoped APIs and policy reduce accidental or confused-deputy mistakes, but they do not defend against a hostile process running under the same OS user. The CLI must show this limitation before dispatch and store the operator's expiring approval.

### 21.3 Actions requiring approval by default

- merging to a protected or primary branch;
- force push, history rewrite, or branch deletion with uncertain ownership;
- deleting a dirty worktree or untracked files;
- running a command outside the registered repository and data directories;
- changing secrets, credentials, permissions, or security policy;
- publishing data outside configured forge targets;
- taking over a live boss lease;
- enabling `unsafe-host`;
- widening a running job's scope or authority.

Creating a job, sending a message to its worker, reading owned state, and stopping a CrewBoss-owned worker are normally reversible in-scope actions.

### 21.4 Approval receipt

An approval records action, exact target, scope, approver identity, method, expiry, and whether it is single-use. The service hashes the receipt and binds it to the external operation. Changing the action invalidates the approval.

The attached agent cannot approve its own request. Strong approval comes from a fresh local operator interaction or a supported attested user action. A same-user socket peer, boss message, or worker message is never accepted as operator approval. Reusable approval credentials remain outside every worker sandbox.

### 21.5 Repository trust boundary

Repository files, issue text, worker output, and pull-request comments are untrusted input.

- No untrusted value is interpolated into a shell command.
- Commands use argument arrays.
- Paths are resolved and checked against allowed roots.
- Symlink traversal is checked before writes and cleanup.
- Logs redact registered secrets and capabilities.
- Enforced worker sandboxes cannot open the control socket, state database, config, or another run's files.
- The per-run ingress exposes only heartbeat and worker event actions; its token cannot call boss, approval, configuration, or delivery APIs.
- Direct database access is a trusted service operation. File mode `0600` protects against other OS users, not another process with the same UID.
- Forge comments cannot change authority without operator confirmation.

These are security guarantees only for adapters whose live isolation probe passes. Under `unsafe-host`, they are API rules rather than a boundary against malicious same-UID code.

## 22. Verification and delivery

### 22.1 Delivery modes

| Mode | Meaning |
| --- | --- |
| `verified-pr` | Run required local checks, optional review agents, open or update a PR, wait for required remote checks, then request or perform merge according to policy. |
| `direct-pr` | Run the minimum declared checks and open or update a PR without the full review pipeline. |
| `local` | Verify and merge into a local target branch without opening a PR. |
| `report` | Store and present a research or review artifact. No code delivery. |

A later `draft-pr` mode may publish early work while keeping delivery incomplete.

### 22.2 Verification evidence

Every check stores:

- the exact `head_sha`;
- command arguments or external check identity;
- start and finish times;
- exit result;
- captured evidence artifact;
- tool version when available.

Any commit after a check invalidates that check. A delivery cannot use evidence from another revision.

### 22.3 Verified PR pipeline

The default robust pipeline is:

1. worker completion event;
2. inspect clean worktree and produced commits;
3. run project checks;
4. run configured review jobs in parallel;
5. resolve required findings or record accepted exceptions;
6. create or update the PR idempotently;
7. wait for required CI and review state;
8. confirm head SHA has not changed;
9. obtain merge approval when policy requires it;
10. merge through the forge adapter;
11. store delivery evidence;
12. clean up owned resources safely.

Red required checks are never merged. A review exception must be a named, scoped approval record.

### 22.4 Local delivery

Local delivery uses the worktree adapter's safe merge support. It proves the target repository and target branch, checks for a dirty primary checkout, and records pre-merge and post-merge SHAs. If the target changes during verification, the delivery returns to `pending` and re-verifies.

### 22.5 Explore promotion

Promotion links the report artifact to a new Build job. It creates the Build run from the current clean base branch, not from an Explore worker's modified directory. The promoted brief states which conclusions are evidence and which remain assumptions.

## 23. Crew Leads

A Crew Lead is a persistent manager for a defined domain, such as frontend, release engineering, or one large project.

### 23.1 Properties

- It has a durable identity, scope, routing rules, queue, and optional endpoint.
- Its logical context and worker tokens are isolated from other leads.
- It can supervise jobs in scope and return structured status to CrewBoss.
- It cannot grant authority, merge outside policy, or create another Crew Lead.
- It does not invent work while idle.
- Idle is a healthy state and should cost zero model tokens.

### 23.2 Lifecycle

```text
creating -> active -> paused -> active
creating|active|paused -> retiring -> retired
active -> degraded -> active|retiring
```

Retirement refuses to discard active work. The operator may re-route jobs, wait for completion, or explicitly approve cancellation before teardown.

### 23.3 Structured return protocol

Crew Leads use the same event and decision system as workers, with a larger but still scoped capability. They report job changes, routing conflicts, and summaries as structured events. CrewBoss does not scrape their chat output to learn state.

## 24. Fleet visibility and operations

### 24.1 `crewboss status`

The default view shows:

- daemon and database health;
- attached boss and mode;
- active, blocked, waiting, and failed job counts;
- active workers by project and lead;
- open decisions and approvals;
- verification and delivery work;
- stale endpoints or leases;
- adapter health.

### 24.2 Logs and reports

`job logs` separates:

- durable CrewBoss events;
- adapter diagnostic output;
- captured worker output, when supported;
- verification evidence.

A visible pane snapshot is clearly labelled as a snapshot. It is never called a transcript.

`job report` creates a portable Markdown summary with links or paths to artifacts, commits, checks, decisions, and delivery evidence.

### 24.3 Health and alarms

The supervisor raises warnings for:

- missing endpoint with active run;
- no worker heartbeat beyond the configured threshold;
- repeated start or wake failure;
- expiring approval or boss lease;
- event consumer lag;
- database checkpoint failure;
- worktree or branch drift;
- delivery waiting too long on an external system.

Thresholds live in configuration. They are not public CLI timeout arguments on every command.

## 25. Backward compatibility and migration

### 25.1 Compatibility promise

The old commands remain supported through the full 1.x release line. They may be removed only in 2.0 or later, after deprecation warnings have shipped in at least two minor releases and the published migration guide is complete. Removal depends on this version window, not a machine-local usage counter. CrewBoss sends no usage telemetry by default.

### 25.2 Imported state

The migration tool reads, without modifying:

- current `crew.json` registry;
- the merged PR #2 `events.jsonl` and `event-state.json` formats;
- known CrewBoss-owned Worktrunk worktrees;
- known Herdr endpoints.

`migrate inspect` produces an import plan and conflicts. `migrate apply` first creates a timestamped backup, imports records in one database transaction, then reconciles external resources.

### 25.3 Mapping

- old crew name -> project-scoped canonical job name plus a compatibility alias preserving the old case;
- old branch/path/pane/agent -> first imported run and endpoint;
- old `task` and latest prompt -> job objective and run amendment history;
- old blocked/done event -> durable event with imported source metadata;
- old closed crew -> terminal endpoint plus preserved job/run state.

An ambiguous repository or name is not guessed. It becomes an import conflict with a suggested command.

### 25.4 Rollout switch

During the bridge release:

- `CREWBOSS_ENGINE=bash` selects the old implementation;
- `CREWBOSS_ENGINE=service` selects the new implementation;
- the default changes only after contract and migration tests pass;
- the Bash engine is frozen as a rollback path and does not implement `crewboss.cli.v1`;
- rollback keeps the pre-migration backup and does not pretend new service state can always be represented by the old registry.

## 26. Incremental roadmap

Each release is independently releasable. Reliability gates are mandatory even when they take more work. Human development cost is not used to remove a correctness requirement. Version names replace numbered roadmap phases so they cannot collide with the repository's historical phase documents and branch names.

### v0.2: Confirm and tag the event baseline

**Objective:** Verify merged PR #2 as the trustworthy Bash migration source and tag it. The event implementation is already on main; this release does not plan it again.

**Deliver:**

- run the event, wait, registry, endpoint-reconciliation, and full repository suites against current main;
- capture migration fixtures for `crew.json`, `events.jsonl`, `event-state.json`, and naming derivation;
- confirm strict sequence validation, locked writes, crew/run identity checks, FIFO selection, pending checkpoints, and at-least-once recovery;
- confirm README, `SKILL.md`, CLI help, and `AGENTS.md` describe the merged behavior;
- record verified and experimental harness capabilities;
- tag the accepted mainline as v0.2, fixing only gaps found by this gate.

**Public surface:** Existing commands, multi-name `wait`, and durable `blocked` and `done` events through `crewboss emit`.

**Acceptance gate:**

- all current main tests pass;
- concurrent event writers produce no lost or malformed records;
- a crash after event output may replay the pending event but cannot lose it;
- a missing pane never becomes successful only from endpoint state;
- no runtime path uses terminal text or a `TASKDONE` sentinel as completion;
- documentation states exactly what is verified and what remains experimental.

### v0.3: Trustworthy Bash bridge

**Objective:** Remove the largest safety and interface risks before changing languages.

**Deliver:**

- project identity on every crew;
- commands independent of current working directory;
- provisional registry records and compensation for spawn/open failures;
- no hard-coded unsafe harness mode;
- `doctor` with adapter and version checks;
- explicit labels for pane snapshots;
- frozen behavior and naming fixtures for the rollback engine.

This release fixes Bash safety and repository-scoping defects only. It does not implement `crewboss.cli.v1`, request idempotency, or the new exit-code contract. Those fixtures are written now, but Go is their only implementation in v0.4.

**Public surface:** `doctor`, project-qualified crew selectors, and otherwise frozen human-oriented Bash commands.

**Acceptance gate:**

- two repositories may use the same crew name without collision;
- `remove`, `close`, and `open` work from a third directory;
- injected failures at every spawn step leave either no resource or a recorded recoverable resource;
- live Herdr and Worktrunk smoke tests pass;
- dangerous harness permissions require explicit configuration;
- the Bash engine has no new JSON envelope or idempotency implementation;
- frozen rollback and naming fixtures pass.

### v0.4: Durable Go core

**Objective:** Introduce the service and SQLite without changing normal user commands.

**Deliver:**

- Go CLI and Unix-socket service;
- XDG home layout and owner-only permissions;
- SQLite migrations and WAL configuration through `modernc.org/sqlite`;
- core projects, jobs, runs, endpoints, events, cursors, requests, operations, leases, and audit tables;
- transactional domain state changes;
- idempotent command API;
- the only implementation of `crewboss.cli.v1`, stable exit codes, and `--request-id`;
- contract fixtures written before the service implementation;
- Bash CLI shim and engine switch;
- `migrate inspect` and `migrate apply`;
- service-owned backup creation, verification, and restore;
- Sigstore-signed release checksums, plus Developer ID signing and notarization on macOS.

**Public surface:** `daemon`, `config`, `backup`, `migrate`, and compatibility commands backed by the service.

**Acceptance gate:**

- frozen Bash regression tests pass for the rollback engine without requiring v1 JSON output;
- `crewboss.cli.v1` fixtures pass against the Go engine only;
- current main migration fixtures import without data loss;
- killing the service between external saga steps recovers safely;
- 100 concurrent event writes have unique ordered sequences and no loss;
- stale generations cannot overwrite new state;
- the socket refuses another local user;
- same-user peer credentials alone cannot obtain operator, boss, or approval authority;
- the reference binary builds with `CGO_ENABLED=0` for macOS and Linux on amd64 and arm64, and release verification accepts only the pinned signing identity and checksums;
- a clean rollback to the stored backup is documented and tested before new-only work is created.

### v0.5: Projects and Jobs

**Objective:** Add the durable multi-project work model.

**Deliver:**

- project registry and canonical repository identity;
- Build and Explore job types;
- immutable run briefs and content-addressed artifacts;
- job dependencies with cycle detection;
- deterministic scheduler and concurrency limits;
- dispatch saga with worktree and endpoint recovery;
- explicit worker event commands, per-run ingress, and scoped capabilities;
- enforced worker isolation for `safe`, `standard`, and `autonomous` profiles;
- Explore reports and promotion to Build;
- project, job, diff, logs, and report commands.

**Public surface:** `project ...`, `job ...`, and internal `worker ...` protocol.

**Acceptance gate:**

- register three repositories and dispatch ten jobs without name collision;
- dependency order is stable and explainable;
- a worker retry cannot duplicate completion or a question;
- with `worker_isolation=enforced`, a worker cannot open the control socket, state database, config, credentials, or another run's files;
- without enforced isolation, safe profiles refuse dispatch and only explicitly approved `unsafe-host` is available;
- Explore cannot enter code delivery;
- promotion begins from a clean current base;
- no coordinator write occurs in a primary checkout;
- every failed dispatch step is reconciled or safely compensated.

### v0.6: Always-on supervision

**Objective:** Continue supervision without an always-running model conversation.

**Deliver:**

- boss attach, heartbeat, generation lease, wake, mode, and detach;
- durable boss event queue and cursor;
- service supervisor and semantic endpoint observation;
- worker and boss heartbeat alarms;
- turn-end guard and supported harness hooks;
- full startup reconciliation;
- attended and away modes;
- OS desktop notification adapter;
- bounded retry policies and dead-letter visibility.

**Public surface:** `boss ...`, `events`, expanded `status`.

**Acceptance gate:**

- detach and reattach from another terminal without losing events;
- an expired old boss cannot acknowledge events after takeover;
- kill and restart the service, boss endpoint, and one worker endpoint in separate tests;
- each recovery produces one clear state and no false success;
- no model process is called for an idle fleet;
- blocked questions remain queued for at least seven days or configured retention;
- supervisor retries are bounded and visible.

### v0.7: Verification and delivery

**Objective:** Turn worker output into evidence-backed results.

**Deliver:**

- checks, approvals, and deliveries tables and workflows;
- revision-bound local verification;
- `verified-pr`, `direct-pr`, `local`, and `report` modes;
- GitHub/`gh` forge adapter;
- PR creation/update, CI wait, review status, and merge;
- review jobs and finding resolution;
- local merge with branch-drift protection;
- safe cleanup and delivery report.

**Public surface:** `job verify`, `job deliver`, `approval ...`, approval prompts, and delivery status.

**Acceptance gate:**

- changing HEAD invalidates every earlier passing check;
- retrying PR creation returns the same PR;
- red required CI cannot be merged;
- protected merge without approval returns exit code 5;
- a consumed approval cannot authorize a second different merge;
- local target movement forces re-verification;
- cleanup refuses dirty or unowned resources;
- delivery evidence identifies exact base and head SHAs.

### v0.8: Crew Leads and fleet routing

**Objective:** Add persistent domain supervision and clear fleet-wide routing.

**Deliver:**

- Crew Lead lifecycle, scope, routing rules, queue, and endpoint;
- lead capability and structured event protocol;
- routing explanation and conflict decisions;
- fleet/project/lead capacity controls;
- lead pause, resume, recovery, and safe retirement;
- fleet status grouped by project, lead, and state.

**Public surface:** `lead ...`, `lead` filters in job and status commands.

**Acceptance gate:**

- route at least three domains across three projects;
- a lead cannot see or mutate out-of-scope jobs;
- tied routing rules create a decision;
- a lead cannot create another lead or approve delivery;
- retiring a lead with active work is refused until work is rerouted, completed, or explicitly cancelled;
- idle leads consume no model tokens;
- restart restores lead queues and endpoint state.

### v0.9: Runtime portability and controlled autonomy

**Objective:** Make orchestration portable and safe for longer unattended periods.

**Deliver:**

- Tmux session adapter at reference quality;
- Claude and Codex harness adapters at verified quality;
- OpenCode adapter at verified or clearly experimental quality;
- permission-profile translation, isolation conformance probes, and gap reporting;
- autonomous mode with scoped, expiring policy grants;
- webhook or local notification connector interface;
- GitLab forge adapter;
- self-update verification for the pinned Sigstore identity, checksum manifest, and macOS notarization, with explicit install approval;
- fault-injection and adapter conformance suites.

**Public surface:** adapter selection, permission profiles, `boss mode autonomous`, update status.

**Acceptance gate:**

- the same Build and Explore contract passes on Herdr and Tmux;
- Claude and Codex both complete the explicit worker protocol live tests;
- unavailable resume or permission features are reported before dispatch;
- `doctor` proves each supported safe profile denies control and state paths before it reports `worker_isolation=enforced`;
- autonomous mode cannot merge or perform destructive cleanup beyond its exact grant;
- expired grants fail closed;
- update verification rejects a wrong signing identity, unsigned manifest, checksum mismatch, or missing required macOS signature/notarization;
- GitHub and GitLab delivery share the same domain behavior.

### v1.0: Competitor-ready release

**Objective:** Prove the full product as one reliable system.

**Deliver:**

- complete CLI and agent documentation;
- stable `crewboss.cli.v1` and event schemas;
- supported migration from released Bash formats;
- Homebrew, signed binary, and skill installation paths;
- performance, recovery, and security hardening;
- compatibility warnings and deprecation schedule;
- end-to-end parity demonstration and reproducible test fixture.

**Public surface:** Stable 1.0 CLI, JSON, event, worker, installation, and migration contracts.

**Acceptance gate:**

- complete the parity scenario in section 28;
- all unit, contract, integration, migration, live-adapter, crash, and security suites pass;
- no high-severity unresolved security finding;
- no known event-loss or unauthorized-delivery path;
- documentation matches every supported command and adapter capability;
- upgrade from v0.2 fixture to v1.0 preserves jobs, events, endpoints, and artifacts;
- a fresh user can install, run `doctor`, register a project, and dispatch a job using only shipped documentation.

## 27. Feature parity matrix

This matrix tracks the user outcome, not identical implementation.

| Capability | CrewBoss today | Target release | CrewBoss outcome |
| --- | --- | --- | --- |
| Agent-loadable instructions | Yes | v0.2 | Keep `SKILL.md` as the trigger and protocol guide. |
| Durable completion events | Yes, Bash JSONL | v0.2 and v0.4 | Preserve at-least-once event behavior in the transactional SQLite stream. |
| Safe multi-repository state | No | v0.3 to v0.5 | Project registry and project-scoped names. |
| Stable machine protocol | No | v0.4 | Versioned JSON CLI and socket API implemented by Go. |
| Durable backlog/jobs | No | v0.5 | Jobs, runs, dependencies, briefs, and artifacts. |
| Implementation workflow | Basic spawn | v0.5 to v0.7 | Build jobs with verification and delivery. |
| Investigation workflow | No | v0.5 | Explore reports and clean promotion to Build. |
| Background supervision | No | v0.6 | Event-driven local supervisor and wake queue. |
| Session restart recovery | Partial open/close | v0.6 | Lease and adapter reconciliation after restart. |
| Persistent domain managers | No | v0.8 | Scoped Crew Leads with durable queues. |
| Worktree isolation | Yes, Worktrunk | v0.5 | Preserve it behind a tested adapter contract. |
| Same-user worker isolation | No | v0.5 and v0.9 | Verified sandbox denial of control and state paths, with honest unsafe fallback. |
| Several terminal backends | No | v0.9 | Herdr and Tmux at verified quality. |
| Several agent harnesses | Partial | v0.9 | Claude and Codex verified; more through adapters. |
| Pull-request delivery | No | v0.7 | GitHub delivery with checks, reviews, and approval. |
| Local-only delivery | Manual | v0.7 | Revision-bound verified local merge. |
| Unattended mode | No | v0.6 and v0.9 | Away mode, then scoped autonomous mode. |
| Explicit safety authority | No | v0.5 to v0.9 | Isolation, profiles, policy, approvals, and receipts. |
| Fleet overview | Basic list | v0.6 and v0.8 | Cross-project jobs, workers, leads, and alarms. |
| Signed self-update | No | v0.9 | Verify pinned Sigstore identity, checksums, and macOS notarization. |
| Public/social intake | No | After 1.0 | Connector SDK without tying the core to one network. |
| Hosted/remote workers | No | After 1.0 | Remote cells and optional control plane. |

## 28. Required 1.0 parity scenario

Release candidates must pass this reproducible scenario on a clean machine:

1. Install the signed binary and agent skill.
2. Register three Git repositories with different defaults.
3. Attach a coordinating agent as CrewBoss.
4. Create at least ten jobs with mixed priorities and dependencies.
5. Dispatch concurrent workers through both Herdr and Tmux.
6. Run at least one worker with Claude and one with Codex.
7. Complete one Build job through `verified-pr`.
8. Complete one Build job through `local` delivery.
9. Complete one Explore report and promote it to a new Build job.
10. Route jobs through at least two Crew Leads.
11. Block one worker on a decision, detach the boss, reattach elsewhere, and answer it.
12. Kill and restart the service during a dispatch saga.
13. Remove one worker endpoint during active work and reconcile it without false success.
14. Change a branch after verification and prove that delivery is invalidated.
15. Attempt an unapproved merge and destructive cleanup and prove both are refused.
16. Run a same-user worker probe that attempts to open the control socket, state database, operator credentials, and another run; every safe profile must deny it.
17. Restart the terminal backend and recover owned endpoints where the adapter supports it.
18. Finish all work and prove safe cleanup of owned worktrees, endpoints, leases, and capabilities.

Pass conditions:

- no job, decision, event, or artifact is lost;
- repeated requests do not duplicate PRs, questions, merges, or completion;
- all delivery evidence points to exact revisions;
- primary checkouts remain untouched by worker runs;
- no unsafe action occurs without a valid approval;
- every claimed safe profile has recorded `worker_isolation=enforced` evidence;
- idle supervision makes zero model calls;
- the final fleet report explains every job outcome and remaining resource.

## 29. Testing and quality strategy

### 29.1 Test layers

**Unit tests** cover names, configuration, policies, state transitions, brief validation, scheduling, and adapter error normalization.

**Property tests** generate transition sequences, dependency graphs, duplicate events, stale generations, and idempotent request retries.

**Store tests** use real SQLite files and test migrations, constraints, concurrent reads, crash recovery, and WAL checkpoints.

**Contract tests** run the same CLI JSON fixtures and adapter behavior against fakes and real adapters.

**Integration tests** create temporary Git repositories and exercise complete worktree, run, check, and delivery sagas.

**Migration tests** import fixtures from the current main registry and merged PR #2 event format, including corrupt and ambiguous cases.

**Fault-injection tests** stop processes, delay responses, duplicate calls, move branches, remove panes, lock files, and interrupt external operations at each recorded step.

**Security tests** cover path traversal, symlink changes, shell injection, malicious repository instructions, token scope, approval replay, socket ownership, and log redaction.

**Live tests** run supported combinations of Herdr, Tmux, Worktrunk, Claude, Codex, GitHub, and GitLab where credentials and binaries are available.

### 29.2 Required performance and reliability targets

- Warm local read commands finish within 100 ms at the 95th percentile for 1,000 jobs.
- A worker mutation is committed before success is acknowledged.
- 100 concurrent event writers produce no lost events and one ordered stream.
- Reconciliation of 100 recorded jobs finishes within 10 seconds, excluding external network wait.
- An idle service makes zero model calls and uses bounded operating-system polling.
- Event consumers provide at-least-once handling with demonstrated idempotency.
- A database crash test never exposes a partially committed domain transition.

### 29.3 Release gates

Every release requires:

- `bash tests/run` while the Bash engine exists;
- Go unit, integration, and race tests;
- static analysis and formatting;
- database migration checksum verification;
- JSON schema compatibility tests;
- documentation examples executed where practical;
- `git diff --check`;
- adapter capability matrix review;
- signed binaries and published checksums for binary releases;
- a migration dry run from the previous release.

## 30. Observability and privacy

CrewBoss is local-first and sends no telemetry by default.

Structured local logs include request ID, event sequence, job/run IDs, adapter, action, duration, and normalized result. They exclude prompt bodies, secrets, raw capabilities, and full source content by default.

Optional diagnostics export:

- produces a reviewable archive manifest before creation;
- redacts registered secrets and local usernames where practical;
- includes database schema and selected rows, not the capability hashes or raw credential material;
- needs explicit operator action.

Metrics are available locally through `crewboss status --json` and a disabled-by-default local endpoint. Remote telemetry, if ever added, is opt-in and documented field by field.

## 31. Risks and fixed decisions

### 31.1 SQLite and one service writer

**Risk:** A service bug can block all state changes.

**Decision:** Keep one authoritative writer because it gives strong transitions and migration safety. Add health checks, supervised restart, backups, integrity checks, and read-only recovery commands.

### 31.2 External side effects are not transactional

**Risk:** A crash can happen after a pane, worktree, PR, or merge is created but before local acknowledgement.

**Decision:** Every external mutation has an idempotency key and recorded saga state. Reconciliation observes before retrying.

### 31.3 Adapter semantics differ

**Risk:** A generic `busy` or `idle` state is unreliable across agent tools.

**Decision:** Each harness adapter owns semantic interpretation and publishes verified capabilities. Explicit worker events remain authoritative.

### 31.4 No dedicated coordinator home

**Risk:** Moving the coordinating role between agent sessions can lose conversational context.

**Decision:** Durable jobs, decisions, event cursors, summaries, and artifacts are the context boundary. Boss takeover reads a generated fleet brief instead of relying on chat history.

### 31.5 Repository content is adversarial input

**Risk:** A repository or issue can instruct an agent to escape scope or reveal secrets.

**Decision:** Service policy and scoped capabilities are outside model prompts and cannot be overridden by repository text.

### 31.6 Compatibility can slow design cleanup

**Risk:** Old crew commands do not express projects, runs, approvals, or delivery clearly.

**Decision:** Preserve them as aliases for common workflows, not as the internal model. Ambiguous old commands fail with a migration hint.

### 31.7 Unix socket portability

**Risk:** The initial service transport does not provide native Windows parity.

**Decision:** Target macOS and Linux for 1.0. Keep the API transport boundary replaceable so named pipes can be added later.

### 31.8 Same-user processes do not have separate OS identities

**Risk:** Unix peer credentials authenticate a user ID, not an agent role. Without a sandbox, a hostile worker running under the operator's UID can reach user-owned files, copy credentials, open SQLite directly, or call the control socket as the same user.

**Decision:** Role-isolation claims require a live-tested harness sandbox that denies control, state, configuration, credential, and unrelated run paths. Workers receive only a per-run event ingress. Safe profiles fail closed without this capability. `unsafe-host` remains available through explicit expiring approval, but its policy is not described as a security boundary against hostile same-UID code.

## 32. Post-1.0 differentiators

After core parity, CrewBoss can move beyond a local competitor in these directions:

1. **Remote execution cells:** encrypted workers on isolated hosts or sandboxes, still controlled by the same job and event protocol.
2. **Web control center:** a local-first live dashboard built on the versioned API and server-sent events.
3. **Policy and adapter SDK:** signed plugins for new harnesses, forges, checks, notifications, and approval systems.
4. **Budget-aware routing:** model, token, money, energy, and time budgets as scheduling constraints.
5. **Replay and simulation:** replay an event stream against a new policy or scheduler before changing production state.
6. **Multi-repository jobs:** one job with coordinated branches, dependency order, and atomic delivery evidence across repositories.
7. **Stacked delivery:** dependent pull requests with automatic rebase and evidence invalidation.
8. **Quality analytics:** compare estimates, retries, verification failures, review findings, and lead performance without sending source code.
9. **Team mode:** shared control plane, role-based access, signed approvals, and an audit ledger.
10. **Connector framework:** GitHub issues, Jira, Slack, Teams, email, webhooks, and public networks as intake or notification channels.
11. **Collaborative review:** independent worker proposals, structured debate, and evidence-based selection before implementation.
12. **Reusable playbooks:** versioned job templates for releases, migrations, incident work, audits, and dependency upgrades.

## 33. Definition of complete

CrewBoss is a credible Firstmate competitor when all of the following are true:

- It is no longer dependent on one agent conversation for durable coordination.
- Its skill, CLI, service API, database, and worker protocol form one documented product contract.
- It manages multiple projects, workers, and persistent Crew Leads from one fleet.
- Build and Explore workflows are complete from request through evidence-backed delivery.
- Restarting any normal local component does not lose authoritative work state.
- Completion and blocked state come from explicit events, not terminal scraping.
- Authority is scoped, high-impact actions are approved, and approvals cannot be replayed broadly.
- Supported adapters pass live conformance tests and unsupported capabilities are reported honestly.
- Existing CrewBoss users have a tested migration path and useful compatibility aliases.
- The required parity scenario passes on a clean supported machine.
- The product keeps its own CrewBoss identity and leaves room for the post-1.0 differentiators.

This document is the master product and architecture specification. Before implementing a release, create a smaller execution plan that names the exact files, tests, migration steps, and commits for that release. A release may refine internal details, but it must not weaken the public contracts or acceptance gates here without an explicit design update.
