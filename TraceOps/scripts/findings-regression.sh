#!/usr/bin/env bash
#
# Re-test every FINDINGS entry that is an mxcli behaviour, against whatever mxcli
# is currently installed.
#
# Each probe reproduces the exact construct from the finding and reports
# FIXED / STILL PRESENT / CHANGED. Run it after any mxcli update:
#
#   bash scripts/findings-regression.sh
#
# Platform findings (Mendix semantics, Atlas CSS, test methodology) are out of
# scope here — mxcli cannot fix them. The list at the bottom says which and why.
#
# Probes run against a throwaway copy of the project so the real .mpr is never
# touched. Syntax-only probes need no project at all.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
MXCLI=${MXCLI:-mxcli}
MX=${MX:-$HOME/.mxcli/mxbuild/11.12.1/modeler/mx}

WORK=$(mktemp -d)
PROJ="$WORK/proj"
trap 'rm -rf "$WORK"' EXIT

fixed=0; present=0; changed=0

report() {  # report <status> <id> <summary>
  case "$1" in
    FIXED)   fixed=$((fixed+1))   ; printf '\033[1;32mFIXED       \033[0m #%-3s %s\n' "$2" "$3" ;;
    PRESENT) present=$((present+1)); printf '\033[1;31mSTILL PRESENT\033[0m #%-3s %s\n' "$2" "$3" ;;
    CHANGED) changed=$((changed+1)); printf '\033[1;33mCHANGED     \033[0m #%-3s %s\n' "$2" "$3" ;;
  esac
}

# `mxcli check` on a snippet; echoes its output, and the caller greps it.
syntax() { printf '%s\n' "$1" > "$WORK/probe.mdl"; "$MXCLI" check "$WORK/probe.mdl" 2>&1; }

printf 'mxcli    %s\n' "$("$MXCLI" --version 2>&1 | head -1)"
printf 'source   %s\n\n' "$(cat /opt/mxcli-src/.installed-sha 2>/dev/null || echo '?')"

# ---------------------------------------------------------------------------
# Syntax-only probes
# ---------------------------------------------------------------------------

# #11 — MDL string literals cannot span lines.
out=$(syntax "create or replace microflow TraceOps.ZZ_Probe11 ()
begin
  declare \$S String = 'line one
line two';
  return;
end;
/")
if grep -q 'Syntax errors found' <<<"$out"; then
  report PRESENT 11 "a string literal still cannot span lines"
else
  report FIXED 11 "multi-line string literals now parse"
fi

# #12 — reserved words rejected as widget names.
out=$(syntax "create or replace page TraceOps.ZZ_Probe12 (Title: 'p', Layout: Atlas_Core.Atlas_Default)
{
  container body {
    dynamictext t (Content: 'x')
  }
}")
if grep -qi 'syntax errors found\|reserved' <<<"$out"; then
  report PRESENT 12 "'body' is still rejected as a widget name"
else
  report FIXED 12 "reserved words are usable as widget names"
fi

# #16 — `alter entity` requires the `attribute` keyword.
out=$(syntax "alter entity TraceOps.Requirement add ZZProbe16: string(10);")
if grep -q 'Syntax errors found' <<<"$out"; then
  report PRESENT 16 "'add <name>:' without the 'attribute' keyword is still rejected"
else
  report FIXED 16 "'add <name>:' now parses without the 'attribute' keyword"
fi

# #27 — a doc comment between two `add attribute` clauses.
out=$(syntax "alter entity TraceOps.Requirement
  add attribute ZZProbe27a: string(10)
  /** a doc comment between add clauses */
  add attribute ZZProbe27b: string(10);")
if grep -q 'Syntax errors found' <<<"$out"; then
  report PRESENT 27 "a doc comment between add-attribute clauses is still a syntax error"
else
  report FIXED 27 "doc comments are now allowed between add-attribute clauses"
fi

# #28 — count() used inline in a change expression.
out=$(syntax "create or replace microflow TraceOps.ZZ_Probe28 ()
begin
  retrieve \$All from TraceOps.Requirement;
  \$S = call microflow TraceOps.DS_AppState ();
  change \$S (ReqCount = count(\$All));
  return;
end;
/")
if grep -qi 'MDL044\|not a Mendix expression function' <<<"$out"; then
  report PRESENT 28 "count() inline in an expression is still rejected (correctly, with MDL044)"
else
  report CHANGED 28 "count() inline no longer flagged — check it still builds"
fi

# ---------------------------------------------------------------------------
# Project probes — need a real .mpr. One copy, one build check.
# ---------------------------------------------------------------------------
mkdir -p "$PROJ"
# themesource/ and modules/ matter: without them mx check drowns the real results
# in ~930 CE6083 "design property not supported by your theme" errors.
cp -r TraceOps.mpr mprcontents widgets theme themesource modules resources \
      javasource javascriptsource userlib "$PROJ/" 2>/dev/null

# #21 — idempotency of `create microflow` and `alter entity add attribute`.
cat > "$WORK/p21.mdl" <<'EOF'
create microflow TraceOps.ZZ_Probe21 ()
begin
  return;
end;
/
EOF
"$MXCLI" exec "$WORK/p21.mdl" -p "$PROJ/TraceOps.mpr" >/dev/null 2>&1
out=$("$MXCLI" exec "$WORK/p21.mdl" -p "$PROJ/TraceOps.mpr" 2>&1)
if grep -qi 'already exists' <<<"$out"; then
  report PRESENT 21 "'create microflow' is still not idempotent"
else
  report FIXED 21 "'create microflow' can be re-applied"
fi

cat > "$WORK/p21b.mdl" <<'EOF'
alter entity TraceOps.Requirement add attribute ZZProbe21: string(10);
EOF
"$MXCLI" exec "$WORK/p21b.mdl" -p "$PROJ/TraceOps.mpr" >/dev/null 2>&1
out=$("$MXCLI" exec "$WORK/p21b.mdl" -p "$PROJ/TraceOps.mpr" 2>&1)
if grep -qi 'already exists' <<<"$out"; then
  report PRESENT 21 "  └ 'alter entity add attribute' still has no 'or replace' form"
else
  report FIXED 21 "  └ 'alter entity add attribute' is now re-appliable"
fi

# #17 — ListView PageSize. Set it, then read it back out of the model.
cat > "$WORK/p17.mdl" <<'EOF'
create or replace page TraceOps.ZZ_Probe17 (Title: 'p', Layout: Atlas_Core.Atlas_Default)
{
  listview lvProbe (
    DataSource: database from TraceOps.Requirement,
    PageSize: 500
  ) {
    dynamictext t (Content: '{1}', ContentParams: [{1} = ReqId])
  }
}
EOF
"$MXCLI" exec "$WORK/p17.mdl" -p "$PROJ/TraceOps.mpr" >/dev/null 2>&1
out=$("$MXCLI" -p "$PROJ/TraceOps.mpr" -c "DESCRIBE PAGE TraceOps.ZZ_Probe17" 2>&1)
if grep -q 'PageSize: 500' <<<"$out"; then
  report FIXED 17 "listview PageSize is honoured and round-trips"
else
  report PRESENT 17 "listview PageSize is still dropped (accepted, then ignored)"
fi

# #9 — an empty Content: on a DYNAMICTEXT.
# #10 — a Content: literal starting with '$' + digits.
# #19 — a DYNAMICTEXT bound to an enumeration.
cat > "$WORK/p9.mdl" <<'EOF'
create or replace page TraceOps.ZZ_Probe910 (Title: 'p', Layout: Atlas_Core.Atlas_Default)
{
  container c {
    dynamictext empty9 (Content: '')
    dynamictext dollar10 (Content: '$318')
  }
}
EOF
"$MXCLI" exec "$WORK/p9.mdl" -p "$PROJ/TraceOps.mpr" >/dev/null 2>&1
out=$("$MXCLI" -p "$PROJ/TraceOps.mpr" -c "DESCRIBE PAGE TraceOps.ZZ_Probe910" 2>&1)
if grep -q "empty9 (Content: '{1}')" <<<"$out"; then
  report PRESENT 9 "Content: '' still persists as an orphaned '{1}' placeholder"
elif grep -qE "empty9 \(Content: ''\)|empty9 \(\)" <<<"$out"; then
  report FIXED 9 "Content: '' now persists as an empty caption"
else
  report CHANGED 9 "Content: '' persists as something new: $(grep -o "empty9[^)]*)" <<<"$out" | head -1)"
fi

if grep -q "dollar10 (Content: '\$318')" <<<"$out"; then
  report FIXED 10 "a '\$318' literal survives as a literal"
elif grep -qi 'unbound' <<<"$out"; then
  report PRESENT 10 "a '\$318' literal is still parsed as a variable and left unbound"
else
  report CHANGED 10 "'\$318' persists as: $(grep -o "dollar10[^)]*)" <<<"$out" | head -1)"
fi

# #23 — combobox and an association. The grammar has always *accepted*
# `Association:`; the writer drops it, and the failure surfaces at MxBuild. So the
# test is whether it round-trips, not whether it parses.
cat > "$WORK/p23.mdl" <<'EOF'
create or replace page TraceOps.ZZ_Probe23 (
  params: { $Requirement: TraceOps.Requirement },
  Title: 'p', Layout: Atlas_Core.Atlas_Default)
{
  dataview dv (DataSource: $Requirement) {
    combobox cbParent (Label: 'Parent', Association: TraceOps.Requirement_Parent)
  }
}
EOF
"$MXCLI" exec "$WORK/p23.mdl" -p "$PROJ/TraceOps.mpr" >/dev/null 2>&1
out=$("$MXCLI" -p "$PROJ/TraceOps.mpr" -c "DESCRIBE PAGE TraceOps.ZZ_Probe23" 2>&1)
if grep -q 'Association: TraceOps.Requirement_Parent' <<<"$out"; then
  report FIXED 23 "combobox now keeps an Association through a round-trip"
else
  report PRESENT 23 "combobox drops Association silently (surfaces later as CE0642)"
fi

# One build check covers every project probe at once.
printf '\n  running mx check on the probe project…\n'
mxout=$("$MX" check "$PROJ/TraceOps.mpr" 2>&1 | tail -25)
errs=$(grep -c '^\[error\]' <<<"$mxout" || true)
printf '  %s\n' "$(grep 'The app contains' <<<"$mxout")"
if [ "$errs" -gt 0 ]; then
  grep '^\[error\]' <<<"$mxout" | sed 's/^/    /' | head -12
fi

printf '\n%d fixed, %d still present, %d changed\n' "$fixed" "$present" "$changed"

cat <<'NOTE'

Out of scope — these are Mendix or environment behaviour, not mxcli:
  #1-#8   toolchain and base image (ANTLR, GOTOOLCHAIN, PATH, 403 on raw github)
  #13,#18 Atlas wrapper DOM and flex direction
  #14     ListView row cannot read an ancestor DataView's object
  #20     commit without refresh never re-queries the client
  #22     no integer division, no Decimal -> Integer conversion
  #24     required-attribute validation fires on assignment
  #19     a bound enum renders its value name, not its caption (Mendix client)
  #25,#30 test-harness behaviour
  #26,#29 consequences of app design, not tool defects

Expected build errors from the probes, which are the findings reproducing:
  CE0720 at 'empty9'   -> #9   Content: '' left an orphaned {1} placeholder
  CE0402 at 'dollar10' -> #10  '$318' parsed as a variable, left unbound
  CE0642 at 'cbParent' -> #23  combobox Association dropped
NOTE
