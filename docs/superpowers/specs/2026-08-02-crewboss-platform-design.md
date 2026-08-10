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

The section 27 matrix is the authoritative mapping of these capabilities to target releases.

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

These event capabilities landed on main in PR #2 and form the verified Bash migration baseline; `2026-07-31-phase-1-event-log-design.md` and the merged PR #2 test suites are their authoritative specification — this list is a summary.

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
| CrewBoss | The product and the currently attached coordinating agent, also called the boss. |
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
| Endpoint | One session-adapter surface, such as a pane, window, or process, where an agent runs. |
| Consumer | A named reader of the event stream with its own durable cursor. |
| Approval | A single-use operator authorization for one exact action. |
| Grant | Standing, pre-approved authority for a repeatable action inside an exact scope. |

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
- Taking over a live lease needs an exact unexpired operator approval unless the lease has expired.
- Detaching the boss never stops workers or loses events.
- If no boss is attached, actionable events stay queued and may trigger an OS notification.

There is no required cloned coordinator home. An agent in any terminal can attach after an operator-authorized attach flow issues a short-lived boss credential. The credential remains outside worker sandboxes. Access to the local socket or matching user ID alone is not enough (15.7).

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
$XDG_CONFIG_HOME/crewboss/homes/<home>.toml
$XDG_STATE_HOME/crewboss/<home>/state.db
$XDG_DATA_HOME/crewboss/<home>/artifacts/
$XDG_DATA_HOME/crewboss/<home>/briefs/
$XDG_RUNTIME_DIR/crewboss/<home>/control.sock
$XDG_RUNTIME_DIR/crewboss/<home>/runs/<run-id>/
```

State and runtime directories use mode `0700`; databases, tokens, and sensitive configuration use `0600`. The daemon refuses a socket or state directory owned by another user. The control socket is never mounted into a worker sandbox. Each run's directory holds its event ingress, provider-gateway ingress, and unsent event spool at mode `0700`. The two ingresses use different capabilities and expose disjoint protocols. The directory and sockets are removed when the run's capabilities are revoked.

### 11.3 Configuration

TOML is the human-edited configuration format. SQLite stores live and derived state.

Configuration sections are versioned; the values below are illustrative, not shipped defaults:

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
harness = "claude"
delivery = "verified-pr"
permission_profile = "standard"

[forge.github]
enabled = true
```

Two homes can differ. `$XDG_CONFIG_HOME/crewboss/homes/<home>.toml` overrides `[limits]`, `[defaults]`, and `[forge.*]` for one home. `crewboss config show --home <home>` prints the effective value and its source file.

Environment variables may select a home or override non-secret runtime values. They must not create hidden policy exceptions. `crewboss config validate` prints all effective sources and rejects unknown keys by default.

## 12. Domain model and database contract

IDs use UUIDv7. Times use UTC RFC 3339 with microseconds at API boundaries. JSON payloads carry a schema version. Each mutable aggregate has an integer `generation` used for compare-and-swap updates.

### 12.1 Required tables

Each CrewBoss home is one database file. A home is a whole database, not a row inside a shared one, so `home_id` is not a column on domain tables. The `homes` table holds one row identifying the file's own home slug, and the service refuses to open a database whose slug does not match the requested home. `events.seq` alone orders the stream. API payloads still carry `"home"` so a reader never has to infer it.

#### `schema_migrations`

Fields: `version`, `name`, `checksum`, `applied_at`.

#### `legacy_import_checkpoints`

Fields: `source_id`, `source_format`, `registry_revision`, `registry_sha256`, `last_event_seq`, `last_event_sha256`, `event_state_revision`, `event_state_sha256`, `cutover_spool_sha256`, `authority_state`, `generation`, `inspected_at`, `imported_at`, `cutover_at`.

There is one row for the legacy Bash home. `authority_state` is `rehearsal`, `cutover_pending`, or `service_authoritative`. The checkpoint identifies one stable legacy snapshot and makes repeated imports idempotent. It never stores a raw capability or credential. Once it reaches `service_authoritative`, an older checkpoint cannot be imported and the legacy engine cannot become a writer again without restoring the pre-cutover home backup.

#### `homes`

Fields: `id`, `slug`, `display_name`, `config_revision`, `created_at`, `updated_at`.

`slug` is unique on the machine.

#### `projects`

Fields: `id`, `slug`, `display_name`, `repo_root`, `repo_identity`, `canonical_remote`, `base_branch`, `branch_prefix`, `session_adapter`, `worktree_adapter`, `harness_defaults_json`, `forge_config_json`, `verification_json`, `policy_json`, `status`, `generation`, `created_at`, `updated_at`, `archived_at`.

`slug` and `repo_identity` are unique for active projects. `repo_identity` is derived from the canonical repository identity, not only the current path. `branch_prefix`, `verification_json`, and `policy_json` hold the project-owned settings that sections 15.3 and 18.1 require.

#### `boss_sessions`

Fields: `id`, `endpoint_id`, `holder_identity`, `lease_id`, `state`, `generation`, `attached_at`, `heartbeat_at`, `expires_at`, `detached_at`.

Only one unexpired active boss session may exist per home.

#### `leads`

Fields: `id`, `slug`, `display_name`, `scope_json`, `routing_rules_json`, `endpoint_id`, `harness_config_json`, `status`, `generation`, `created_at`, `updated_at`, `retired_at`.

`slug` is unique for non-retired leads.

#### `jobs`

Fields: `id`, `project_id`, `lead_id`, `name`, `title`, `type`, `state`, `state_reason`, `return_state`, `priority`, `tags_json`, `delivery_mode`, `merge_authority`, `requested_by`, `source_ref`, `objective`, `scope_json`, `acceptance_json`, `authority_json`, `current_run_id`, `generation`, `created_at`, `updated_at`, `completed_at`, `cancelled_at`, `archived_at`.

`(project_id, name)` is unique where `archived_at IS NULL`. This lets a project reuse a ticket or job name after the earlier job is archived. A globally ambiguous short name produces a clear conflict and requires `project/name`. `title` defaults to the raw task text; `name` follows the derivation rules in 15.3.

`merge_authority` is `operator` or `policy`. `operator` is the default and requires a matching approval before merge. `policy` permits a merge only when an unexpired autonomous grant covers the exact action and target.

`return_state` is non-null only while the job is `suspended` or `waiting`. The valid pairs are exactly the suspend and wait transitions in 13.1; database constraints and the domain layer reject every other pair.

#### `job_dependencies`

Fields: `job_id`, `depends_on_job_id`, `kind`, `created_at`.

The service rejects self-dependencies and cycles. Initial `kind` values are `blocks` and `informs`.

#### `briefs`

Fields: `id`, `job_id`, `schema_version`, `content_sha256`, `content_json`, `rendered_artifact_id`, `created_by`, `created_at`.

A brief is immutable after its linked run starts. `runs.brief_id` is a non-null unique foreign key, so the run owns the only database relationship and exactly one run uses each brief. The brief and its run are created in one transaction and must reference the same job. `rendered_artifact_id` may be null until rendering finishes.

#### `runs`

Fields: `id`, `job_id`, `attempt`, `state`, `return_state`, `brief_id`, `base_ref`, `base_sha`, `branch`, `worktree_path`, `endpoint_id`, `worker_identity`, `capability_hash`, `capability_expires_at`, `head_sha`, `result_summary`, `failure_code`, `generation`, `created_at`, `dispatched_at`, `started_at`, `heartbeat_at`, `finished_at`.

`(job_id, attempt)` and `brief_id` are unique. A retry always creates a new run and a new brief.

`runs.return_state` is non-null only while the run is `suspended`; the valid values are exactly the suspend transitions in 13.2.

#### `provider_sessions`

Fields: `id`, `run_id`, `harness_adapter`, `provider`, `auth_mode`, `state`, `capability_hash`, `capability_expires_at`, `generation`, `created_at`, `last_used_at`, `revoked_at`.

One run has at most one active provider session. `auth_mode` is `brokered` or `provider_run_scoped` for an enforced sandbox; `host_inherited` is allowed only under `unsafe-host`. The row stores only the hash of the run-scoped gateway capability or provider-issued run token. Upstream API keys, OAuth refresh tokens, cookies, and harness account files never enter any of the locations excluded by the credential rule in 21.2.

#### `endpoints`

Fields: `id`, `adapter`, `external_id`, `kind`, `state`, `semantic_state`, `metadata_json`, `last_seen_at`, `generation`, `created_at`, `closed_at`.

`external_id` is internal. Users are never required to type it.

#### `decisions`

Fields: `id`, `job_id`, `run_id`, `key`, `question`, `choices_json`, `context_json`, `state`, `answer`, `answered_by`, `replaces_decision_id`, `generation`, `created_at`, `answered_at`, `expires_at`.

Partial unique indexes allow only one open decision for each `(run_id, key)` when `run_id IS NOT NULL`, and only one open decision for each `(job_id, key)` when `run_id IS NULL`. Repeated identical open questions are idempotent. Answered, expired, and superseded decisions remain as history. A replacement decision points to the earlier row through `replaces_decision_id`. A decision superseded by its run ending terminally has no replacement row; `replaces_decision_id` stays null.

#### `approvals`

Fields: `id`, `job_id`, `grant_id`, `action`, `target_json`, `scope_json`, `requested_by`, `approved_by`, `denied_by`, `method`, `state`, `receipt_hash`, `generation`, `created_at`, `approved_at`, `denied_at`, `expires_at`, `consumed_at`.

An approval is bound to one described action and cannot be widened after creation. Every approval is single-use; consumption follows 13.6. `grant_id` is null for a direct operator approval and set when the approval was minted by consuming a grant.

#### `grants`

Fields: `id`, `action`, `scope_json`, `granted_by`, `method`, `state`, `single_use`, `receipt_hash`, `generation`, `created_at`, `expires_at`, `revoked_at`.

A grant is standing, pre-approved authority for a repeatable action inside an exact scope; consumption and revocation semantics are defined in 21.6. A `single_use` grant moves to `exhausted` on its first consumption.

#### `events`

Fields: `seq`, `event_id`, `aggregate_type`, `aggregate_id`, `aggregate_generation`, `job_id`, `run_id`, `kind`, `severity`, `dedupe_key`, `payload_json`, `actor_type`, `actor_id`, `created_at`.

`seq` is the ordered stream key. `event_id` is globally unique. `(actor_id, dedupe_key)` is unique when a deduplication key is supplied.

#### `consumer_cursors`

Fields: `consumer_id`, `last_acked_seq`, `lease_id`, `generation`, `updated_at`.

`consumer_id` is unique.

Consumers receive events at least once. They acknowledge a sequence only after completing their local action.

#### `consumer_parked_events`

Fields: `consumer_id`, `seq`, `parked_at`.

`(consumer_id, seq)` is unique. A filtered read such as `job wait` may deliver a newer event before an older event its selector did not choose. A shared `last_acked_seq` alone would then skip the older event forever. So when a consumer's cursor advances past an undelivered actionable event (14.3), that sequence is parked for the consumer in the same transaction. A consumer's unread set is the events past its cursor plus its parked rows, and delivering a parked event deletes its row. This carries forward the Bash `event-state.json` pending checkpoint: a filtered wait must never lose an event for an unselected job. `info` events never park because no wait returns them.

#### `requests`

Fields: `request_id`, `actor_type`, `actor_id`, `command`, `protocol_version`, `input_sha256`, `state`, `operation_id`, `response_json`, `error_json`, `created_at`, `completed_at`.

`request_id` is unique inside its home database. A replay returns the stored result only when the authenticated actor, command, protocol version, and `input_sha256` all match the stored request; any mismatch returns `state_conflict`. A cached result is never returned across actors, so one caller can never read another caller's privileged response by reusing its request identifier.

#### `operations`

Fields: `id`, `aggregate_type`, `aggregate_id`, `kind`, `state`, `idempotency_key`, `step`, `attempt`, `next_attempt_at`, `input_json`, `observation_json`, `result_json`, `error_json`, `generation`, `created_at`, `updated_at`, `completed_at`.

This table records sagas for external work such as creating a worktree, starting an endpoint, publishing a revision, opening a PR, or merging. `(kind, idempotency_key)` is unique.

#### `artifacts`

Fields: `id`, `job_id`, `run_id`, `kind`, `name`, `media_type`, `storage_uri`, `sha256`, `size_bytes`, `metadata_json`, `created_at`.

Artifacts are content-addressed where practical. Initial kinds include `brief`, `report`, `patch`, `log`, `diff`, and `verification`.

#### `checks`

Fields: `id`, `job_id`, `run_id`, `head_sha`, `kind`, `name`, `command_json`, `state`, `exit_code`, `evidence_artifact_id`, `started_at`, `finished_at`, `invalidated_at`.

Passing evidence is valid only for the recorded `head_sha`.

#### `deliveries`

Fields: `id`, `job_id`, `run_id`, `mode`, `state`, `head_sha`, `base_sha`, `source_ref`, `published_sha`, `target_branch`, `forge`, `external_ref`, `url`, `approval_id`, `evidence_json`, `generation`, `created_at`, `updated_at`, `delivered_at`.

`source_ref` is the exact service-owned remote ref used for a PR. `published_sha` is null until the forge adapter observes that ref at `head_sha`. PR creation and remote-check evidence are invalid unless `published_sha = head_sha`.

#### `leases`

Fields: `id`, `resource_type`, `resource_id`, `holder`, `purpose`, `generation`, `acquired_at`, `heartbeat_at`, `expires_at`, `released_at`.

`(resource_type, resource_id)` has at most one active generation.

#### `audit_entries`

Fields: `seq`, `entry_id`, `request_id`, `actor_type`, `actor_id`, `action`, `target_json`, `policy_result`, `approval_id`, `before_hash`, `after_hash`, `created_at`.

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
active -> suspended(return_state=active) -> active
blocked -> suspended(return_state=blocked) -> blocked
active|blocked -> verifying
verifying -> waiting(return_state=verifying) -> verifying
verifying -> ready
ready -> waiting(return_state=ready) -> ready
ready -> complete
dispatching -> queued            (safe dispatch recovery)
dispatching|active|blocked|suspended|verifying|waiting|ready -> failed
failed -> queued                 (retry)
draft|queued|dispatching|active|blocked|suspended|verifying|waiting|ready -> cancelled
```

`waiting` means CrewBoss is waiting for a named external condition, such as CI or an approval. `state_reason` identifies that condition. `ready` means required evidence is valid and delivery may proceed.

Entering `suspended` or `waiting` stores the exact origin in `return_state` in the same transaction as the state change and event. Leaving returns only to that stored state and clears `return_state` in the same transaction. A transition to `failed` or `cancelled` also clears it. Events may repeat this provenance for audit, but restart and resume use the aggregate field only; no other row or observation is consulted.

Dispatch recovery is bounded. When the recorded dispatch operation exhausts its retry policy, the job moves to `failed` with `state_reason=dispatch_failed` instead of returning to `queued` again.

Cancelling during `dispatching` first marks the dispatch operation `cancel_requested`. The service unwinds or records every external saga step before it commits `cancelled`. If cleanup cannot finish, the job remains visible with `state_reason=cancel_cleanup`; it is never hidden as successfully cancelled.

### 13.2 Run state

```text
preparing -> dispatched -> active -> succeeded
dispatched|active -> blocked -> active
blocked -> succeeded                         (terminal worker event while blocked)
active -> suspended(return_state=active) -> active
blocked -> suspended(return_state=blocked) -> blocked
preparing|dispatched|active|blocked|suspended -> failed
preparing|dispatched|active|blocked|suspended -> cancelled
dispatched|active|blocked -> lost
lost -> active|failed|cancelled              (reconciliation)
```

`lost` means the endpoint disappeared without an authoritative worker result. Reconciliation returns a run to `active` only after an authenticated worker heartbeat on the same run generation. A restored endpoint, a present worktree, or screen text is never enough. Otherwise reconciliation records `failed` or `cancelled`, or the operator retries into a new run.

A terminal worker event received while a run is blocked is accepted, not rejected. The service marks the run's open decisions `superseded` with no replacement row, records the terminal transition, and keeps the unanswered question in history. Rejecting it would discard authoritative worker evidence and strand the run.

### 13.3 Endpoint state

```text
creating -> live -> idle
live|idle -> closed
creating|live|idle -> missing
missing -> live|closed
any observable state -> unknown
unknown -> live|idle|missing|closed    (reconciliation)
```

`semantic_state` is adapter-specific and may include `starting`, `thinking`, `waiting_input`, `running_command`, or `exited`. It is diagnostic and routing input, not completion evidence.

### 13.4 Delivery state

```text
none -> pending -> delivering -> delivered
pending -> awaiting_approval -> delivering
pending|awaiting_approval|delivering -> failed
awaiting_approval|delivering -> pending      (approval denied, or base/head moved)
failed -> pending
```

### 13.5 Decision state

```text
open -> answered
open -> superseded
open -> expired
```

Expiry does not guess an answer and does not mark the run successful or failed. The run and job remain blocked with `state_reason=decision_expired`. The service emits an urgent boss event. The operator may cancel or retry the job, or provide an answer that creates a replacement decision linked to the expired one and resumes the worker if its endpoint is still usable.

### 13.6 Approval state

```text
requested -> granted -> consumed
requested -> denied
requested|granted -> expired
```

Grant and denial record the authenticated operator action. Approval consumption and creation of the authorized operation record commit in one transaction, so one approval cannot be raced or replayed. A denied, expired, or consumed approval cannot return to `granted`.

Standing grants (21.6) follow their own machine:

```text
active -> revoked
active -> expired
active -> exhausted     (single-use grant consumed)
```

Revocation is an operator action; its timing follows 21.6. All three terminal grant states fail closed, exactly like an expired approval.

### 13.7 Check state

```text
pending -> running -> passed|failed
passed|failed -> invalidated     (head_sha moved)
```

### 13.8 Provider session state

```text
preparing -> active -> revoked
preparing|active -> failed
active -> expired
```

The local gateway rejects a capability as soon as its row leaves `active`. Suspension and terminal run transitions commit local revocation with the run change. Revoking a provider-issued run token is an external saga, but direct provider egress remains denied while that compensation finishes.

All transitions are checked in the domain layer and committed with the expected generation. State and `return_state` are one compare-and-swap update, never separate writes. A stale caller receives `state_conflict`; it does not overwrite newer state.

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

The brief tells the worker to send a heartbeat immediately after it reads the brief and capability. The first authenticated heartbeat is the dispatch acknowledgement. Pane text and inferred harness state are not acknowledgements.

The token is:

- stored only as a hash in SQLite;
- bound to one run and generation;
- limited to the worker event actions;
- short-lived and renewable while the run is `dispatched`, `active`, or `blocked`;
- revoked when the run is suspended, ends, or is replaced.

An authenticated heartbeat received before expiry extends `capability_expires_at` while the run is `dispatched`, `active`, or `blocked`, capped by the configured maximum run lifetime. A blocked run must stay renewable: a decision can wait for days, and 13.2 accepts a terminal worker event while blocked, which only an authenticated token can deliver. The heartbeat renews the existing opaque token; there is no separate renewal endpoint. An expired token cannot renew itself. Suspending a run revokes its event capability and provider session. `job resume` creates fresh run-scoped capabilities for the same run through the protected dispatch path before the worker continues.

The service validates the token and writes the event and state transition before acknowledging it. A worker may retry after a lost response without creating a duplicate because every mutation carries an idempotency key.

The worker CLI creates an event UUID before sending and keeps an unsent envelope in its protected runtime directory. A retry reuses that UUID. Completion and failure transitions also reject a second different terminal event for the same run generation.

### 14.2 Event delivery

Event delivery is at least once.

- Every home has a monotonic `seq`.
- Consumers read the events past their stored cursor plus any sequences parked for them in 12.1.
- A consumer acknowledges only after its side effect or response is safe.
- A consumer crash may replay an event.
- All consumers must therefore be idempotent.
- Retention may archive old payloads only after every required consumer passes the sequence with no parked row at or below it and audit policy allows it.

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

`severity` is one of `info`, `action`, `urgent`, or `error`; the last three are the **actionable** severities. `info` needs no response. `action` needs a normal consumer or operator action. `urgent` is time-sensitive and must wake or notify the boss. `error` reports a failed operation or broken invariant.

The initial stable event namespace includes:

- `project.added`, `project.changed`, `project.archived`;
- `job.created`, `job.queued`, `job.blocked`, `job.suspended`, `job.resumed`, `job.ready`, `job.completed`, `job.failed`, `job.cancelled`, `job.archived`;
- `run.preparing`, `run.started`, `run.progress`, `run.question`, `run.amended`, `run.suspended`, `run.resumed`, `run.completed`, `run.failed`, `run.lost`;
- `provider_session.started`, `provider_session.revoked`, `provider_session.expired`, `provider_session.failed`;
- `endpoint.changed`, `endpoint.missing`;
- `decision.opened`, `decision.answered`, `decision.superseded`, `decision.expired`;
- `check.started`, `check.passed`, `check.failed`, `check.invalidated`;
- `delivery.requested`, `delivery.awaiting_approval`, `delivery.completed`, `delivery.failed`;
- `approval.requested`, `approval.granted`, `approval.denied`, `approval.expired`, `approval.consumed`;
- `grant.created`, `grant.revoked`, `grant.expired`, `grant.exhausted`;
- `boss.attached`, `boss.detached`, `boss.wake_requested`;
- `lead.created`, `lead.routed`, `lead.retired`;
- `system.warning`, `system.reconciled`.

New event kinds may be added in a minor protocol version. Existing meanings must not change inside a major version.

### 14.4 Bash compatibility protocol

During migration, the Bash adapter reads the legacy `events.jsonl` records that workers append with `crewboss emit` (`blocked` and `done`). It maps `blocked` to a free-text `run.question` and `done` to `run.completed`, using the stored legacy `crew_id` and `run_id`. The legacy `event_id` becomes the deduplication key, and the raw payload is preserved.

The v0.3 Bash shim also participates in one legacy-home write barrier. Every registry mutation and event append takes the barrier in shared mode before it takes its existing registry or event lock. Migration inspection and rehearsal import take it exclusively only long enough to copy an immutable snapshot, then release it while the service validates or imports that copy. A final service cutover holds it exclusively through the authority switch. Rehearsal imports do not take authority and never make an earlier snapshot silently current.

After cutover, compatibility commands route to the service; engine-marker authority over `CREWBOSS_ENGINE=bash` is defined in 25.4. Already-running Bash workers may keep using `crewboss emit`; the shim sends their stored crew/run identity and original event UUID through the service's legacy ingress instead of appending `events.jsonl`.

During an interrupted cutover, operator-retryable mutations fail closed with `migration_in_progress`, while mutations carrying authoritative worker evidence are never dropped: `emit` first routes to the service if SQLite already records service authority; otherwise it appends the original envelope and UUID to a locked `cutover-events.jsonl` spool. It reports success only after a service acknowledgement or a durable spool append. Recovery of an interrupted cutover follows the forward-only rules in 25.4, so neither engine accepts an untracked write and at-least-once worker delivery holds across every cutover crash point.

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
crewboss job diff|logs|report|verify|deliver|focus
crewboss lead create|list|show|route|pause|resume|retire
crewboss approval list|show|grant|deny
crewboss grant create|list|show|revoke
crewboss backup create|list|verify|restore
crewboss migrate inspect|apply
crewboss skill install|status|update
```

Compatibility aliases remain during the deprecation window:

```text
spawn send wait read focus close open remove list
```

Aliases accept the old arguments, print one clear deprecation warning in human mode, and map to a project-scoped job when unambiguous. They never ask for pane IDs, worktree paths, or internal timeouts.

- `spawn` maps to `job create` followed by `job dispatch` as one idempotent convenience operation.
- `send` maps to `job send`.
- `wait` maps to `job wait`.
- `list` maps to `job list`.
- `focus` maps to `job focus` through the session adapter.
- `read` maps to `job logs --snapshot`. It labels the result as a visible endpoint snapshot and returns `backend_unavailable` when no live endpoint can provide one.

Both `job wait` and its compatibility alias accept one or more selectors. This preserves the existing multi-name wait behavior.

`job wait` blocks until one selected job has an undelivered actionable event (14.3), either parked for the caller's consumer or past its cursor, then prints the oldest such event and exits. The first human line is `NAME KIND`; `--json` emits the standard `crewboss.cli.v1` envelope from 15.4 with the full event envelope nested under `data.event`. `info` events never satisfy a wait. The caller names its consumer with `--consumer`; the default is the shared `cli` consumer. The cursor advances only after the event reaches standard output, and that advance parks the skipped actionable events of unselected jobs per the parked-event rule in 12.1. The compatibility alias always uses the single `legacy` consumer, mirroring today's `event-state.json` cursor and pending checkpoint, and renders `run.question` as `blocked` and `run.completed` as `done` in its first line.

`job send` delivers a free-text message to the run's worker through the harness adapter. Unlike `job answer`, it does not resolve a decision. `job diff` shows the run's recorded `base_sha..head_sha` through the worktree adapter and labels the exact SHAs.

The compatibility alias `close` maps to `job suspend`. It records the job and run as suspended, including each exact `return_state`, before safely closing the worker endpoint. The alias `open` maps to `job resume`. Resume restores the same run only when the harness adapter reports verified resume support; otherwise it returns `backend_unavailable` and recommends `job retry`. The resume saga keeps both aggregates suspended while it restores the endpoint and delivers fresh event and provider capabilities. Only after the worker acknowledges the protected resume path does one transaction restore the job and run to their respective stored states, clear both `return_state` fields, and emit the resume events. `remove` maps to `job remove`, safely cleans CrewBoss-owned runtime resources, and archives the logical job. It does not erase events, approvals, or audit evidence.

`job remove` first completes normal cancellation and cleanup when needed. It sets `archived_at` only after cleanup succeeds or no owned runtime resources remain. It preserves the job's terminal state and all history.

### 15.2 Names and selectors

- Project slugs are unique in a CrewBoss home.
- Non-archived job names are unique in a project.
- `job-name` works when globally unambiguous.
- `project/job-name` selects the non-archived job without global ambiguity.
- UUIDs are accepted for automation but are not the normal user interface.
- Internal pane, process, and worktree identifiers do not appear as required arguments.

Name selectors and lists omit archived jobs by default. `--all` includes them. If several archived jobs share one project and name, the qualified name selector returns `ambiguous_selector` and lists the matching UUIDs.

### 15.3 Naming derivation

Naming carries forward today's `scripts/lib/naming.sh` derivation rules, with one explicit normalization change: canonical job names are lowercase. Contract fixtures record both the preserved rules and that change.

1. An explicit `--name` wins after validation and lowercase normalization.
2. Otherwise CrewBoss takes the first Jira-style key matching `[A-Za-z][A-Za-z0-9]+-[0-9]+` and lowercases it for the job name, so `CB-142 add retry limits` becomes `cb-142`.
3. With no ticket, CrewBoss removes ticket-like text, lowercases the task, replaces non-alphanumeric runs with spaces, takes the first four words, and joins them with `-`.
4. Empty derived names fail with `invalid_argument`.
5. A name collision with a non-archived job in the project fails with `state_conflict` and asks for `--name`; CrewBoss never silently attaches to the existing job or adds a random suffix.

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

JSON output writes only the envelope to standard output. Human diagnostics go to standard error. Commands that mutate state accept `--request-id`; retrying the same request from the same authenticated actor, command, and protocol version returns the original result or its current operation record, under the matching rules in 12.1. The CLI generates a request ID when the flag is absent and returns it in the envelope, so the API requirement in 15.7 always holds.

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

The stable error codes are exactly those in the mapping table below. A new code may be added in version 1, but the meaning of an existing code cannot change.

Each stable error code maps to exactly one exit code:

| Exit | Error codes |
| --- | --- |
| 2 | `invalid_argument`, `ambiguous_selector` |
| 3 | `not_found` |
| 4 | `state_conflict` |
| 5 | `approval_required` |
| 6 | `backend_unavailable`, `unsupported_protocol` |
| 7 | `external_retryable` |
| 8 | `policy_refused`, `invalid_capability` |
| 9 | `integrity_failure`, `internal` |

A new error code must declare its exit code in the same commit.

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

Every public CLI command maps to a documented route. The map above is the 1.0 core resource map; each route ships with the release that ships its command, per the section 26 public surfaces. Later releases document additional routes when their commands ship.

The two `/v1/worker/*` routes are served only through the run-specific ingress. They are not exposed by the control socket.

Mutations require `X-CrewBoss-Request-ID`. Conditional aggregate updates use `If-Match: <generation>`. Event streaming uses server-sent events and resumes with `Last-Event-ID`; `GET /v1/events` remains the durable catch-up path.

Socket ownership and operating-system peer identity prove only that a caller belongs to the local user account. They do not prove that the process is the operator, boss, or worker. Control requests therefore also require a role credential outside the worker sandbox. Approval grants require an operator method from 21.4, preferring an attested user-presence action over plain TTY confirmation; same-user peer credentials alone never grant approval authority.

Workers do not receive the control socket. Each run receives a separate event ingress socket or inherited file descriptor that exposes only worker events and heartbeat, plus its scoped event capability. A second run-specific ingress may expose only the provider gateway described in 21.2, with a separate run-scoped provider capability. Neither capability grants the other protocol. The harness sandbox must deny everything in the 21.2 denial set. No API accepts a caller role from an untrusted request body.

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

A dependency can also stop being completable. When a `blocks` dependency is cancelled, or archived before completing, its dependents keep `queued` but leave the eligible set with `state_reason=dependency_unresolved`, and the service opens an urgent job-scoped decision on each dependent: retry or replace the dependency, drop the edge, or cancel the dependent. A `failed` dependency does not trigger this decision because `failed -> queued` retry remains possible; the scheduler records the skip reason and the supervisor warns when the wait persists. Dependents never sit queued forever without a visible reason and a recorded way out.

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
6. create a revocable provider session without exposing the upstream credential;
7. start the selected harness with the run-scoped event and provider ingresses;
8. deliver the brief and event capability;
9. receive the worker's first authenticated heartbeat as the protocol acknowledgement;
10. mark the run active.

Every completed step is recorded. If a later step fails, the service either compensates safely or leaves a visible recoverable operation. It never forgets an orphaned worktree or pane.

### 18.4 Cleanup

Cleanup checks:

- run state is terminal;
- no uncommitted or untracked user work would be lost;
- delivery evidence is stored;
- no other active lease references the endpoint or worktree;
- the run's event and provider capabilities are revoked;
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

Worktrunk is the reference adapter. It owns creation, path resolution, and removal. `Diff`, `Merge`, and `InspectWorktree` are Git operations the adapter performs directly, because Worktrunk does not expose them. A native Git adapter is optional but useful for portability. The domain layer owns lifecycle policy; an adapter owns tool syntax.

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

Each adapter declares support for resume, non-interactive input, structured hooks, permission controls, model selection, reasoning-effort selection, worker filesystem isolation, provider endpoint override, and provider authentication mode. CrewBoss must not claim a capability that has not passed a live test.

Claude is the reference harness for v0.5 dispatch and isolation. Claude and Codex are required for 1.0. OpenCode is the next supported harness. Additional harnesses use the same contract.

### 19.4 Forge adapter

Required operations:

- `Probe`
- `ReadRemoteRef`
- `PublishHead`
- `FindOrCreatePullRequest`
- `ReadChecks`
- `ReadReviews`
- `MergePullRequest`
- `ClosePullRequest`
- `ResolveRevisionURL`

GitHub through `gh` is the reference adapter. GitLab follows after the GitHub contract is stable.

`PublishHead` receives the canonical repository, local worktree, expected local `head_sha`, one service-owned `source_ref`, and the nullable expected remote SHA from `deliveries.published_sha`. It first proves the worktree resolves to `head_sha`, then observes the remote ref. A missing ref is created only when the expected remote SHA is null. A ref already at `head_sha` is an idempotent success. A ref at the expected remote SHA may advance with a non-force fast-forward to a newly verified `head_sha`. Any other value returns `state_conflict`; the adapter never force-pushes, deletes, or silently chooses another ref. Those actions require a new exact operation and the approval required by 21.3. The recorded observation includes the remote identity, ref, before SHA, after SHA, and provider request identifier when available. The service updates `published_sha` only if the delivery generation and `head_sha` are still current.

`FindOrCreatePullRequest` requires `source_ref` and `expected_head_sha`. Before returning an existing or new PR, it proves both the remote source ref and the forge's PR head resolve to that SHA. A moved ref or a PR associated with another head is a conflict, not an idempotent match.

### 19.5 Capability negotiation

Every adapter returns a versioned capability document. A workflow fails before side effects if required capabilities are missing. Experimental support appears in `doctor` and JSON output; it is never described as verified support.

Harness capability documents report `worker_isolation` as `enforced`, `advisory`, or `none`, and `provider_auth` as `brokered`, `provider_run_scoped`, or `host_inherited`. `enforced` requires a live conformance probe proving every filesystem and egress denial in the 21.2 denial set while the worker can still use its own worktree and run-scoped ingresses. An enforced profile requires `brokered` or a provider-issued token that is independently proved short-lived, run-scoped, revocable, and unable to mint another credential. `host_inherited` always makes `worker_isolation=none`. `doctor` runs this probe for every supported harness and profile. A harness or provider-auth adapter version change invalidates the cached result until the probe passes again.

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

The supervisor writes a durable event before waking an agent. It uses bounded backoff and jitter for external polling.

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

Reconciliation preserves a persisted `return_state` while an aggregate remains suspended or waiting, per the return-state rule in 13.1. A pending resume or external-wait operation must complete its recorded checks before the domain transition consumes that field.

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
| `safe` | Use an enforced sandbox to read allowed repository data and prepare plans or reports. No source mutation, forge delivery, or general network egress; model traffic uses only the provider gateway. |
| `standard` | Use an enforced sandbox and isolated worktree, run declared checks, and prepare delivery. Merge and destructive cleanup need approval. |
| `autonomous` | Use an enforced sandbox to perform pre-approved project actions, including selected delivery operations, within exact policy limits. |
| `unsafe-host` | Run without a verified same-user isolation boundary. Intended only for controlled environments. Requires explicit operator activation and expires. |

No harness receives a dangerous bypass flag merely because it is installed. The harness adapter translates a CrewBoss permission profile to supported vendor controls and reports any gap.

`safe`, `standard`, and `autonomous` require `worker_isolation=enforced`. Their sandbox denies the CrewBoss control socket, state and configuration roots, upstream provider credentials, operator and boss credentials, unrelated worktrees, and other run directories; together with the egress rules below, this is the canonical denial set that other sections reference. It exposes only the run's worktree, declared tool paths, event ingress, provider-gateway ingress, and general egress proxy. Dispatch fails closed if any required denial cannot be proved.

Enforcement comes from a deny-by-default filesystem sandbox that the service applies when it launches the harness, not from the harness's own permission prompts. The reference mechanisms are Seatbelt (`sandbox-exec`) on macOS and a Linux user namespace with bind mounts. Each allows only the run's worktree, run-specific ingress sockets and spool directory, the general egress proxy, and the declared tool paths, and denies everything else. A harness the service cannot launch inside one of these reports `worker_isolation=none`, whatever its own permission features are.

Isolation constrains the network as well as the filesystem, because a harness needs model-provider connectivity while hostile repository code must not get free egress. The sandbox denies direct outbound network and exposes service-owned local gateways next to the event ingress. A general egress proxy enforces a per-profile host allowlist: `safe` permits no arbitrary external destination, `standard` and `autonomous` add only the hosts named in the project's `policy_json`, such as a package registry, and `unsafe-host` is unrestricted. For `safe`, model requests through the provider gateway are the only disclosed external data flow; they do not authorize package, forge, or arbitrary host access. The 19.5 conformance probe must show that a direct connection and a disallowed proxied host both fail, or the harness reports `worker_isolation=none`.

Model traffic uses a separate provider gateway outside the worker sandbox. The service reads the upstream API key, OAuth refresh token, or harness account credential from an operator-configured OS credential store or protected service credential source. It never mounts or copies that credential into the harness environment, filesystem, or process namespace, and the credential never enters the database, briefs, run artifacts, worker files, or logs. The worker receives only a short-lived capability bound to one run, harness, provider, model policy, and expiry. The gateway validates that capability, applies configured usage limits, adds the upstream credential, forwards only the model protocol, redacts authentication data from logs, and revokes the session when the run suspends or ends.

An enforced harness must support a verified provider endpoint override or a provider-issued run-scoped credential with equivalent properties. Its command sandbox must also prevent a child command from reading the harness process memory, environment, inherited descriptors, or another process namespace. If either condition cannot be proved for the installed harness and authentication mode, `provider_auth=host_inherited`, `worker_isolation=none`, and safe profiles fail closed. Subscription or browser-login credentials that cannot be mediated are therefore available only through explicitly approved `unsafe-host`; CrewBoss does not relabel them as safe.

`crewboss init` and `crewboss doctor` run the isolation probe and record the result. If no supported profile can prove enforcement on this machine, `init` leaves `permission_profile = "standard"` and prints the exact `unsafe-host` activation command. Dispatch then fails with `policy_refused` and repeats that instruction. CrewBoss never lowers the configured profile on its own.

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

An approval records action, exact target, scope, approver identity, method, and expiry. Every approval is single-use and consumed under 13.6; standing authority for repeatable actions is a grant under 21.6. The service hashes the receipt and binds it to the external operation. Changing the action invalidates the approval.

Approval methods are ranked. An `attested` approval comes from an operating-system user-presence check the service can verify, such as Touch ID through LocalAuthentication on macOS or a FIDO2 security-key touch. The mechanism sits behind one internal interface, like the sandbox in 31.9, so it can be replaced without changing the policy model. A `tty` approval is a fresh interactive confirmation on a local terminal. A terminal cannot prove a human: the attached coordinating agent runs under the operator's user ID, controls a terminal, and can read the screen, so it can type the confirmation itself. `tty` therefore protects against accidents and confused-deputy requests, not against a hostile or misaligned boss agent.

The guarantee that an agent cannot approve its own request is enforced only through an attested method. `init` and `doctor` probe which attested mechanism is available and record it. Where one exists, the actions in 21.3 require it. Where none exists, `tty` approvals are accepted, the receipt records the weaker method, and the guarantee narrows to the same honest statement 21.5 makes for `unsafe-host`: policy against mistakes, not a boundary against a hostile same-user agent. A same-user socket peer, boss message, or worker message is never accepted as operator approval. Reusable approval credentials remain outside every worker sandbox.

### 21.5 Repository trust boundary

Repository files, issue text, worker output, and pull-request comments are untrusted input.

- No untrusted value is interpolated into a shell command.
- Commands use argument arrays.
- Paths are resolved and checked against allowed roots.
- Symlink traversal is checked before writes and cleanup.
- Logs redact registered secrets and capabilities.
- Enforced worker sandboxes cannot open anything in the 21.2 denial set.
- The event ingress exposes only heartbeat and worker event actions; its token cannot call boss, approval, configuration, provider, or delivery APIs.
- The provider ingress accepts only its separate run-scoped capability and model protocol; it cannot call CrewBoss APIs or reveal, refresh, or export the upstream credential.
- Direct database access is a trusted service operation. File mode `0600` protects against other OS users, not another process with the same UID.
- Forge comments cannot change authority without operator confirmation.

These are security guarantees only for adapters whose live isolation probe passes. Under `unsafe-host`, they are API rules rather than a boundary against malicious same-UID code.

### 21.6 Autonomous grants

`merge_authority=policy`, away mode, and autonomous mode act only through the grants recorded in 12.1. A grant names one exact action, scope, grantor, method, expiry, and whether it is single-use, and it can never widen after creation. Granting uses the same operator methods as 21.4. `grant revoke` takes effect for any use whose minted approval has not yet committed.

Each use consumes the grant by minting one single-use approval in the same transaction, so every autonomous action leaves its own receipt and audit entry. An expired, revoked, or exhausted grant fails closed. Policy workflows treat a missing grant exactly like a missing approval: `approval_required`, exit code 5.

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
4. run configured review checks in parallel;
5. resolve required findings or record accepted exceptions;
6. reserve a unique service-owned remote source ref and record a publish operation;
7. publish `head_sha` without force and observe the remote ref at that exact SHA;
8. create or update the PR idempotently with that ref and expected SHA;
9. wait for required CI and review state;
10. confirm the local head, remote source ref, and PR head still equal `head_sha`;
11. obtain merge approval when policy requires it;
12. merge through the forge adapter;
13. store delivery evidence, including the remote ref observations;
14. clean up owned resources safely.

Red required checks are never merged. A review exception must be a named, scoped approval record.

A configured forge target may allow the non-force creation of the job's reserved source ref under `standard` policy. Publishing to another remote or ref is outside the recorded delivery target and requires approval under 21.3. A retry always observes the ref before pushing; it never assumes a failed response means the push did not happen.

`direct-pr` uses the same source-ref reservation, revision-pinned publication, PR identity, and drift checks. It skips only the additional review pipeline that distinguishes `verified-pr`; it never skips revision binding.

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
- It does not invent work while idle; idle is a healthy state and costs zero model tokens.

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
- delivery waiting too long on an external system;
- jobs queued behind a failed or unresolvable dependency.

Thresholds live in configuration. They are not public CLI timeout arguments on every command.

## 25. Backward compatibility and migration

### 25.1 Compatibility promise

The old commands remain supported through the full 1.x release line. They may be removed only in 2.0 or later, after deprecation warnings have shipped in at least two minor releases and the published migration guide is complete. Removal depends on this version window, not a machine-local usage counter. CrewBoss sends no usage telemetry by default.

### 25.2 Imported state

The migration tool reads, without modifying:

- the `crew.json` registry, both the captured v0.2 fixture format and the final v0.3 format with project identity;
- the merged PR #2 `events.jsonl` and `event-state.json` formats, plus the final v0.3 event-state revision;
- known CrewBoss-owned Worktrunk worktrees;
- known Herdr endpoints.

`migrate inspect` produces an import plan and conflicts. A normal `migrate apply` is a rehearsal import: it first creates a timestamped backup, copies one stable legacy snapshot under the write barrier, then imports records and its `legacy_import_checkpoints` row in one database transaction after releasing the barrier. The snapshot records the Bash registry revision and hash, the last complete event sequence and record hash, and the event-state revision and hash. Import invariants:

- Repeating the same checkpoint returns the stored result.
- A newer checkpoint updates imported non-authoritative records by stable legacy crew, run, and event identities without duplicating them.
- Registry revision, event sequence, and event-state revision must each be nondecreasing, and at least one must advance for a new checkpoint.
- If a revision is unchanged, its hash must also be unchanged.
- A lower coordinate, a changed event below the event high-water mark, or an equal coordinate with a different hash fails with `state_conflict`.

In v0.4 imported endpoints and worktrees are recorded in the `unknown` state, because no adapter exists yet to observe them; the v0.5 adapters reconcile them through the normal 13.3 path. Reconciliation against live external resources is therefore a v0.5 behavior, not a v0.4 promise. A rehearsal import never changes which engine may write.

### 25.3 Mapping

- old crew name -> project-scoped canonical job name plus a compatibility alias preserving the old case;
- old branch/path/pane/agent -> first imported run and endpoint;
- old `task` and latest prompt -> job objective and run amendment history;
- old blocked/done event -> durable event with imported source metadata;
- old `event-state.json` cursor and pending map -> `legacy` consumer cursor and parked events;
- old closed crew -> terminal endpoint plus preserved job/run state; a closed running or blocked crew imports as suspended with `return_state=active` or `blocked`, respectively.

An ambiguous repository or name is not guessed. It becomes an import conflict with a suggested command.

### 25.4 Rollout switch

During the bridge release:

- before final cutover, `CREWBOSS_ENGINE=bash` selects the old implementation;
- before final cutover, `CREWBOSS_ENGINE=service` selects the new implementation for the release's allowed rehearsal and contract-test surface;
- the default changes only after the service implements every compatibility command and the contract, migration, and live dispatch tests pass, which is v0.5 at the earliest;
- the Bash engine is frozen as a rollback path and does not implement `crewboss.cli.v1`;
- rollback keeps the pre-migration backup and does not pretend new service state can always be represented by the old registry.

The final handoff is `migrate apply --cutover`. It is a recorded saga with this order:

1. record the cutover operation and set the checkpoint to `cutover_pending`; this state alone does not stop Bash writes;
2. acquire the legacy-home write barrier exclusively;
3. create and fsync a `cutover-in-progress` marker that makes every Bash mutation fail closed after a crash;
4. capture the registry revision and hash, the last complete event sequence and hash, the event-state revision and hash, and any existing cutover-event spool while no legacy writer can advance them;
5. import through those exact high-water marks, deduplicate every spooled UUID, and commit the domain rows, legacy checkpoint including the spool hash, audit entry, and `service_authoritative` authority state in one SQLite transaction;
6. prove every spooled UUID is committed and no unobserved spool record remains;
7. atomically replace the in-progress marker with the service-engine marker;
8. release the barrier and route compatibility commands and legacy worker events to the service.

Recovery observes before acting:

- A crash while only `cutover_pending` is recorded leaves Bash authoritative; recovery takes a new snapshot instead of trusting the earlier plan.
- After the in-progress marker exists, a pre-commit recovery may remove it and reopen Bash only when the database is still at the previous rehearsal checkpoint and the cutover-event spool is empty.
- The presence of any spooled UUID makes recovery forward-only: it reacquires the barrier, imports every spooled event through normal deduplication, commits service authority, and completes the service marker.
- A crash after commit follows the same forward path for any event spooled before recovery reacquired the barrier.
- No recovery path reopens Bash with a preserved but unconsumed spool.

The cutover command verifies that a fresh legacy snapshot has the committed registry revision, event high-water mark, event-state revision, hashes, and no uncommitted spool UUID before it reports success.

`CREWBOSS_ENGINE=bash` cannot override a `cutover-in-progress` or service-authoritative marker. The rollback engine may write only in a restored pre-cutover home. After any service-only mutation, rollback means restoring that backup with an explicit loss summary or moving forward; it is never an implicit engine toggle.

## 26. Incremental roadmap

Each release is independently releasable. Reliability gates are mandatory even when they take more work. Human development cost is not used to remove a correctness requirement. Version names replace numbered roadmap phases so they cannot collide with the repository's historical phase documents and branch names.

### v0.2: Confirm and tag the event baseline

**Objective:** Verify merged PR #2 as the trustworthy Bash migration source and tag it.

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
- monotonic registry and event-state revisions, plus the shared legacy-home write barrier used by registry mutations, event append, and event-state checkpoints;
- frozen behavior and naming fixtures for the rollback engine;
- refreshed migration fixtures for the v0.3 registry format, since project identity changes the schema the v0.2 fixtures captured.

This release fixes Bash safety and repository-scoping defects only. It does not implement `crewboss.cli.v1`, request idempotency, or the new exit-code contract. Those fixtures are written now, but Go is their only implementation in v0.4.

**Public surface:** `doctor`, project-qualified crew selectors, and otherwise frozen human-oriented Bash commands.

**Acceptance gate:**

- two repositories may use the same crew name without collision;
- `remove`, `close`, and `open` work from a third directory;
- injected failures at every spawn step leave either no resource or a recorded recoverable resource;
- live Herdr and Worktrunk smoke tests pass;
- dangerous harness permissions require explicit configuration;
- concurrent registry, event, and event-state writers stop behind an exclusive cutover barrier, and a durable in-progress marker makes later Bash mutations fail closed;
- the Bash engine has no new JSON envelope or idempotency implementation;
- frozen rollback and naming fixtures pass.

### v0.4: Durable Go core

**Objective:** Introduce the service and SQLite without changing normal user commands.

**Deliver:**

- Go CLI and Unix-socket service;
- XDG home layout and owner-only permissions;
- SQLite migrations and WAL configuration through `modernc.org/sqlite`;
- core projects, jobs, runs, endpoints, events, consumer cursors with parked events, requests, operations, leases, approvals, and audit tables;
- legacy import checkpoints with registry and event high-water marks;
- transactional domain state changes;
- idempotent command API;
- the only implementation of `crewboss.cli.v1`, stable exit codes, and `--request-id`;
- contract fixtures written before the service implementation;
- Bash CLI shim and engine switch;
- `crewboss skill install|status|update` for managing the installed agent instructions;
- `migrate inspect` and `migrate apply`;
- service-owned backup creation, verification, and restore;
- Sigstore-signed release checksums, plus Developer ID signing and notarization on macOS.

**Public surface:** `daemon`, `config`, `backup`, `migrate`, and `skill`. The engine switch exists, but `CREWBOSS_ENGINE=service` is a contract-test and migration-rehearsal path in this release: the service cannot run endpoint or worktree commands until the v0.5 adapters exist, and the section 14.4 legacy event bridge also arrives with v0.5 dispatch. The default engine remains `bash`.

**Acceptance gate:**

- frozen Bash regression tests pass for the rollback engine without requiring v1 JSON output;
- `crewboss.cli.v1` fixtures pass against the Go engine only;
- current main migration fixtures import without data loss;
- closed running and blocked fixtures import with `return_state=active` and `blocked`, respectively, and remain deterministic after restart;
- repeated rehearsal imports are idempotent, reject rewritten history below their high-water mark, and do not change engine authority;
- killing the service between external saga steps recovers safely;
- 100 concurrent event writes have unique ordered sequences and no loss;
- stale generations cannot overwrite new state;
- the socket refuses another local user;
- same-user peer credentials alone cannot obtain operator, boss, or approval authority;
- the approvals table is migrated with its audit relationship, while public approval workflows remain unavailable until v0.5;
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
- Herdr session and Claude harness adapters sufficient for reference dispatch;
- explicit worker event commands, separate event and provider ingresses, and scoped capabilities;
- a service-owned provider gateway and revocable run-scoped provider sessions for the reference Claude harness;
- the section 14.4 legacy bridge and cutover routing, so Bash-spawned workers stay supervised while both engines coexist and after service authority begins;
- an isolation conformance probe for the reference Claude harness and every supported safe profile;
- enforced worker isolation, including the provider gateway, general egress proxy, and allowlist, for `safe`, `standard`, and `autonomous` profiles;
- minimal approval request, grant, deny, expiry, and single-use consumption workflows for `unsafe-host` and later live boss-lease takeover;
- Explore reports and promotion to Build;
- project, job, diff, logs, and report commands.

**Public surface:** `project ...`, `job ...`, `approval list|show|grant|deny`, and internal `worker ...` protocol.

**Acceptance gate:**

- register three repositories and dispatch ten jobs without name collision;
- dependency order is stable and explainable;
- a worker retry cannot duplicate completion or a question;
- Herdr and Claude complete the reference Build and Explore dispatch contract;
- with `worker_isolation=enforced`, Claude completes a real model turn through the provider gateway while the worker cannot recover or use the upstream credential, open the control socket, state database, config, or another run's files, or reach a network destination outside its profile's egress allowlist;
- suspending or ending the run revokes its provider session, and replaying the run-scoped capability cannot create another session or reach the provider;
- without enforced isolation, safe profiles refuse dispatch and only explicitly approved `unsafe-host` is available;
- an `unsafe-host` approval is exact, expiring, consumed once, and cannot authorize another action;
- Explore cannot enter code delivery;
- suspending once from `active` and once from `blocked`, restarting the service, and resuming returns each job and run only to its recorded state;
- promotion begins from a clean current base;
- no coordinator write occurs in a primary checkout;
- every failed dispatch step is reconciled or safely compensated;
- writes raced immediately before cutover are present in SQLite, writes attempted during cutover fail closed or retry, and compatibility writes after cutover reach only the service;
- killing `migrate apply --cutover` before its SQLite commit with an empty spool may reopen Bash; repeating the crash with a spooled terminal event must finish forward to service authority and commit exactly one copy of that event;
- killing cutover after its SQLite commit, then advancing the legacy event checkpoint and emitting a terminal event, recovers service authority with the same registry revision, event high-water mark, and event-state revision and exactly one copy of that event.

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
- taking over a live boss lease requires an exact unexpired approval;
- an expired old boss cannot acknowledge events after takeover;
- kill and restart the service, boss endpoint, and one worker endpoint in separate tests;
- each recovery produces one clear state and no false success;
- restart during a resume saga leaves the aggregates suspended until capability delivery succeeds, then consumes each stored return state exactly once;
- a one-hour idle-fleet soak records every child process launch and outbound request, with no harness launch and zero requests to a model provider;
- blocked questions remain queued for at least seven days or configured retention;
- supervisor retries are bounded and visible.

### v0.7: Verification and delivery

**Objective:** Turn worker output into evidence-backed results.

**Deliver:**

- checks and deliveries tables and workflows;
- delivery and destructive-cleanup approval requests built on the v0.5 approval workflow;
- revision-bound local verification;
- `verified-pr`, `direct-pr`, `local`, and `report` modes;
- GitHub/`gh` forge adapter;
- revision-pinned remote publication, PR creation/update, CI wait, review status, and merge;
- review checks and finding resolution;
- local merge with branch-drift protection;
- safe cleanup and delivery report.

**Public surface:** `job verify`, `job deliver`, delivery prompts through the existing `approval ...` commands, and delivery status.

**Acceptance gate:**

- changing HEAD invalidates every earlier passing check;
- publishing creates or fast-forwards only the reserved source ref from its recorded `published_sha`, and its observed remote SHA equals the newly verified `head_sha` before PR creation;
- a lost publish response retries idempotently, while a concurrently moved source ref returns `state_conflict` without force-pushing;
- retrying PR creation returns the same PR;
- PR creation refuses a forge-reported head that differs from the recorded `published_sha`;
- red required CI cannot be merged;
- protected merge without approval returns exit code 5;
- a consumed approval cannot authorize a second different merge;
- local target movement forces re-verification;
- restart while waiting once from `verifying` and once from `ready` returns each job only to its stored state when the named condition resolves;
- cleanup refuses dirty or unowned resources;
- delivery evidence identifies the exact base SHA, local head SHA, source ref, published SHA, and forge-reported PR head SHA.

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
- Codex harness adapter and expanded Claude adapter capabilities at verified quality;
- OpenCode adapter at verified or clearly experimental quality;
- permission-profile translation, isolation probes for every supported harness and profile, and gap reporting;
- autonomous mode with scoped, expiring policy grants through the 12.1 grants model and `grant` commands;
- webhook or local notification connector interface;
- GitLab forge adapter;
- self-update verification for the pinned Sigstore identity, checksum manifest, and macOS notarization, with explicit install approval;
- fault-injection and adapter conformance suites.

**Public surface:** adapter selection, permission profiles, `boss mode autonomous`, `grant ...`, update status.

**Acceptance gate:**

- the same Build and Explore contract passes on Herdr and Tmux;
- Claude and Codex both complete the explicit worker protocol live tests;
- Claude and Codex each complete a model turn through a verified brokered or provider-issued run-scoped session without exposing an upstream credential;
- unavailable resume or permission features are reported before dispatch;
- `doctor` proves each supported safe profile denies control and state paths before it reports `worker_isolation=enforced`;
- autonomous mode cannot merge or perform destructive cleanup beyond its exact grant;
- expired, revoked, and exhausted grants fail closed;
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
- upgrade from a v0.2 fixture to v1.0 preserves imported crews as jobs, plus their events and endpoints;
- a fresh user can install, run `doctor`, register a project, and dispatch a job using only shipped documentation.

## 27. Feature parity matrix

This matrix tracks the user outcome, not identical implementation. Release contents and acceptance gates in section 26 are authoritative; the target-release column is a tracking summary.

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
7. Complete one Build job through `verified-pr` and prove its local head, published source ref, and PR head are the same verified SHA.
8. Complete one Build job through `local` delivery.
9. Complete one Explore report and promote it to a new Build job.
10. Route jobs through at least two Crew Leads.
11. Block one worker on a decision, detach the boss, reattach elsewhere, and answer it.
12. Kill and restart the service during a dispatch saga.
13. Remove one worker endpoint during active work and reconcile it without false success.
14. Change a branch after verification and prove that delivery is invalidated.
15. Attempt an unapproved merge and destructive cleanup and prove both are refused.
16. Run a same-user worker probe that attempts to open the control socket, state database, operator and upstream provider credentials, harness process state, another run, and a network destination outside its egress allowlist; every safe profile must deny it while one permitted model turn through the provider gateway succeeds.
17. Restart the terminal backend and recover owned endpoints where the adapter supports it.
18. Finish all work and prove safe cleanup of owned worktrees, endpoints, leases, and capabilities.

Pass conditions:

- no job, decision, event, or artifact is lost;
- repeated requests do not duplicate PRs, questions, merges, or completion;
- all delivery evidence points to exact revisions;
- primary checkouts remain untouched by worker runs;
- no unsafe action occurs without a valid approval;
- every claimed safe profile has recorded `worker_isolation=enforced` evidence;
- recorded idle-soak evidence shows that supervision makes zero model calls;
- the final fleet report explains every job outcome and remaining resource.

## 29. Testing and quality strategy

### 29.1 Test layers

**Unit tests** cover names, configuration, policies, state transitions, brief validation, scheduling, and adapter error normalization.

**Property tests** generate transition sequences, suspended and waiting return-state pairs, dependency graphs, duplicate events, stale generations, and idempotent request retries.

**Store tests** use real SQLite files and test migrations, constraints, concurrent reads, crash recovery, and WAL checkpoints.

**Contract tests** run the same CLI JSON fixtures and adapter behavior against fakes and real adapters.

**Integration tests** create temporary Git repositories and exercise complete worktree, run, check, and delivery sagas.

**Migration tests** import fixtures from the current main registry and merged PR #2 event format, including corrupt and ambiguous cases.

**Fault-injection tests** stop processes, delay responses, duplicate calls, move branches, remove panes, lock files, and interrupt external operations at each recorded step.

**Security tests** cover path traversal, symlink changes, shell injection, malicious repository instructions, event and provider token scope, provider credential recovery attempts, approval replay, socket ownership, and log redaction.

**Live tests** run supported combinations of Herdr, Tmux, Worktrunk, Claude, Codex, GitHub, and GitLab where credentials and binaries are available.

**Idle-soak tests** inject a recording process launcher and recording outbound transport into the service. Subprocess network traffic uses a counting deny proxy. A one-hour test runs the daemon, supervisor, and an attached but inactive boss lease. Any harness launch or request to a model-provider host fails the gate. Process and request records are stored as release evidence.

### 29.2 Required performance and reliability targets

- Warm local read commands finish within 100 ms at the 95th percentile for 1,000 jobs.
- A worker mutation is committed before success is acknowledged.
- 100 concurrent event writers produce no lost events and one ordered stream.
- Reconciliation of 100 recorded jobs finishes within 10 seconds, excluding external network wait.
- The recorded one-hour idle soak shows zero harness launches and zero requests to model-provider hosts, with bounded operating-system polling.
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

**Decision:** Role-isolation claims require a live-tested harness sandbox that enforces the 21.2 denial set, including process inspection. Workers receive separate run-scoped event and provider ingresses. Upstream model credentials remain in the service-owned provider gateway; a harness that cannot use brokered or provider-issued run-scoped authentication has `worker_isolation=none`. Safe profiles fail closed without these capabilities. `unsafe-host` remains available through explicit expiring approval, but its policy is not described as a security boundary against hostile same-UID code.

### 31.9 The sandbox mechanism is platform-specific and not guaranteed

**Risk:** `sandbox-exec` is deprecated by Apple, and Linux user namespaces are restricted or unavailable on some hosts and inside some containers. If the reference mechanism disappears, every safe profile loses enforcement at once.

**Decision:** Isolation is applied by the service, behind one internal interface, so a mechanism can be replaced without touching the policy model. The probe is the contract, not the mechanism. When no mechanism passes, CrewBoss reports `worker_isolation=none` and offers only `unsafe-host` with an expiring approval. It never redefines a weaker mechanism as enforced.

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
