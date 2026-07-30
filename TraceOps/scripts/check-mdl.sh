#!/usr/bin/env bash
#
# Syntax-check every MDL source file.
#
# The repo's central claim is that the app can be re-applied from mdlsource/ from
# scratch. That only holds if every file parses — and a file can be applied
# successfully in pieces (via `-c`, or before a comment was added) while the file
# as a whole no longer parses. 17-crud-domain.mdl shipped in exactly that state.
# This is the guard for that; run it before committing MDL changes.
#
#   bash scripts/check-mdl.sh
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MXCLI=${MXCLI:-mxcli}
fail=0
checked=0

for f in mdlsource/*.mdl; do
  [ -e "$f" ] || continue
  checked=$((checked + 1))
  out=$("$MXCLI" check "$f" 2>&1)
  if printf '%s' "$out" | grep -qE 'Syntax errors found|^Error'; then
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$f"
    printf '%s\n' "$out" | grep -E '^\s+- line' | head -5 | sed 's/^/      /'
  else
    printf 'ok    %s\n' "$f"
  fi
done

printf '\n%d file(s) checked, %d failed\n' "$checked" "$fail"
[ "$fail" -eq 0 ] || exit 1
