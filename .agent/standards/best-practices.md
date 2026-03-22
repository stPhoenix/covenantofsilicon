## Purpose
This guide gives practical guardrails so code remains readable, testable, and easy to extend. Refer to it whenever creating a new module, reviewing a PR, or making process choices.

## Core Principles
- **KISS (Keep It Simple, Stupid)**: Prefer the least complex approach that satisfies the requirement; resist premature abstractions and speculative features.
- **DRY (Don’t Repeat Yourself)**: Consolidate duplicated knowledge into a single source of truth; use shared helpers, libraries, or configuration instead of copy/paste.
- **Single Responsibility**: Every component (function, struct, service) should have one reason to change; split logic when a unit mixes concerns.
- **Fail Fast**: Validate inputs early, panic only when invariants break, and surface errors at boundaries; it tightens feedback loops and simplifies debugging.
- **Make It Observable**: Instrument with logs/metrics/traces at meaningful checkpoints so operators can see what the system is doing.

## Planning & Design
- Capture the problem before the solution: summarize business goal, constraints, and measurable success criteria in the issue or PR description.
- Use sequence diagrams or quick sketches for non-trivial flows; they align teammates before code exists.
- Break work into vertical slices that deliver a usable increment; avoid “big bang” branches.
- Choose data structures after confirming access patterns; benchmark or prototype if uncertainty remains.

## Testing & Quality Gates
- Cover happy path plus critical edge cases before merging; ensure tests fail without the feature (red-green-refactor).
- Write fast unit tests for pure logic and targeted integration tests for boundaries (DB, APIs). Avoid end-to-end overuse.
- Seed fixtures deterministically; avoid “sleep” based timing—use fakes or clock injection.
- Track code coverage trends, but do not chase 100%; focus on risky modules and recently changed files.
- Automate linters/formatters in CI so reviews center on architecture, not whitespace.

## Documentation & Communication
- Update README/ADR/API docs alongside code changes; stale docs erode trust.
- Prefer short, high-signal comments explaining intent or invariants; avoid narrating obvious code.
- When decisions deviate from standards, log them in an ADR or issue comment with rationale and date.
- Share status early when blocked; propose next steps instead of waiting for direction.

## Operational Excellence
- Add structured logging (key/value) around external calls and retries so incidents pinpoint root causes quickly.
- Establish timeouts and circuit breakers for network interactions; never rely on defaults.
- Measure and alert on SLO-aligned metrics (latency, error rate, saturation); alerts must be actionable.
- Document runbooks for recurring tasks (deployments, migrations) and keep them versioned with code.

## Continuous Improvement
- After each release or incident, capture lessons learned and feed them into backlog tasks or new checks.
- Periodically refactor high-churn areas; small, frequent cleanups are cheaper than large rewrites.
- Mentor peers by pairing and leaving constructive review comments—teaching reinforces your own understanding.

Use these practices as the baseline. When exceptions arise, document the reasoning and confirm alignment with the team lead before proceeding.
