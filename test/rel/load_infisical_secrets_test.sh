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
echo "DATABASE_URL=${DATABASE_URL:-unset}"
echo "TOKEN=${INFISICAL_TOKEN:-unset}"
echo "CLIENT_SECRET=${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET:-unset}"
SCRIPT
chmod +x "$work/start"

# The stub records each command in $STUB_CALLS and the full `run` arguments
# in $STUB_RUN_ARGS. A `run` naming $STUB_MISSING_PATH exits non-zero, as
# the CLI does for a folder it can't read.
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
  run)
    echo "$*" > "$STUB_RUN_ARGS"
    [ "${INFISICAL_TOKEN:-}" = "stub-token" ] || { echo "run without token" >&2; exit 9; }
    for arg in "$@"; do
      [ -n "${STUB_MISSING_PATH:-}" ] && [ "$arg" = "--path=$STUB_MISSING_PATH" ] && {
        echo "failed to fetch secrets for path" >&2; exit 1; }
    done
    while [ "$1" != "--" ]; do shift; done
    shift
    DATABASE_URL=from-infisical INFISICAL_CANARY_SHARED=canary-value-shared \
      INFISICAL_CANARY_CORE=canary-value-core exec "$@" ;;
esac
STUB
chmod +x "$work/bin/infisical"

all_four="INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=id INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=secret INFISICAL_PROJECT_ID=project INFISICAL_ENV=prod"

run_start() {
  rm -f "$work/calls" "$work/run_args"
  STUB_CALLS="$work/calls" STUB_RUN_ARGS="$work/run_args" PATH="$work/bin:$PATH" \
    DATABASE_URL=from-platform env "$@" "$work/start" > "$work/out" 2> "$work/err"
}

check() {
  if eval "$2"; then echo "ok - $1"; else echo "FAIL - $1"; failures=$((failures + 1)); fi
}

run_start
status=$?
check "nothing configured starts as before, without calling Infisical" \
  '[ $status -eq 0 ] && grep -q "DATABASE_URL=from-platform" "$work/out" && [ ! -e "$work/calls" ]'

# shellcheck disable=SC2086
run_start $all_four
status=$?
check "fully configured re-runs under Infisical, whose values win" \
  '[ $status -eq 0 ] && grep -q "DATABASE_URL=from-infisical" "$work/out" && [ "$(cat "$work/calls" | tr "\n" " ")" = "login run " ]'
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

# shellcheck disable=SC2086
run_start $all_four STUB_MISSING_PATH=/core "INFISICAL_PATHS=/shared /core"
status=$?
check "a folder the CLI fails to read stops the start" \
  '[ $status -ne 0 ] && ! grep -q DATABASE_URL "$work/out"'

run_start INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=id INFISICAL_PROJECT_ID=project
status=$?
check "partly configured refuses to start" \
  '[ $status -ne 0 ] && grep -q "only partly configured" "$work/err" && ! grep -q DATABASE_URL "$work/out" && [ ! -e "$work/calls" ]'

# shellcheck disable=SC2086
run_start STUB_LOGIN_FAILS=1 $all_four
status=$?
check "a failed Infisical sign-in refuses to start" \
  '[ $status -ne 0 ] && ! grep -q DATABASE_URL "$work/out"'

# shellcheck disable=SC2086
run_start STUB_LOGIN_EMPTY=1 $all_four
status=$?
check "an empty Infisical token refuses to start, before fetching secrets" \
  '[ $status -ne 0 ] && grep -q "returned no token" "$work/err" && [ "$(cat "$work/calls")" = "login" ]'

# shellcheck disable=SC2086
run_start INFISICAL_SECRETS_LOADED=1 $all_four
status=$?
check "INFISICAL_SECRETS_LOADED without a token refuses to start, without calling Infisical" \
  '[ $status -ne 0 ] && grep -q "did not come from Infisical" "$work/err" && ! grep -q DATABASE_URL "$work/out" && [ ! -e "$work/calls" ]'

run_start INFISICAL_SECRETS_LOADED=1
status=$?
check "INFISICAL_SECRETS_LOADED alone refuses to start" \
  '[ $status -ne 0 ] && grep -q "did not come from Infisical" "$work/err" && ! grep -q DATABASE_URL "$work/out"'

[ "$failures" -eq 0 ]
