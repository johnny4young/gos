# Active maintenance backlog

Reviewed 2026-10-09 against main `dc3c7865da4d752f1db413c03e3586d1f06b064c`.
This file is the one active repository backlog. Move completed items to the changelog
or a linked merged PR; do not keep a second checklist in architecture or audit docs.
The GitHub open-issue and open-PR lists were empty at this inspection.

## Evidence-driven resilience work

- Add failure-injection coverage for shared versions/cache roots used by different
  activation roots. Current mutation locks are scoped to the activation path;
  record supported sharing/concurrency semantics before changing lock ownership.
- Broaden activation failure tests to malformed successful version output and
  repeated/interrupted repair, without weakening checksum or rollback protection.
- Extend fault injection around cleanup failures and termination after validation;
  distinguish preserved recovery residue from success and verify retry behavior.

## Child environment follow-ups

- A caller-exported `SHELLOPTS` is readonly and is not restored, so a child Bash
  inherits gos's own `errexit`/`nounset`/`pipefail`. Decide whether `run`/`each`
  should capture caller shell options before `set -euo pipefail` and reset them
  before exec.
- The exported-value snapshot is keyed on a literal `run`/`each` first argument and
  relies on `compgen -e`. A new alias, a global flag before the command, or a Bash
  built without programmable completion silently skips restoration; move the
  snapshot behind the dispatcher or fail closed when it cannot be taken.

## Keep, do not duplicate

Keep the single Bash distribution, command/env manifests and generated surfaces,
JSON schemas, Windows ownership receipts, canary/release checks, security guidance,
and changelog history. Do not remove portable branches or fixture helpers based
only on low textual reference counts. This audit found no proven unused production
function suitable for deletion.
