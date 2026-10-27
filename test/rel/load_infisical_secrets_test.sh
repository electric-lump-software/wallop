#!/bin/sh
# Checks the start script's Infisical loader against a stub CLI.
set -u

for name in $(env | sed -n 's/^\(INFISICAL_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$name"; done

loader=${1:-rel/overlays/bin/load_infisical_secrets}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

cp "$loader" "$work/load_infisical_secrets"

cat > "$work/start" <<'SCRIPT'
#!/bin/sh
set -eu
. "$(dirname "$0")/load_infisical_secrets"
echo "VAULT_KEY=${VAULT_KEY:-unset}"
echo "TOKEN=${INFISICAL_TOKEN:-unset}"
echo "CLIENT_SECRET=${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET:-unset}"
SCRIPT
chmod +x "$work/start"

# The stub records each command in $STUB_CALLS, the full `run` arguments in
# $STUB_RUN_ARGS and each `export`'s in $STUB_EXPORT_ARGS. An `export` or
# `run` naming $STUB_MISSING_PATH exits non-zero, as the CLI does for a
# folder it can't read. `export` lists a clean set of names for every
# folder, plus STUB_NAMES (and STUB_SPACED_NAMES, as indented JSON) for the
# folder STUB_NAMES_PATH, default "/".
mkdir "$work/bin"
cat > "$work/bin/infisical" <<'STUB'
#!/bin/sh
echo "$1" >> "$STUB_CALLS"
case "$1" in
  login)
    grep -q run "$STUB_CALLS" 2>/dev/null && exit 8
    [ "${STUB_LOGIN_FAILS:-}" = "1" ] && exit 1
    [ "${STUB_LOGIN_EMPTY:-}" = "1" ] && exit 0
    echo "stub-token" ;;
  export)
    echo "$*" >> "$STUB_EXPORT_ARGS"
    [ "${INFISICAL_TOKEN:-}" = "stub-token" ] || { echo "export without token" >&2; exit 9; }
    for arg in "$@"; do
      case "$arg" in --path=*) path=${arg#--path=} ;; esac
    done
    [ -n "${STUB_MISSING_PATH:-}" ] && [ "$path" = "$STUB_MISSING_PATH" ] && {
      echo "failed to fetch secrets for path" >&2; exit 1; }
    names="VAULT_KEY INFISICAL_CANARY_SHARED LDAP_URL PORTAL_KEY HOMEPAGE_URL MY_PATH ld_preload"
    spaced=""
    if [ "$path" = "${STUB_NAMES_PATH:-/}" ]; then
      names="$names ${STUB_NAMES:-}"
      spaced=${STUB_SPACED_NAMES:-}
    fi
    printf '[{"key":"NOTE","value":"stub-value \\"key\\":\\"LD_PRELOAD\\""}'
    for name in $names; do
      printf ',{"key":"%s","value":"stub-value-%s","type":"shared","secretPath":"%s"}' "$name" "$name" "$path"
    done
    for name in $spaced; do
      printf ',\n  {\n    "key" : "%s",\n    "value" : "stub-value-%s"\n  }' "$name" "$name"
    done
    printf ']\n' ;;
  run)
    echo "$*" > "$STUB_RUN_ARGS"
    [ "${INFISICAL_TOKEN:-}" = "stub-token" ] || { echo "run without token" >&2; exit 9; }
    for arg in "$@"; do
      [ -n "${STUB_MISSING_PATH:-}" ] && [ "$arg" = "--path=$STUB_MISSING_PATH" ] && {
        echo "failed to fetch secrets for path" >&2; exit 1; }
    done
    while [ "$1" != "--" ]; do shift; done
    shift
    VAULT_KEY=from-infisical INFISICAL_CANARY_SHARED=canary-value-shared \
      INFISICAL_CANARY_CORE=canary-value-core exec "$@" ;;
esac
STUB
chmod +x "$work/bin/infisical"

all_four="INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=id INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=secret INFISICAL_PROJECT_ID=project INFISICAL_ENV=prod"

run_start() {
  rm -f "$work/calls" "$work/run_args" "$work/export_args"
  STUB_CALLS="$work/calls" STUB_RUN_ARGS="$work/run_args" STUB_EXPORT_ARGS="$work/export_args" \
    PATH="$work/bin:$PATH" VAULT_KEY=from-platform env "$@" "$work/start" > "$work/out" 2> "$work/err"
}

check() {
  if eval "$2"; then echo "ok - $1"; else echo "FAIL - $1"; failures=$((failures + 1)); fi
}

run_start
status=$?
check "nothing configured starts as before, without calling Infisical" \
  '[ $status -eq 0 ] && grep -q "VAULT_KEY=from-platform" "$work/out" && [ ! -e "$work/calls" ]'

# shellcheck disable=SC2086
run_start $all_four
status=$?
check "fully configured re-runs under Infisical, whose values win" \
  '[ $status -eq 0 ] && grep -q "VAULT_KEY=from-infisical" "$work/out" && [ "$(cat "$work/calls" | tr "\n" " ")" = "login export run " ]'
check "the app never sees the Infisical credentials" \
  'grep -q "TOKEN=unset" "$work/out" && grep -q "CLIENT_SECRET=unset" "$work/out"'
check "without INFISICAL_PATHS it reads the root folder only" \
  '[ "$(grep -o -- "--path=[^ ]*" "$work/run_args" | tr "\n" " ")" = "--path=/ " ]'
check "values are read literally, with --expand=false" \
  'grep -q -- "--expand=false" "$work/run_args"'
check "--watch is never passed" \
  '! grep -q -- "--watch" "$work/run_args"'
check "the restarted script logs the canary names it was given" \
  'grep -q "Canaries present: INFISICAL_CANARY_CORE INFISICAL_CANARY_SHARED" "$work/out"'
check "canary values are never logged" \
  '! grep -q "canary-value" "$work/out" "$work/err"'

# shellcheck disable=SC2086
run_start $all_four "INFISICAL_PATHS=/shared /core"
status=$?
check "two paths are each passed as their own --path, in order" \
  '[ $status -eq 0 ] && [ "$(grep -o -- "--path=[^ ]*" "$work/run_args" | tr "\n" " ")" = "--path=/shared --path=/core " ]'
check "the names in each folder are listed before the re-run" \
  '[ "$(tr "\n" " " < "$work/calls")" = "login export export run " ] && [ "$(grep -o -- "--path=[^ ]*" "$work/export_args" | tr "\n" " ")" = "--path=/shared --path=/core " ]'
check "names are listed from the same project and environment, as JSON, unexpanded, with telemetry off" \
  '[ "$(grep -c -- "--projectId project --env prod .*--format=json --expand=false --silent --telemetry=false" "$work/export_args")" -eq 2 ] && ! grep -q -- "--output-file" "$work/export_args"'
check "a clean set of names, a canary and a value mentioning a refused name all pass" \
  '[ $status -eq 0 ] && ! grep -q "must not come from Infisical" "$work/err"'

# shellcheck disable=SC2086
run_start $all_four STUB_MISSING_PATH=/core "INFISICAL_PATHS=/shared /core"
status=$?
check "a folder the CLI fails to read stops the start, before the re-run" \
  '[ $status -ne 0 ] && grep -q "Could not list the secrets in Infisical folder /core" "$work/err" && ! grep -q VAULT_KEY "$work/out" && ! grep -qx run "$work/calls"'

for name in PATH HOME SHELL ENV BASH_ENV IFS SHELLOPTS PS4 DATABASE_URL REDIS_URL PORT \
  ELIXIR_ERL_OPTIONS SSL_CERT_FILE SSL_CERT_DIR LD_PRELOAD DYLD_INSERT_LIBRARIES ERL_FLAGS \
  RELEASE_COOKIE MIX_ENV OTEL_EXPORTER_OTLP_ENDPOINT BEAM_PORT OPENSSL_CONF INFISICAL_TOKEN \
  INFISICAL_API_URL PGHOST PGPASSWORD GCONV_PATH GLIBC_TUNABLES HOSTALIASES RES_OPTIONS \
  HTTP_PROXY https_proxy All_Proxy no_proxy; do
  # shellcheck disable=SC2086
  run_start $all_four "INFISICAL_PATHS=/shared /core" STUB_NAMES_PATH=/core "STUB_NAMES=$name"
  status=$?
  check "$name in Infisical refuses to start, before the re-run" \
    '[ $status -ne 0 ] && grep -qx "Infisical folder /core holds names that must not come from Infisical: $name" "$work/err" && ! grep -q VAULT_KEY "$work/out" && ! grep -qx run "$work/calls" && ! grep -q "stub-value" "$work/out" "$work/err"'
done

# shellcheck disable=SC2086
run_start $all_four "INFISICAL_PATHS=/shared /core" STUB_NAMES_PATH=/shared "STUB_NAMES=PATH LD_PRELOAD" STUB_SPACED_NAMES=ERL_FLAGS
status=$?
check "every refused name in a folder is named on one line, from compact or indented JSON" \
  '[ $status -ne 0 ] && [ "$(grep -c "must not come from Infisical" "$work/err")" -eq 1 ] && grep -qx "Infisical folder /shared holds names that must not come from Infisical: ERL_FLAGS LD_PRELOAD PATH" "$work/err"'
check "secret values never appear in the output" \
  '! grep -q "stub-value" "$work/out" "$work/err"'

# shellcheck disable=SC2086
run_start $all_four STUB_NAMES=INFISICAL_CANARY_CORE
status=$?
check "an INFISICAL_CANARY_ name is allowed" \
  '[ $status -eq 0 ] && grep -q "VAULT_KEY=from-infisical" "$work/out" && [ ! -s "$work/err" ]'

run_start INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=id INFISICAL_PROJECT_ID=project
status=$?
check "partly configured refuses to start" \
  '[ $status -ne 0 ] && grep -q "only partly configured" "$work/err" && ! grep -q VAULT_KEY "$work/out" && [ ! -e "$work/calls" ]'

# shellcheck disable=SC2086
run_start STUB_LOGIN_FAILS=1 $all_four
status=$?
check "a failed Infisical sign-in refuses to start" \
  '[ $status -ne 0 ] && ! grep -q VAULT_KEY "$work/out"'

# shellcheck disable=SC2086
run_start STUB_LOGIN_EMPTY=1 $all_four
status=$?
check "an empty Infisical token refuses to start, before fetching secrets" \
  '[ $status -ne 0 ] && grep -q "returned no token" "$work/err" && [ "$(cat "$work/calls")" = "login" ]'

# shellcheck disable=SC2086
run_start INFISICAL_SECRETS_LOADED=1 $all_four
status=$?
check "INFISICAL_SECRETS_LOADED without a token refuses to start, without calling Infisical" \
  '[ $status -ne 0 ] && grep -q "did not come from Infisical" "$work/err" && ! grep -q VAULT_KEY "$work/out" && [ ! -e "$work/calls" ]'

run_start INFISICAL_SECRETS_LOADED=1
status=$?
check "INFISICAL_SECRETS_LOADED alone refuses to start" \
  '[ $status -ne 0 ] && grep -q "did not come from Infisical" "$work/err" && ! grep -q VAULT_KEY "$work/out"'

[ "$failures" -eq 0 ]
