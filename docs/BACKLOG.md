# Active maintenance backlog

Reviewed 2026-10-09 against main `dc3c7865da4d752f1db413c03e3586d1f06b064c`.
This file is the one active repository backlog. Move completed items to the changelog
or a linked merged PR; do not keep a second checklist in architecture or audit docs.
The GitHub open-issue and open-PR lists were empty at this inspection.

## Qualify the prepared local fixes

1. **P1: activation environment and rollback recovery.** Review the `GOROOT`/stdin
   isolation and the occupied rollback recovery-slot guard. New regression suite:
   `tests/activation-probe-env.bash`. Linux fixtures pass; obtain exact-patch macOS
   Bash 3.2 and Windows applicable coverage before publication.
2. **P2: literal, nonempty `each` input.** Review prevalidation before any child
   invocation. Run `tests/each-input.bash`, including wildcard filenames, empty
   elements and ordered duplicate versions.
3. **P2: exported caller environment.** Review the run/each entry snapshot and
   restoration boundary, including scalar/array name collisions, empty/newline
   values, readonly shell metadata, PID/argv/signals and Bash 3.2 behavior. Keep GOS
   state namespaces excluded; `child-environment-cleanup.bash` verifies TERM/INT
   cannot turn inherited cleanup paths into deletion targets.
4. **Required qualification.** Run the complete local validation with Ruby,
   ShellCheck, shfmt and supported optional shells. The audit environment lacked
   those tools. Existing main CI success is not qualification of these changes.

## Evidence-driven resilience work

- Add failure-injection coverage for shared versions/cache roots used by different
  activation roots. Current mutation locks are scoped to the activation path;
  record supported sharing/concurrency semantics before changing lock ownership.
- Broaden activation failure tests to malformed successful version output and
  repeated/interrupted repair, without weakening checksum or rollback protection.
- Extend fault injection around cleanup failures and termination after validation;
  distinguish preserved recovery residue from success and verify retry behavior.

## Keep, do not duplicate

Keep the single Bash distribution, command/env manifests and generated surfaces,
JSON schemas, Windows ownership receipts, canary/release checks, security guidance,
and changelog history. Do not remove portable branches or fixture helpers based
only on low textual reference counts. This audit found no proven unused production
function suitable for deletion.
