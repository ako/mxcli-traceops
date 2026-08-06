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

fixed=0; present=0; changed=0; improved=0; bydesign=0

report() {  # report <status> <id> <summary>
  case "$1" in
    FIXED)    fixed=$((fixed+1))     ; printf '\033[1;32mFIXED       \033[0m #%-3s %s\n' "$2" "$3" ;;
    PRESENT)  present=$((present+1)) ; printf '\033[1;31mSTILL PRESENT\033[0m #%-3s %s\n' "$2" "$3" ;;
    CHANGED)  changed=$((changed+1)) ; printf '\033[1;33mCHANGED     \033[0m #%-3s %s\n' "$2" "$3" ;;
    # The behaviour is unchanged on purpose, but the finding's actual complaint —
    # usually an unactionable error message — has been addressed.
    IMPROVED) improved=$((improved+1)); printf '\033[1;36mIMPROVED    \033[0m #%-3s %s\n' "$2" "$3" ;;
    # Not a defect. The probe asserts the documented correct form still works, so
    # the entry keeps earning its place without pretending to be an open bug.
    BYDESIGN) bydesign=$((bydesign+1)); printf '\033[1;35mBY DESIGN   \033[0m #%-3s %s\n' "$2" "$3" ;;
  esac
}

# `mxcli check` on a snippet; echoes its output, and the caller greps it.
syntax() { printf '%s\n' "$1" > "$WORK/probe.mdl"; "$MXCLI" check "$WORK/probe.mdl" 2>&1; }

printf 'mxcli    %s\n' "$("$MXCLI" --version 2>&1 | head -1)"
printf 'binary   %s\n' "$MXCLI"
# .installed-sha describes the binary the toolchain hook installed on PATH. When
# MXCLI points at a locally built binary (testing a branch) it is NOT that build's
# sha, so it is labelled honestly rather than passed off as the version under test.
printf 'src HEAD %s (of /opt/mxcli-src, not necessarily of $MXCLI)\n\n' \
  "$(git -C /opt/mxcli-src rev-parse --short HEAD 2>/dev/null || echo '?')"

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
  report FIXED 11 "multi-line string literals parse (apply + build asserted below)"
  MULTILINE_OK=1
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
  report FIXED 12 "reserved words work as widget names (apply + build asserted below)"
  KEYWORDNAME_OK=1
fi

# #16 — `alter entity` requires the `attribute` keyword.
out=$(syntax "alter entity TraceOps.Requirement add ZZProbe16: string(10);")
if ! grep -q 'Syntax errors found' <<<"$out"; then
  report FIXED 16 "'add <name>:' now parses without the 'attribute' keyword"
elif grep -q 'needs the .attribute. keyword' <<<"$out"; then
  # Keeping `attribute` mandatory is right — it is the documented form. The
  # finding's real complaint was the unactionable "no viable alternative at input
  # 'addGuardrailRef'", and that is what got fixed.
  report IMPROVED 16 "syntax unchanged by design, but the error now shows the correct form"
else
  report PRESENT 16 "'add <name>:' is rejected with no hint about the 'attribute' keyword"
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
ok=$(syntax "create or replace microflow TraceOps.ZZ_Probe28b ()
begin
  retrieve \$All from TraceOps.Requirement;
  \$S = call microflow TraceOps.DS_AppState ();
  set \$N = count(\$All);
  change \$S (ReqCount = \$N);
  return;
end;
/")
if grep -qi 'MDL044\|not a Mendix expression function' <<<"$out" && grep -q 'Check passed' <<<"$ok"; then
  report BYDESIGN 28 "aggregates need their own variable (Mendix rule); \$n = count(\$L) passes, inline is caught by MDL044"
elif ! grep -q 'Check passed' <<<"$ok"; then
  report PRESENT 28 "the documented form \$n = count(\$List) no longer passes — regression"
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
# A plain `create` refusing to overwrite is intentional and SQL-shaped. What has
# to hold is that the error names a working idempotent form.
if grep -qi 'already exists' <<<"$out" && grep -qi 'create or modify' <<<"$out"; then
  report BYDESIGN 21 "plain 'create' refuses by design, and the error names 'create or modify'"
elif grep -qi 'already exists' <<<"$out"; then
  report PRESENT 21 "'create microflow' refuses with no pointer to an idempotent form"
else
  report CHANGED 21 "'create microflow' now overwrites silently — that would be a regression"
fi

# The documented re-runnable form for a schema addition.
cat > "$WORK/p21b.mdl" <<'EOF'
alter entity TraceOps.Requirement add attribute if not exists ZZProbe21: string(10);
EOF
"$MXCLI" exec "$WORK/p21b.mdl" -p "$PROJ/TraceOps.mpr" >/dev/null 2>&1
out=$("$MXCLI" exec "$WORK/p21b.mdl" -p "$PROJ/TraceOps.mpr" 2>&1)
if grep -qi 'skipped' <<<"$out"; then
  report BYDESIGN 21 "  └ 'add attribute if not exists' is idempotent, on released mxcli too"
else
  report PRESENT 21 "  └ 'add attribute if not exists' is not idempotent: $(tail -1 <<<"$out")"
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
elif grep -qE "dynamictext empty9\s*$|empty9 \(Content: ''\)" <<<"$out"; then
  report FIXED 9 "Content: '' persists as an empty caption (no Content property)"
else
  report CHANGED 9 "Content: '' persists as: $(grep -o 'empty9.*' <<<"$out" | head -1)"
fi

if grep -q "dollar10 (Content: '\$318')" <<<"$out"; then
  report FIXED 10 "a '\$318' literal survives as a literal"
elif grep -qi 'unbound' <<<"$out"; then
  report PRESENT 10 "a '\$318' literal is still parsed as a variable and left unbound"
else
  report CHANGED 10 "'\$318' persists as: $(grep -o "dollar10[^)]*)" <<<"$out" | head -1)"
fi

# #11 / #12 — the constructs have to survive apply and build, not just parse.
# Asserting on the parse alone is how two probes previously reported a fixed
# behaviour as broken (and #17 hid a silent drop behind a passing check).
if [ "${MULTILINE_OK:-0}" = 1 ] || [ "${KEYWORDNAME_OK:-0}" = 1 ]; then
  cat > "$WORK/p1112.mdl" <<'EOF'
create or replace microflow TraceOps.ZZ_Probe11 ()
returns String as $S
begin
  declare $S String = 'line one
line two';
  return $S;
end;
/
create or replace page TraceOps.ZZ_Probe12 (Title: 'p', Layout: Atlas_Core.Atlas_Default)
{
  container body {
    container content {
      dynamictext search (Content: 'keyword-named widgets')
    }
  }
}
EOF
  "$MXCLI" exec "$WORK/p1112.mdl" -p "$PROJ/TraceOps.mpr" >/dev/null 2>&1
fi

# #23 — combobox binding an association. Association mode needs three things: the
# reference, the option list, and a caption attribute. Probing with `Association:`
# alone tests the *incomplete* form, which is a different question — so both are
# probed, and the complete one is what decides the finding.
cat > "$WORK/p23.mdl" <<'EOF'
create or replace page TraceOps.ZZ_Probe23 (
  params: { $Requirement: TraceOps.Requirement },
  Title: 'p', Layout: Atlas_Core.Atlas_Default)
{
  dataview dv (DataSource: $Requirement) {
    combobox cbParent (
      Label: 'Parent',
      Association: TraceOps.Requirement_Parent,
      datasource: database TraceOps.Requirement,
      CaptionAttribute: ReqId
    )
  }
}
EOF
"$MXCLI" exec "$WORK/p23.mdl" -p "$PROJ/TraceOps.mpr" >/dev/null 2>&1
out=$("$MXCLI" -p "$PROJ/TraceOps.mpr" -c "DESCRIBE PAGE TraceOps.ZZ_Probe23" 2>&1)
if grep -qE 'Attribute: Requirement_Parent|Association: TraceOps.Requirement_Parent' <<<"$out"; then
  report FIXED 23 "combobox binds an association (round-trips; build below confirms)"
else
  report PRESENT 23 "combobox drops the association silently (surfaces later as CE0642)"
fi

# And the incomplete form should now be caught at check time rather than at build.
out=$(syntax "create or replace page TraceOps.ZZ_Probe23b (
  params: { \$Requirement: TraceOps.Requirement },
  Title: 'p', Layout: Atlas_Core.Atlas_Default)
{
  dataview dv (DataSource: \$Requirement) {
    combobox cbBad (Label: 'Parent', Association: TraceOps.Requirement_Parent)
  }
}")
if grep -q 'MDL-WIDGET16' <<<"$out"; then
  report FIXED 23 "  └ an incomplete association combobox is flagged at check time"
else
  report PRESENT 23 "  └ an incomplete association combobox still slips through to MxBuild"
fi

# #37 — a parameterized microflow datasource must survive describe -> exec.
# Asserted on the describe output rather than by re-applying, so this probe cannot
# leave a CE1571 behind and spoil the single mx check below. A String parameter is
# deliberate: with an entity parameter matching the enclosing context, Mendix
# supplies a default argument and the round-trip builds clean even when the
# binding was dropped.
cat > "$WORK/p37.mdl" <<'EOF'
create or modify microflow TraceOps.ZZ_DS_Probe37 ($Prefix: String)
returns List of TraceOps.GuardrailLink as $Links
begin
  retrieve $Links from TraceOps.GuardrailLink
    where TraceOps.GuardrailLink.GuardrailRef = $Prefix;
  return $Links;
end;
/

create or replace page TraceOps.ZZ_Probe37 (Title: 'p', Layout: Atlas_Core.Atlas_Default)
{
  listview lvProbe37 (DataSource: microflow TraceOps.ZZ_DS_Probe37(Prefix: 'GR')) {
    dynamictext t37 (Content: '{1}', ContentParams: [{1} = GuardrailTitle])
  }
}
EOF
"$MXCLI" exec "$WORK/p37.mdl" -p "$PROJ/TraceOps.mpr" >/dev/null 2>&1
out=$("$MXCLI" -p "$PROJ/TraceOps.mpr" -c "DESCRIBE PAGE TraceOps.ZZ_Probe37" 2>&1)
if grep -q "ZZ_DS_Probe37(Prefix" <<<"$out"; then
  report FIXED 37 "describe page emits a parameterized datasource's arguments; the round-trip is lossless"
elif grep -q 'ZZ_DS_Probe37' <<<"$out"; then
  report PRESENT 37 "describe page still drops datasource arguments — a describe -> exec round-trip yields CE1571"
else
  report CHANGED 37 "describe page no longer shows the datasource at all — check by hand"
fi

# ---------------------------------------------------------------------------
# Source probe — #36 needs a booted runtime and a database to test for real, which
# is out of scope for a build-only harness. The defect is one missing pair of JVM
# properties on the local boot path, so when the mxcli source is present the
# presence of that fix is checkable directly.
# ---------------------------------------------------------------------------
# #35 gap 3 — the Starlark widget projection must expose the datasource flow, or
# a rule keyed on it cannot see a microflow-datasource list widget at all.
STARLARK=/opt/mxcli-src/mdl/linter/starlark.go
if [ -r "$STARLARK" ]; then
  if grep -q 'microflow_ref' "$STARLARK"; then
    report FIXED 35 "  └ gap 3: Starlark widgets expose microflow_ref, so PERF001 can detect a microflow datasource"
  else
    report PRESENT 35 "  └ gap 3: Starlark widgets still drop microflow_ref; PERF001 cannot fire"
  fi
fi

LOCALBOOT=/opt/mxcli-src/cmd/mxcli/docker/localboot.go
if [ -r "$LOCALBOOT" ]; then
  if grep -q 'mendix.live-preview=enabled' "$LOCALBOOT"; then
    report FIXED 36 "'run --local' boots the runtime with the live-preview dev flags, so mxcli oql can reach it"
  else
    report PRESENT 36 "'run --local' omits -Dmendix.live-preview; mxcli oql returns 'Action not found'"
  fi
else
  printf '  (skipped #36: %s not readable — needs the mxcli source)\n' "$LOCALBOOT"
fi

# One build check covers every project probe at once.
printf '\n  running mx check on the probe project…\n'
mxout=$("$MX" check "$PROJ/TraceOps.mpr" 2>&1 | tail -25)
errs=$(grep -c '^\[error\]' <<<"$mxout" || true)
printf '  %s\n' "$(grep 'The app contains' <<<"$mxout")"
if [ "$errs" -gt 0 ]; then
  grep '^\[error\]' <<<"$mxout" | sed 's/^/    /' | head -12
fi

printf '\n%d fixed, %d still present, %d improved, %d by design, %d changed\n' \
  "$fixed" "$present" "$improved" "$bydesign" "$changed"

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

A clean `mx check` on the probe project is the real pass for #9, #10, #11, #12 and
#23: each writes the construct that used to fail, so 0 errors is the assertion. On
a regression, expect CE0720 at 'empty9', CE0402 at 'dollar10', CE0642 at
'cbParent'.
NOTE
