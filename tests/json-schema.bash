#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# Every --json output validates against its schema in docs/schema, every JSON
# command has a schema, and the schema index lists every schema.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"
schema_dir="${repo_root}/docs/schema"

# Every visible JSON command must map to at least one schema; hidden helpers
# and use --print have their own names.
json_commands=$(sed -n 's/^GOS_JSON_COMMANDS="\(.*\)"$/\1/p' "$script")
[ -n "$json_commands" ] || fail "could not read GOS_JSON_COMMANDS"
schema_for_command() {
  case "$1" in
    list) echo "list list-installed" ;;
    use) echo "use-print" ;;
    __commands) echo "commands" ;;
    __env) echo "env-reference" ;;
    *) echo "$1" ;;
  esac
}
for command_name in $json_commands use; do
  for schema_name in $(schema_for_command "$command_name"); do
    [ -f "${schema_dir}/${schema_name}.schema.json" ] || fail "gos ${command_name} --json has no schema docs/schema/${schema_name}.schema.json"
  done
done
[ -f "${schema_dir}/error.schema.json" ] || fail "the error document schema is missing"
for schema_file in "${schema_dir}"/*.schema.json; do
  schema_name=$(basename "$schema_file")
  grep -Fq "](${schema_name})" "${schema_dir}/README.md" || fail "docs/schema/README.md does not list ${schema_name}"
done
pass "every JSON command has a schema and the index lists every schema"

if ! command -v python3 >/dev/null 2>&1; then
  pass "schema validation skipped (python3 unavailable)"
  exit 0
fi

validator="${test_root}/validate.py"
cat >"$validator" <<'PY'
import json, re, sys

def kind_ok(value, kind):
    return {
        "null": value is None,
        "boolean": isinstance(value, bool),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "string": isinstance(value, str),
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
    }[kind]

def check(value, schema, path, errors):
    kinds = schema.get("type")
    if kinds is not None:
        kinds = kinds if isinstance(kinds, list) else [kinds]
        if not any(kind_ok(value, k) for k in kinds):
            errors.append(f"{path}: expected {kinds}, got {json.dumps(value)[:80]}")
            return
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {json.dumps(value)} not in {schema['enum']}")
    if "pattern" in schema and isinstance(value, str) and not re.search(schema["pattern"], value):
        errors.append(f"{path}: {json.dumps(value)} does not match {schema['pattern']}")
    if "minimum" in schema and isinstance(value, (int, float)) and not isinstance(value, bool) and value < schema["minimum"]:
        errors.append(f"{path}: {value} below minimum {schema['minimum']}")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key, item in value.items():
            if key in props:
                check(item, props[key], f"{path}.{key}", errors)
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}: unexpected field {key}")
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required field {key}")
    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            check(item, schema["items"], f"{path}[{index}]", errors)

schema = json.load(open(sys.argv[1]))
document = json.loads(sys.stdin.read())
errors = []
check(document, schema, "$", errors)
for error in errors:
    print(error)
sys.exit(1 if errors else 0)
PY

validated=""
assert_schema() {
  local schema_name="$1" document="$2" label="$3" report
  [ "$(printf '%s\n' "$document" | grep -c .)" -eq 1 ] || fail "${label}: expected exactly one JSON line: ${document}"
  if ! report=$(printf '%s\n' "$document" | python3 "$validator" "${schema_dir}/${schema_name}.schema.json" 2>&1); then
    fail "${label}: does not validate against ${schema_name}.schema.json: ${report}. Document: ${document}"
  fi
  validated="${validated} ${schema_name}"
}
# JSON goes to stdout alone; stderr (progress, errors) is kept apart.
run_json() {
  GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" "$@"
}

case_dir="${test_root}/schemas"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install before schema validation failed: ${output}"

run_json check --json
[ "$status" -eq 0 ] || fail "check --json failed: ${output} $(cat "${case_dir}/stderr")"
assert_schema check "$output" "check"
run_json current --json
assert_schema current "$output" "current (found)"
GOS_TEST_GO_BROKEN=1 run_json current --json
assert_schema current "$output" "current (not found)"
run_json list --json
assert_schema list "$output" "list"
run_json list --minor --json
assert_schema list "$output" "list --minor"
run_json list --installed --json
assert_schema list-installed "$output" "list --installed"
run_json platforms --json
assert_schema platforms "$output" "platforms"
run_json status --json
assert_schema status "$output" "status (flat)"
run_json which --json
assert_schema which "$output" "which"
run_json verify --json
[ "$status" -eq 0 ] || fail "verify --json failed: ${output} $(cat "${case_dir}/stderr")"
assert_schema verify "$output" "verify"
printf 'tampered\n' >"${case_dir}/go/VERSION_MARKER"
run_json verify --json
assert_status 4 "$status" "verify --json tampered" "$output"
assert_schema verify "$output" "verify (modified)"
GOS_TEST_PARSERS=jq run_json self-verify --json
[ "$status" -eq 0 ] || fail "self-verify --json failed: ${output} $(cat "${case_dir}/stderr")"
assert_schema self-verify "$output" "self-verify"
run_json env --json
assert_schema env "$output" "env"
run_json doctor --json
assert_schema doctor "$output" "doctor"
run_json doctor --fix --json
assert_schema doctor "$output" "doctor --fix"
HTTPS_PROXY="http://proxy.corp.test:3128" run_json doctor --json
assert_schema doctor "$output" "doctor (proxy)"
run_json prune --dry-run --json
assert_schema prune "$output" "prune --dry-run"
run_json prune --rollback --json
assert_schema prune "$output" "prune --rollback"
run_json version --json
assert_schema version "$output" "version"
run_json __commands --json
assert_schema commands "$output" "__commands"
run_json __env --json
assert_schema env-reference "$output" "__env"
pass "flat-layout JSON outputs validate against their schemas"

# Side-by-side plus a project file exercise the nullable objects of status.
project_dir="${case_dir}/project"
mkdir -p "$project_dir"
printf '1.21\n' >"${project_dir}/.go-version"
versions_case="${test_root}/schemas-versions"
GOS_TEST_VERSIONS_DIR="${versions_case}/versions" run_gos "$versions_case" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "side-by-side install before schema validation failed: ${output}"
cd "$project_dir"
case_dir="$versions_case"
GOS_TEST_VERSIONS_DIR="${versions_case}/versions" run_json status --json
assert_schema status "$output" "status (side-by-side, project)"
assert_contains "$output" '"layout":"side-by-side"' "status side-by-side layout"
assert_contains "$output" '"project":{"version":"go1.21"' "status project object"
GOS_TEST_VERSIONS_DIR="${versions_case}/versions" run_json use --print --json
assert_schema use-print "$output" "use --print"
GOS_TEST_VERSIONS_DIR="${versions_case}/versions" run_json which 1.21.6 --json
assert_schema which "$output" "which <version>"
GOS_TEST_VERSIONS_DIR="${versions_case}/versions" run_json list --installed --minor --json
assert_schema list-installed "$output" "list --installed --minor"
cd "$repo_root"
mkdir -p "${versions_case}/go.gos-lock"
printf '%s\n' "$$" >"${versions_case}/go.gos-lock/pid"
case_dir="$versions_case"
GOS_TEST_VERSIONS_DIR="${versions_case}/versions" run_json status --json
assert_schema status "$output" "status (lock held)"
assert_contains "$output" '"lock":{"state":"held"' "status lock object"
rm -rf "${versions_case}/go.gos-lock"
pass "side-by-side, project, and lock variants of status validate"

# Error documents, one per class.
case_dir="${test_root}/schemas"
run_json which --bogus --json
assert_status 2 "$status" "usage error document" "$output"
assert_schema error "$output" "error (usage)"
GOS_TEST_DOWNLOAD_MODE=fail-all run_json --json check
assert_status 3 "$status" "network error document" "$output"
assert_schema error "$output" "error (network)"
GOS_TEST_PARSERS=none run_json verify --json
assert_status 4 "$status" "verification error document" "$output"
assert_schema error "$output" "error (verification)"
# No JSON-capable command takes the mutation lock, so the lock class only
# reaches stdout as text; the enum keeps it for completeness.
pass "error documents validate for the usage, network, and verification classes"

# The validator itself must reject drift, or the suite proves nothing.
if printf '{"gos_version":"1.0.0","extra":true}\n' | python3 "$validator" "${schema_dir}/version.schema.json" >/dev/null 2>&1; then
  fail "the schema validator accepted an undeclared field"
fi
if printf '{"found":true}\n' | python3 "$validator" "${schema_dir}/current.schema.json" >/dev/null 2>&1; then
  fail "the schema validator accepted a document missing required fields"
fi
if printf '{"error":{"code":"weird","message":"x"}}\n' | python3 "$validator" "${schema_dir}/error.schema.json" >/dev/null 2>&1; then
  fail "the schema validator accepted a value outside the enum"
fi
for schema_file in "${schema_dir}"/*.schema.json; do
  schema_name=$(basename "$schema_file" .schema.json)
  case " ${validated} " in
    *" ${schema_name} "*) ;;
    *) fail "schema ${schema_name} was never exercised by this suite" ;;
  esac
done
pass "the validator rejects drift and every schema was exercised"
