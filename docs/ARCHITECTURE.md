# Architecture

gos is one Bash script. This page is the map a contributor needs to change it
safely: where things live in `gos.sh`, how a command becomes help, docs, and
completions, how an install stays crash-safe, what gos keeps on disk, and the
constraints (bash 3.2, no dependencies) that decide what code is acceptable.

## Why one file

`gos.sh` is the product, not a build artifact. Users are asked to `curl | bash`
it, so the whole thing has to be readable before it runs, and it has to run on a
stock machine: bash 3.2 (macOS ships that), plus `curl` or `wget`, `tar`, and a
SHA-256 tool. `jq` or `python3` make feed parsing nicer but a `grep` scrape works
without them. gos never installs optional parser dependencies or generates
runtime code; it only downloads the release metadata and Go archives requested
by its commands.

That is why there is no module system, no config file, no generated per-version
shim layer, no telemetry, and no rewrite in Go: a Go version manager that needs
Go is a bootstrap paradox, and every one of those would cost the auditability
that makes `curl | bash` defensible. The packaged Windows `gos.cmd` launcher is
the narrow exception that locates Git Bash and delegates to the same `gos.sh`.

## Map of `gos.sh`

Sections, in file order, with the functions that matter:

| Section | What lives there |
|---|---|
| Configuration | `GOS_*` defaults from the environment; trailing-slash normalization. Every user-facing knob is an env var (see README "Configuration"). |
| Helpers | `_gos_cleanup_tmp` (the EXIT trap), `_gos_os`/`_gos_arch`, JSON escaping, color gating (`_gos_color_enabled` is TTY-only and off under `--json`/`NO_COLOR`), `_gos_error`/`_gos_warning`/`_gos_progress`, path validation (`_gos_reject_unsafe_path`, `_gos_validate_install_dir`, `_gos_validate_versions_dir`, `_gos_validate_cache_dir`), download helpers (`_gos_download`, `_gos_download_stdout`). |
| Go downloads feed | `_gos_feed_json` (memoized per run, optional on-disk TTL cache), the jq → python3 → grep parser cascade (`_gos_feed_versions`, `_gos_fetch_checksum`, `_gos_platforms_for_version`), `_gos_resolve_bare_minor`. |
| Checksums and cache | `_gos_sha256`, `_gos_try_cache`, `_gos_store_cache`, checksum policy (`GOS_REQUIRE_CHECKSUM`), the `.sha256` companion fallback. |
| Privilege and locking | `_gos_needs_sudo` / `_gos_sudo` / `_gos_sudo_for` (escalation decided per target path), `_gos_acquire_lock` / `_gos_release_lock` / `_gos_lock_state`. |
| Activation | `_gos_activate_install` (move or link), `_gos_activate_rollback`, `_gos_restore_backup`, `_gos_rollback_state`, `_gos_install_version` (the whole install pipeline). |
| Project resolution | `.go-version` / `.tool-versions` / `go.mod` readers, `_gos_resolve_project_version`, `_gos_resolve_installed_version`. |
| Version ordering | `_gos_sort_versions` (awk, semantic: beta < rc < release), `_gos_go_version_is_newer`, `_gos_newest_per_minor`, `_gos_semver_is_newer` for gos's own version. |
| Commands | one `cmd_<name>` per command in the manifest, plus hidden `cmd___commands`, `cmd___versions`, `cmd___project_version` used by completions and the auto-switch hook. |
| Completions | the three shell completions embedded as heredocs between `# gos-completions:<shell>:begin/end` markers (generated, never edited by hand). |
| Manifest and help | `_gos_command_manifest` (the source of truth), `cmd_help`, `_gos_suggest_command`. |
| Entrypoint | `main`: leading `--json` gate, per-command preconditions (validations, lock), dispatch. |

## The command manifest

`_gos_command_manifest` reads a heredoc of `name|usage|description|group` lines and
formats effective usage by appending JSON options from `GOS_JSON_COMMANDS`.
The conditional `use [--print [--json]]` form stays in its manifest entry.
Entries are ordered by task group for help and generated command lists.
`__commands --details` retains the three-field `name|usage|description` format;
`__commands --details --json` includes the additive `group` field.
This effective manifest, together with `_gos_env_manifest` (`gos __env`,
`name|scope|default|description`), is the single source for:

- `gos help` and `gos help <command>`, and the usage line of every argument
  error (`_gos_usage`)
- the README command table and configuration table
- the man page `docs/gos.1` (COMMANDS and ENVIRONMENT)
- the command lists inside the three completion files
- the completions embedded back into `gos.sh`

`scripts/sync-command-surfaces.bash` is the only generator: one Ruby target
table names every marked block (or whole file) and its renderer, everything is
rendered in memory first, `--check` reports every stale surface at once, and
`--write` snapshots the targets (listed by `--targets`) and restores them if a
write fails. It is a CI gate, so none of those surfaces can drift from the
manifests.
The per-command *flag* completions below the generated markers are still hand
written in each shell file. Tests compare them with effective manifest flags
(including JSON) and exercise Bash/Fish queries and real Zsh ZLE completion in
an isolated, time-bounded pseudo-terminal.

Adding a command therefore means: one manifest line, one `cmd_<name>` function,
one dispatcher case (with the right preconditions), the flag arms in the three
completion files, tests, and a CHANGELOG entry; then `--write`.

Because `|` is the field separator, a usage or description can never contain
one.

## The install transaction

`_gos_install_version` is a pipeline whose only irreversible step is the last
one:

1. Validate the version and the target directories; fail before any network
   access on bad configuration.
2. Resolve the expected checksum: default feed first (small, fresh), then the
   `include=all` feed for older versions, then the `.sha256` companion file next
   to the archive. `GOS_REQUIRE_CHECKSUM=1` refuses to continue without one;
   `=feed` additionally refuses the same-origin companion file.
3. Reuse a cached archive if its hash matches; otherwise download to a
   resumable `.partial` in the cache (curl `-C -`), verify, and promote it to
   the cache entry.
4. Extract into a temp staging directory (`mktemp -d`, removed by the EXIT
   trap) and check that `go/bin/go` exists.
5. Activate. Flat layout: rename the staged tree into `GOS_INSTALL_DIR`.
   Side-by-side layout (`GOS_VERSIONS_DIR` set): move it to
   `GOS_VERSIONS_DIR/go<version>` and point the `GOS_INSTALL_DIR` symlink at it.

Activation (`_gos_activate_install`) is the same saga in both layouts:

```
mv  GOS_INSTALL_DIR  ->  GOS_INSTALL_DIR.gos-backup.<pid>     (backup)
mv/ln  new tree     ->  GOS_INSTALL_DIR                       (activate)
GOS_INSTALL_DIR/bin/go version                                (validate)
mv  backup          ->  GOS_INSTALL_DIR.gos-rollback           (keep for gos rollback)
```

Between the first and the second step the machine has no Go. That window is
covered by `GOS_ACTIVATION_BACKUP`: while it is set, the EXIT trap
(`_gos_cleanup_tmp`, also reached from the INT/TERM traps) moves the backup back
if the slot is empty. It is armed before the backup rename (Bash can defer a
trapped signal until the foreground `mv` returns), kept armed
through validation and any restore attempt, and cleared only once the swap is
complete or the restore succeeded. `gos rollback` (`_gos_activate_rollback`)
runs the same saga with the rollback slot as the source.

Commands that mutate a Go installation hold `GOS_INSTALL_DIR.gos-lock/` (a
`mkdir` lock with the pid inside) so concurrent installs, switches, and
rollbacks fail fast instead of racing. `gos self-update` instead locks the
resolved gos script path (`gos.sh.gos-lock/`): shells with different
`GOS_INSTALL_DIR` values can still replace the same script. Read-only commands
and dry runs never take a lock.

## Privilege

gos never runs as root by itself. `_gos_sudo` escalates a single `mv`, `rm`,
`mkdir`, or `ln` only when the nearest existing parent of the path being
written is not writable, retrying with `sudo` once when a plain attempt fails
with a permission error. The decision is made per target path
(`_gos_sudo_for`): the install slot may be root-owned while the versions tree
is the user's, and vice versa. No user-controlled string is ever interpolated
into a `sudo sh -c`.

## Trust boundaries

- The version list and checksums come from `https://go.dev/dl/?mode=json`.
  Archives come from `https://go.dev/dl/` (redirecting to `dl.google.com`) or
  from `GOS_DOWNLOAD_MIRROR`; mirror bytes are only accepted when an official
  checksum verifies them.
- The on-disk feed cache (`feed-default.json`, `feed-all.json`, TTL
  `GOS_FEED_TTL`) is used for discovery only (`list`, `platforms`, `check`,
  completions, resolving a bare minor). A checksum lookup never reads it: if the
  in-memory copy came from disk, it is re-downloaded first.
- The `.sha256` companion file lives on the same host as the archive, so it is
  a weaker source than the feed; `GOS_REQUIRE_CHECKSUM=feed` rejects it.
- `gos self-update` always fails closed: the release `checksums.txt` must
  contain exactly one digest for `gos.sh`, the download must hash to it, parse
  with `bash -n`, carry exactly one `GOS_VERSION`, and be newer than the running
  script.
- All downloads are HTTPS-only across redirects with a TLS 1.2 floor and are
  bounded (`--max-time` for metadata, stall detection for archives).

## On-disk state

gos has no database; its state is the filesystem:

| Path | Role |
|---|---|
| `$GOS_INSTALL_DIR` | Active Go: a real directory (flat) or a symlink into the versions tree (side-by-side). |
| `$GOS_INSTALL_DIR.gos-rollback` | The previous installation, target of `gos rollback`. A dangling link here means its version was uninstalled (`gos prune --rollback` clears it). |
| `$GOS_INSTALL_DIR.gos-backup.<pid>`, `.gos-current.<pid>` | Transient slots of an activation in progress; crash residue if left behind (`gos status`/`doctor` report it, `gos prune --rollback` removes it). |
| `$GOS_INSTALL_DIR.gos-lock/pid` | The mutation lock. |
| `<resolved gos script>.gos-lock/pid` | The path-scoped self-update lock. |
| `$GOS_VERSIONS_DIR/go<version>/` | Installed versions in side-by-side mode. |
| `$GOS_CACHE_DIR/go*.tar.gz`, `go*.zip`, `*.partial` | Verified archive cache and resumable partial downloads. |
| `$GOS_CACHE_DIR/feed-default.json`, `feed-all.json` | Discovery feed cache. |
| `./.go-version` | Written by `gos pin`, read (with `.tool-versions` and `go.mod`) by `gos use`, `gos run --`, `gos status`, and the auto-switch hook. |

Invariant, enforced by `tests/workflows.bash`: every function that writes under
`GOS_CACHE_DIR` has a matching reclaim in `cmd_prune`.

## Output contracts

- stdout is data; stderr is diagnostics. Errors are `Error: ...` on stderr;
  warnings are `Warning: ...` on stderr. Exit 1 is a generic failure; 2 is
  invalid arguments/configuration, 3 a download/feed failure, 4 a verification
  failure, and 5 a blocking mutation lock. `gos each` keeps exit 1 when any
  version fails; `gos run` passes through its child command's exit status.
- `--json` (leading or per command) is the stable machine contract for the
  commands listed in `gos help`; fields are only ever added. Failures print
  one `{"error":{"code":"usage|network|verification|lock|failure","message":"..."}}`
  document. Doctor retains its diagnostic report and exit 1 for problems;
  invalid doctor arguments still produce a usage error document.
- `_gos_fail` records a class in the parent process and the EXIT trap promotes
  generic status 1 after cleanup. A classified failure inside a subshell cannot
  update its parent: fetch/classify before pipelines or substitutions. Handled
  validator probes (doctor) must isolate their state instead. Recognize JSON
  before preflight, but never scan child arguments of `run` or `each`.
- Bare `gos` is an offline three-line status, including an explicit Project
  line when no manifest is found. `gos help` remains the full command listing.
- Install progress goes to stdout for `install`/`latest`/`use` and to stderr
  for `run`/`each`, whose stdout belongs to the command they run.
- Color and progress bars appear only on a TTY and never under `--json`,
  `NO_COLOR`, `GOS_NO_COLOR=1`, or `TERM=dumb`.

## The test harness

The suites in `tests/` are hermetic: each builds a directory of fake `curl`,
`sha256sum`, `tar`, `go`, `mv`, `sudo`, ... on `PATH` and drives `gos.sh`
through the CLI. `scripts/run-tests.bash` discovers every tracked
`tests/*.bash` (the `lib*.bash` files are shared helpers, not suites), reads
each suite's `# gos-suite:` header for its per-OS rules, and runs them in
parallel; adding a suite is adding a file. The CLI feature suites (`cli-*`,
`install-cache`, `lock-rollback`, `doctor-status`, `project-env`,
`feed-check`, `self-update`, `side-by-side`, `unit-versions`, `downloaders`,
`property-versions`) share
`tests/lib-features.bash`, whose `run_gos` also runs cases with a restricted
`PATH` exposing only `jq`, only `python3`, or neither. CI requires both
parsers; local runs report unavailable parser cases explicitly.
`tests/install-transaction.bash` injects rename and removal
failures, and kills gos between the two renames of a rollback, to prove the
saga above. `tests/workflows.bash` asserts repository invariants (pinned
actions, job timeouts, generated surfaces, doc fragments). The nightly canary
workflow is the only thing that talks to the real go.dev.

`scripts/validate-local.bash` runs everything CI runs; `--strict` fails when an
optional tool CI requires is missing locally.

## Bash 3.2 rules

macOS ships bash 3.2 and CI runs the suites under `/bin/bash` there, so:

- no `mapfile`/`readarray`, `declare -A`, `${var^^}`/`${var,,}`, `local -n`,
  `|&`, or `globstar`;
- expand a possibly-empty array as `${arr[@]:+"${arr[@]}"}` (a bare
  `"${arr[@]}"` is an unbound-variable error under `set -u`);
- never `local x=$(cmd)`: the `local` masks the exit status;
- keep regexes in a variable and match with `[[ $s =~ $pattern ]]` under
  `local LC_ALL=C`;
- guard every command substitution whose failure matters
  (`x=$(cmd) || x=""`), since `set -e` aborts on a failing assignment;
- prefer parameter expansion over `dirname`/`basename`/`grep` in code that runs
  per prompt or per directory level.

Portability beyond bash: no `sort -V`, `grep -P`, `sed -i`, `readlink -f`, or
`find -printf`; `stat` is probed GNU-first then BSD.
