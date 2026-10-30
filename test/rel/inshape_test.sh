#!/bin/sh
set -eu

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

version=$(sed -n 's/^ARG INSHAPE_VERSION=\(.*\)$/\1/p' Dockerfile)
amd64_sha=$(sed -n 's/^ARG INSHAPE_SHA256_AMD64=\(.*\)$/\1/p' Dockerfile)
arm64_sha=$(sed -n 's/^ARG INSHAPE_SHA256_ARM64=\(.*\)$/\1/p' Dockerfile)
[ -n "$version" ] && [ -n "$amd64_sha" ] && [ -n "$arm64_sha" ] ||
  fail "the Dockerfile does not pin INSHAPE_VERSION and both sha256s"

grep -qxF 'CMD ["/app/bin/migrate_and_start"]' Dockerfile ||
  fail "the image must start /app/bin/migrate_and_start directly"
grep -qxF 'COPY rel/secrets.allow /etc/wallop/secrets.allow' Dockerfile ||
  fail "the Dockerfile does not copy the allowlist to /etc/wallop/secrets.allow"
grep -qxF 'COPY --from=inshape /usr/local/bin/inshape /usr/local/bin/inshape' Dockerfile ||
  fail "the Dockerfile does not install inshape at /usr/local/bin/inshape"

grep -qxF '    start: "/usr/local/bin/inshape --allowlist /etc/wallop/secrets.allow -- /app/bin/migrate_and_start",' .railway/railway.ts ||
  fail ".railway/railway.ts does not start the release through inshape"
[ ! -e railway.toml ] || fail "railway.toml is replaced by .railway/railway.ts"

expected="EDGE_SHARED_SECRET
HONEYCOMB_API_KEY
MET_OFFICE_OBS_API_KEY
SECRET_KEY_BASE
VAULT_KEY
VAULT_KEY_OLD"
[ "$(sort rel/secrets.allow)" = "$expected" ] || fail "rel/secrets.allow does not hold exactly the six secret names"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/inshape" \
  "https://github.com/electric-lump-software/inshape/releases/download/v${version}/inshape-x86_64-unknown-linux-musl"
echo "${amd64_sha}  $work/inshape" | sha256sum -c - >/dev/null || fail "the x86_64 binary does not match its sha256"

if [ "$(uname -s)" != Linux ]; then
  echo "ok: inshape $version pinned (sha256 checked); run on Linux to execute it"
  exit 0
fi

chmod 0755 "$work/inshape"
status=0
env -u INFISICAL_UNIVERSAL_AUTH_CLIENT_ID -u INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET \
  -u INFISICAL_PROJECT_ID -u INFISICAL_ENV \
  "$work/inshape" --allowlist rel/secrets.allow -- true 2>"$work/err" || status=$?
if [ "$status" -ne 64 ] || ! grep -q "Infisical is not configured" "$work/err"; then
  cat "$work/err" >&2
  fail "inshape $version did not accept rel/secrets.allow (exit $status)"
fi

echo "ok: inshape $version (sha256 checked) accepts rel/secrets.allow"
