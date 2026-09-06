# gos JSON schemas

Every `--json` output of gos is described by a [JSON Schema](https://json-schema.org/) (draft-07) in this directory. `tests/json-schema.bash` validates the real output of each command against its schema, so the schemas are contracts, not documentation that may drift.

| Command | Schema |
|---|---|
| `gos check --json` | [check.schema.json](check.schema.json) |
| `gos current --json` | [current.schema.json](current.schema.json) |
| `gos list [--minor] --json` | [list.schema.json](list.schema.json) |
| `gos list --installed [--minor] --json` | [list-installed.schema.json](list-installed.schema.json) |
| `gos platforms [version] --json` | [platforms.schema.json](platforms.schema.json) |
| `gos status --json` | [status.schema.json](status.schema.json) |
| `gos which [version] --json` | [which.schema.json](which.schema.json) |
| `gos verify [version] --json` | [verify.schema.json](verify.schema.json) |
| `gos self-verify --json` | [self-verify.schema.json](self-verify.schema.json) |
| `gos env --json` | [env.schema.json](env.schema.json) |
| `gos doctor [--fix] --json` | [doctor.schema.json](doctor.schema.json) |
| `gos prune [--rollback] [--dry-run] --json` | [prune.schema.json](prune.schema.json) |
| `gos version --json` | [version.schema.json](version.schema.json) |
| `gos use --print --json` | [use-print.schema.json](use-print.schema.json) |
| `gos __commands --json` | [commands.schema.json](commands.schema.json) |
| `gos __env --json` | [env-reference.schema.json](env-reference.schema.json) |
| any failed `--json` command | [error.schema.json](error.schema.json) |

Compatibility rules:

- Fields are only added, never renamed or removed, within a major version of gos. New fields may appear without a schema bump; consumers should ignore unknown keys even though the schemas say `additionalProperties: false` (that strictness is for the tests, which must notice every new field).
- A field that can be absent today is listed without `required`; a field that can be `null` says so in its `type`.
- Failures print exactly one document, either the command's report (`verify`, `self-verify`, `doctor` keep their report and signal the failure through `ok`/`status` and the exit code) or an error document.
