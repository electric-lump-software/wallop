#!/bin/sh
# Checks the start script's Infisical loader against a stub CLI.
set -u

for name in $(env | sed -n 's/^\(INFISICAL_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$name"; done

loader=${1:-rel/overlays/bin/load_infisical_secrets}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

allowed="VAULT_KEY VAULT_KEY_OLD SECRET_KEY_BASE EDGE_SHARED_SECRET HONEYCOMB_API_KEY MET_OFFICE_OBS_API_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY"

cp "$loader" "$work/load_infisical_secrets"

cat > "$work/start" <<'SCRIPT'
#!/bin/sh
set -eu
. "$(dirname "$0")/load_infisical_secrets"
echo "VAULT_KEY=${VAULT_KEY:-unset}"
echo "TOKEN=${INFISICAL_TOKEN:-unset}"
echo "CLIENT_SECRET=${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET:-unset}"
echo "ARGS=$*"
SCRIPT
chmod +x "$work/start"

# The stub records each subcommand in $STUB_CALLS and the full argument list
# of `run` in $STUB_RUN_ARGS, and of each `export` in $STUB_EXPORT_ARGS. A
# --path listed in STUB_UNREADABLE_PATHS makes `export` and `run` exit
# non-zero, as the CLI does when a folder fetch fails. `export` lists a clean
# set of names for every folder, plus STUB_NAMES (and STUB_SPACED_NAMES, as
# indented JSON) for the folder STUB_NAMES_PATH, default "/", or prints
# STUB_RAW_EXPORT for that folder instead. `run` also sets STUB_RUN_EXTRA,
# a variable that `export` did not list.
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
    [ "${INFISICAL_TOKEN:-}" = "stub-token" ] || { echo "export without token" >&2; exit 9; }
    printf '%s\n' "$@" >> "$STUB_EXPORT_ARGS"
    for arg in "$@"; do
      case "$arg" in --path=*) path=${arg#--path=} ;; esac
    done
    for unreadable in ${STUB_UNREADABLE_PATHS:-}; do
      if [ "$path" = "$unreadable" ]; then
        echo "failed to fetch secrets for path \"$unreadable\"" >&2
        exit 1
      fi
    done
    names="VAULT_KEY INFISICAL_CANARY_SHARED SECRET_KEY_BASE"
    spaced=""
    if [ "$path" = "${STUB_NAMES_PATH:-/}" ]; then
      if [ -n "${STUB_RAW_EXPORT+set}" ]; then
        printf '%s\n' "$STUB_RAW_EXPORT"
        exit 0
      fi
      names="$names ${STUB_NAMES:-}"
      spaced=${STUB_SPACED_NAMES:-}
    fi
    printf '[{"key":"HONEYCOMB_API_KEY","value":"stub-value \\"key\\":\\"LD_PRELOAD\\",\\"value\\":1"}'
    for name in $names; do
      printf ',{"key":"%s","value":"stub-value-%s","type":"shared","secretPath":"%s"}' "$name" "$name" "$path"
    done
    for name in $spaced; do
      printf ',\n  {\n    "key" : "%s",\n    "value" : "stub-value-%s"\n  }' "$name" "$name"
    done
    printf ']\n' ;;
  run)
    [ "${INFISICAL_TOKEN:-}" = "stub-token" ] || { echo "run without token" >&2; exit 9; }
    printf '%s\n' "$@" > "$STUB_RUN_ARGS"
    while [ "$1" != "--" ]; do
      for unreadable in ${STUB_UNREADABLE_PATHS:-}; do
        if [ "$1" = "--path=$unreadable" ]; then
          echo "failed to fetch secrets for path \"$unreadable\"" >&2
          exit 1
        fi
      done
      shift
    done
    shift
    exec env VAULT_KEY=from-infisical INFISICAL_CANARY_SHARED=shared-test INFISICAL_CANARY_CORE=core-test \
      ${STUB_RUN_EXTRA:-} "$@" ;;
esac
STUB
chmod +x "$work/bin/infisical"

all_four="INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=id INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=secret INFISICAL_PROJECT_ID=project INFISICAL_ENV=prod"
project_flags="--projectId=project --env=prod --expand=false --silent --telemetry=false "

run_start() {
  rm -f "$work/calls" "$work/run_args" "$work/export_args"
  STUB_CALLS="$work/calls" STUB_RUN_ARGS="$work/run_args" STUB_EXPORT_ARGS="$work/export_args" \
    PATH="$work/bin:$PATH" VAULT_KEY=from-platform DATABASE_URL=from-platform \
    env "$@" "$work/start" > "$work/out" 2> "$work/err"
}

check() {
  if eval "$2"; then echo "ok - $1"; else echo "FAIL - $1"; failures=$((failures + 1)); fi
}

no_values() {
  ! grep -q -e "stub-value" -e "from-platform" -e "-test" -e "elsewhere" "$work/err"
}

refused() {
  [ $status -ne 0 ] && ! grep -q VAULT_KEY "$work/out" && ! grep -qx run "$work/calls" && no_values
}

project_flags_in() {
  [ "$(grep -x -e "--projectId=project" -e "--env=prod" -e "--expand=false" -e "--silent" -e "--telemetry=false" "$1" | tr "\n" " ")" = "$project_flags" ]
}

run_start
status=$?
check "nothing configured starts as before, without calling Infisical" \
  '[ $status -eq 0 ] && grep -q "VAULT_KEY=from-platform" "$work/out" && [ ! -e "$work/calls" ]'

# shellcheck disable=SC2086
run_start $all_four
status=$?
check "fully configured re-runs under Infisical, whose values win" \
  '[ $status -eq 0 ] && grep -q "VAULT_KEY=from-infisical" "$work/out" && [ "$(tr "\n" " " < "$work/calls")" = "login export run " ]'
check "the start script never sees the Infisical credentials" \
  'grep -q "TOKEN=unset" "$work/out" && grep -q "CLIENT_SECRET=unset" "$work/out"'
check "the digest travels as an argument and the start script never sees it" \
  'grep -qx "ARGS=" "$work/out" && grep -q -- "^--infisical-env-digest=[0-9a-f]\{64\}$" "$work/run_args"'
check "with no INFISICAL_PATHS, only the root folder is read" \
  '[ "$(grep -c -- "^--path=" "$work/run_args")" -eq 1 ] && grep -qx -- "--path=/" "$work/run_args"'
check "secret references are not expanded" \
  'grep -qx -- "--expand=false" "$work/run_args"'
check "secrets are never watched for changes" \
  '! grep -q -- "--watch" "$work/run_args"'
check "the names of the canaries present are logged, never their values" \
  'grep -qx "Secrets loaded from Infisical. Canaries present: INFISICAL_CANARY_CORE INFISICAL_CANARY_SHARED " "$work/out" && ! grep -q -- "-test" "$work/out"'
check "names and secrets are fetched with the same project flags" \
  'project_flags_in "$work/export_args" && project_flags_in "$work/run_args"'
check "names are listed as JSON on stdout, never to a file" \
  'grep -qx -- "--format=json" "$work/export_args" && ! grep -q -- "--output-file" "$work/export_args"'

# shellcheck disable=SC2086
run_start $all_four "INFISICAL_PATHS=/shared /core"
status=$?
check "each folder in INFISICAL_PATHS is passed as its own --path" \
  '[ $status -eq 0 ] && grep -q "VAULT_KEY=from-infisical" "$work/out" && [ "$(grep -- "^--path=" "$work/run_args" | tr "\n" " ")" = "--path=/shared --path=/core " ]'
check "the names in each folder are listed before the re-run" \
  '[ "$(tr "\n" " " < "$work/calls")" = "login export export run " ] && [ "$(grep -- "^--path=" "$work/export_args" | tr "\n" " ")" = "--path=/shared --path=/core " ]'

# shellcheck disable=SC2086
run_start $all_four "STUB_NAMES=$allowed INFISICAL_CANARY_CORE" STUB_SPACED_NAMES=EDGE_SHARED_SECRET
status=$?
check "every allowed name, a canary and a value quoting a refused name pass" \
  '[ $status -eq 0 ] && grep -q "VAULT_KEY=from-infisical" "$work/out" && [ ! -s "$work/err" ]'

for raw in "[]" "null" ""; do
  # shellcheck disable=SC2086
  run_start $all_four "STUB_RAW_EXPORT=$raw"
  status=$?
  check "an empty folder ('$raw') refuses to start, as a folder the identity may not read" \
    'refused && grep -qxF "Infisical folder / returned no secrets; check the folder, environment and the identity'"'"'s role." "$work/err"'
done

# shellcheck disable=SC2086
run_start $all_four "INFISICAL_PATHS=/shared /core" STUB_NAMES_PATH=/core "STUB_RAW_EXPORT=[]"
status=$?
check "one empty folder among several refuses to start, naming that folder" \
  'refused && grep -q "Infisical folder /core returned no secrets" "$work/err" && ! grep -q "folder /shared" "$work/err"'

# shellcheck disable=SC2086
run_start $all_four "INFISICAL_PATHS=/*"
status=$?
check "a folder name is passed as written, never expanded as a filename pattern" \
  '[ $status -eq 0 ] && [ "$(grep -- "^--path=" "$work/run_args" | tr "\n" " ")" = "--path=/* " ]'

# shellcheck disable=SC2086
run_start $all_four "INFISICAL_PATHS=/shared /core" STUB_UNREADABLE_PATHS=/core
status=$?
check "a folder that is missing or forbidden refuses to start, before the re-run" \
  'refused && grep -q "failed to fetch secrets" "$work/err" && grep -q "Could not list the secrets in Infisical folder /core" "$work/err"'

for name in PATH HOME SHELL ENV BASH_ENV IFS PS4 DATABASE_URL REDIS_URL PORT \
  ELIXIR_ERL_OPTIONS SSL_CERT_FILE LD_PRELOAD DYLD_INSERT_LIBRARIES ERL_FLAGS \
  RELEASE_COOKIE MIX_ENV OTEL_EXPORTER_OTLP_ENDPOINT BEAM_PORT OPENSSL_CONF INFISICAL_TOKEN \
  INFISICAL_API_URL PGHOST GCONV_PATH HTTP_PROXY https_proxy \
  PHX_HOST POOL_SIZE AWS_REGION AWS_S3_BUCKET_NAME RAILWAY_ENVIRONMENT_NAME STRIPE_SECRET_KEY \
  vault_key Vault_Key 1VAULT_KEY VAULT-KEY "LD_PRELOAD=x" "VAULT_KÉY" "INFISICAL_CANARY_x"; do
  # shellcheck disable=SC2086
  run_start $all_four "INFISICAL_PATHS=/shared /core" STUB_NAMES_PATH=/core "STUB_NAMES=$name"
  status=$?
  check "$name in Infisical refuses to start, before the re-run" \
    'refused && grep -qxF "Infisical folder /core holds names that must stay host variables or be removed: $name" "$work/err"'
done

# shellcheck disable=SC2086
run_start $all_four 'STUB_NAMES=A\"B'
status=$?
check "an escaped quote in a name refuses to start" \
  'refused && grep -qxF "Infisical folder / holds names that must stay host variables or be removed: A\\" "$work/err"'

# shellcheck disable=SC2086
run_start $all_four "INFISICAL_PATHS=/shared /core" STUB_NAMES_PATH=/shared "STUB_NAMES=PATH LD_PRELOAD" STUB_SPACED_NAMES=ERL_FLAGS
status=$?
check "every refused name in a folder is named on one line, from compact or indented JSON" \
  'refused && [ "$(grep -c "must stay host variables" "$work/err")" -eq 1 ] && grep -qx "Infisical folder /shared holds names that must stay host variables or be removed: ERL_FLAGS LD_PRELOAD PATH" "$work/err"'

for raw in '{"PATH":"x"}' '[{"Key":"PATH","Value":"x"}]' '[{"key":"VAULT_KEY"}]' '[{"key":null,"value":"x"},{"key":"VAULT_KEY","value":"x"}]'; do
  # shellcheck disable=SC2086
  run_start $all_four "STUB_RAW_EXPORT=$raw"
  status=$?
  check "an export shaped like $raw refuses to start" \
    'refused && grep -qxF "Could not read the secret names in Infisical folder / from the CLI'"'"'s output." "$work/err"'
done

# shellcheck disable=SC2086
run_start $all_four STUB_RUN_EXTRA=ERL_FLAGS=-x
status=$?
check "a refused name that appears between listing and loading refuses to start" \
  '[ $status -ne 0 ] && grep -q "changed between listing the secret names and loading them" "$work/err" && ! grep -q VAULT_KEY "$work/out" && no_values'

# shellcheck disable=SC2086
run_start $all_four STUB_RUN_EXTRA=DATABASE_URL=elsewhere
status=$?
check "a host variable changed between listing and loading refuses to start" \
  '[ $status -ne 0 ] && grep -q "changed between listing" "$work/err" && ! grep -q VAULT_KEY "$work/out" && no_values'

# shellcheck disable=SC2086
run_start $all_four STUB_RUN_EXTRA=AWS_ACCESS_KEY_ID=added
status=$?
check "an allowed name that appears between listing and loading is accepted" \
  '[ $status -eq 0 ] && grep -q "VAULT_KEY=from-infisical" "$work/out" && [ ! -s "$work/err" ]'

# shellcheck disable=SC2086
run_start INFISICAL_SECRETS_LOADED=1 INFISICAL_TOKEN=stub-token $all_four
status=$?
check "a sentinel and token without the digest argument refuse to start" \
  '[ $status -ne 0 ] && grep -q "not re-run by this loader" "$work/err" && ! grep -q VAULT_KEY "$work/out" && [ ! -e "$work/calls" ]'

mkdir "$work/broken_awk"
printf '#!/bin/sh\nexit 1\n' > "$work/broken_awk/awk"
chmod +x "$work/broken_awk/awk"

# shellcheck disable=SC2086
run_start $all_four "PATH=$work/broken_awk:$work/bin:$PATH"
status=$?
check "an awk that fails refuses to start, rather than compare two empty digests" \
  'refused && grep -q "Could not take a digest of the environment" "$work/err"'

(
  cd "$work" || exit 1
  PATH="$work/broken_awk:$PATH" INFISICAL_SECRETS_LOADED=1 INFISICAL_TOKEN=stub-token \
    ./start --infisical-env-digest=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 \
    > "$work/out" 2> "$work/err"
)
status=$?
check "the re-run refuses the digest of an empty environment listing" \
  '[ $status -ne 0 ] && grep -q "Could not take a digest of the environment" "$work/err" && ! grep -q VAULT_KEY "$work/out"'

run_start INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=id INFISICAL_PROJECT_ID=project
status=$?
check "partly configured refuses to start" \
  '[ $status -ne 0 ] && grep -q "only partly configured" "$work/err" && ! grep -q VAULT_KEY "$work/out" && [ ! -e "$work/calls" ]'

# shellcheck disable=SC2086
run_start STUB_LOGIN_FAILS=1 $all_four
status=$?
check "a failed Infisical sign-in refuses to start, before fetching secrets" \
  '[ $status -ne 0 ] && ! grep -q VAULT_KEY "$work/out" && [ "$(cat "$work/calls")" = "login" ]'

# shellcheck disable=SC2086
run_start STUB_LOGIN_EMPTY=1 $all_four
status=$?
check "an empty Infisical token refuses to start, before fetching secrets" \
  '[ $status -ne 0 ] && grep -q "returned no token" "$work/err" && [ "$(cat "$work/calls")" = "login" ]'

# shellcheck disable=SC2086
run_start INFISICAL_SECRETS_LOADED=1 $all_four
status=$?
check "a sentinel set without a token refuses to start, rather than skip Infisical" \
  '[ $status -ne 0 ] && grep -q "did not come from Infisical" "$work/err" && ! grep -q VAULT_KEY "$work/out" && [ ! -e "$work/calls" ]'

run_start INFISICAL_SECRETS_LOADED=1
status=$?
check "a sentinel set on its own refuses to start" \
  '[ $status -ne 0 ] && grep -q "did not come from Infisical" "$work/err" && ! grep -q VAULT_KEY "$work/out"'

[ "$failures" -eq 0 ]
