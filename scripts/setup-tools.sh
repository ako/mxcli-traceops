#!/usr/bin/env bash
#
# setup-tools.sh — re-establish the Mendix/mxcli toolchain in an ephemeral container.
#
# This container is recycled. Nothing under /opt, ~/.mxcli, or /usr/local/bin
# survives, so this script is the single source of truth for the toolchain and is
# expected to run on every session start (see .claude/settings.json).
#
# It is idempotent and detect-then-install: each step checks for a good existing
# artifact and skips the expensive work if it finds one. A warm re-run is seconds;
# a cold run is a few minutes (clone + go build + ~1.2 GB of Mendix downloads).
#
# Override the targeted Mendix version with MENDIX_VERSION=x.y.z.
#
set -euo pipefail

MENDIX_VERSION="${MENDIX_VERSION:-11.12.1}"
ANTLR_VERSION="4.13.1"
ANTLR_JAR="/opt/antlr/antlr-${ANTLR_VERSION}-complete.jar"
ANTLR_URL="https://www.antlr.org/download/antlr-${ANTLR_VERSION}-complete.jar"
ANTLR_SHIM="/usr/local/bin/antlr4"
MXCLI_REPO="https://github.com/ako/mxcli.git"
MXCLI_SRC="/opt/mxcli-src"
MXCLI_BIN="/usr/local/bin/mxcli"
MXCLI_STAMP="/opt/mxcli-src/.installed-sha"
MXCLI_CACHE="${HOME}/.mxcli"

log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
skip() { printf '\033[1;32m[skip ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL ]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Base image — detect only, never install. These ship with the image.
# ---------------------------------------------------------------------------
PG_BINDIR="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)"
CHROMIUM="${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}/chromium"

# ---------------------------------------------------------------------------
# 1. ANTLR 4.13.1 — mxcli's grammar build shells out to an `antlr4` command.
#    The generated parser must match the antlr4-go runtime pinned in go.mod
#    (v4.13.1); a different generator version is not supported here.
# ---------------------------------------------------------------------------
if [ -s "$ANTLR_JAR" ]; then
  skip "ANTLR ${ANTLR_VERSION} jar already present"
else
  log "downloading ANTLR ${ANTLR_VERSION} jar"
  mkdir -p "$(dirname "$ANTLR_JAR")"
  curl -fsSL --retry 3 --retry-delay 2 -o "${ANTLR_JAR}.tmp" "$ANTLR_URL" \
    || die "could not download ANTLR from ${ANTLR_URL}"
  mv "${ANTLR_JAR}.tmp" "$ANTLR_JAR"
fi

# The shim is tiny; rewrite only when the content would actually change.
read -r -d '' SHIM_BODY <<EOF || true
#!/bin/sh
exec java -jar ${ANTLR_JAR} "\$@"
EOF
if [ -f "$ANTLR_SHIM" ] && [ "$(cat "$ANTLR_SHIM")" = "$SHIM_BODY" ]; then
  skip "antlr4 shim already current"
else
  log "installing antlr4 shim at ${ANTLR_SHIM}"
  printf '%s\n' "$SHIM_BODY" > "$ANTLR_SHIM"
  chmod 755 "$ANTLR_SHIM"
fi

# ---------------------------------------------------------------------------
# 2. mxcli — built from source at main.
#    Rebuild only when the installed binary does not match the current main HEAD.
#    Note: plain `go build` is NOT enough. The Makefile's `build` target also
#    generates the ANTLR parser (mdl/grammar/parser/ is not committed) and syncs
#    the go:embed payloads (skills/, commands/, lint-rules/, changelog.md), all
#    of which are gitignored. `go build` alone fails on the missing embeds.
# ---------------------------------------------------------------------------
export GOTOOLCHAIN=auto   # go.mod asks for a newer toolchain than the image's go

log "resolving ${MXCLI_REPO} main HEAD"
REMOTE_SHA="$(git ls-remote "$MXCLI_REPO" refs/heads/main 2>/dev/null | cut -f1)"
[ -n "$REMOTE_SHA" ] || die "could not resolve main HEAD for ${MXCLI_REPO}"

INSTALLED_SHA="$( [ -f "$MXCLI_STAMP" ] && cat "$MXCLI_STAMP" || echo "" )"

if [ -x "$MXCLI_BIN" ] && [ "$INSTALLED_SHA" = "$REMOTE_SHA" ]; then
  skip "mxcli already built from main HEAD ${REMOTE_SHA:0:12}"
else
  if [ -d "$MXCLI_SRC/.git" ]; then
    log "updating mxcli clone"
    git -C "$MXCLI_SRC" fetch --quiet origin main
    git -C "$MXCLI_SRC" checkout --quiet --force FETCH_HEAD
  else
    log "cloning mxcli"
    rm -rf "$MXCLI_SRC"
    git clone --quiet "$MXCLI_REPO" "$MXCLI_SRC"
    git -C "$MXCLI_SRC" checkout --quiet --force "$REMOTE_SHA"
  fi

  BUILT_SHA="$(git -C "$MXCLI_SRC" rev-parse HEAD)"
  log "building mxcli @ ${BUILT_SHA:0:12} (this takes a few minutes cold)"
  make -C "$MXCLI_SRC" build

  install -m755 "$MXCLI_SRC/bin/mxcli" "$MXCLI_BIN"
  printf '%s' "$BUILT_SHA" > "$MXCLI_STAMP"
  log "installed mxcli -> ${MXCLI_BIN}"
fi

# ---------------------------------------------------------------------------
# 3. Mendix build engine + runtime for the targeted version.
#    Pre-cached so the first build is not a cold ~1.2 GB download.
# ---------------------------------------------------------------------------
if [ -x "${MXCLI_CACHE}/mxbuild/${MENDIX_VERSION}/modeler/mxbuild" ]; then
  skip "mxbuild ${MENDIX_VERSION} already cached"
else
  log "downloading mxbuild ${MENDIX_VERSION}"
  mxcli setup mxbuild --version "$MENDIX_VERSION"
fi

if [ -d "${MXCLI_CACHE}/runtime/${MENDIX_VERSION}/runtime" ]; then
  skip "Mendix runtime ${MENDIX_VERSION} already cached"
else
  log "downloading Mendix runtime ${MENDIX_VERSION}"
  mxcli setup mxruntime --version "$MENDIX_VERSION"
fi

# ---------------------------------------------------------------------------
# 4. Verification — fail loudly, do not let a half-built toolchain look healthy.
# ---------------------------------------------------------------------------
MX_BIN="${MXCLI_CACHE}/mxbuild/${MENDIX_VERSION}/modeler/mx"
MXBUILD_BIN="${MXCLI_CACHE}/mxbuild/${MENDIX_VERSION}/modeler/mxbuild"
RUNTIME_DIR="${MXCLI_CACHE}/runtime/${MENDIX_VERSION}/runtime"

command -v mxcli   >/dev/null 2>&1 || die "mxcli not on PATH"
mxcli --version    >/dev/null 2>&1 || die "mxcli is installed but does not run"
[ -x "$ANTLR_SHIM" ]               || die "antlr4 shim missing at ${ANTLR_SHIM}"
[ -s "$ANTLR_JAR" ]                || die "ANTLR jar missing at ${ANTLR_JAR}"

ANTLR_REPORTED="$(antlr4 2>/dev/null | sed -n 's/.*Version \([0-9.]*\).*/\1/p' | head -1)"
[ "$ANTLR_REPORTED" = "$ANTLR_VERSION" ] \
  || die "antlr4 reports '${ANTLR_REPORTED:-nothing}', expected ${ANTLR_VERSION}"

[ -x "$MX_BIN" ]                   || die "mx validator missing at ${MX_BIN}"
[ -x "$MXBUILD_BIN" ]              || die "mxbuild engine missing at ${MXBUILD_BIN}"
[ -d "$RUNTIME_DIR" ]              || die "Mendix runtime missing at ${RUNTIME_DIR}"
[ -n "$PG_BINDIR" ] && [ -x "${PG_BINDIR}/postgres" ] \
  || die "postgres server binary not found under /usr/lib/postgresql/*/bin"
command -v pg_ctlcluster >/dev/null 2>&1 || die "pg_ctlcluster not on PATH"
[ -x "$CHROMIUM" ]                 || die "chromium missing at ${CHROMIUM}"

# ---------------------------------------------------------------------------
# 5. Version summary
# ---------------------------------------------------------------------------
cat <<EOF

================ toolchain ready ================
 mxcli          $(mxcli --version 2>&1 | head -1)
 mxcli source   ${REMOTE_SHA}
 ANTLR          ${ANTLR_REPORTED} (${ANTLR_JAR})
 Go (image)     $(go version 2>&1 | awk '{print $3}')
 Go (build)     $(cd "$MXCLI_SRC" && go version 2>&1 | awk '{print $3}')  via GOTOOLCHAIN=${GOTOOLCHAIN}
 Java           $(java -version 2>&1 | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -1)
 Node           $(node --version 2>&1)
 PostgreSQL     $("${PG_BINDIR}/postgres" --version 2>&1 | awk '{print $3}') (${PG_BINDIR})
 Chromium       $("$CHROMIUM" --version 2>&1 | head -1)
 Mendix target  ${MENDIX_VERSION}
   mxbuild      ${MXBUILD_BIN}
   mx           ${MX_BIN}
   runtime      ${RUNTIME_DIR}
=================================================
EOF
