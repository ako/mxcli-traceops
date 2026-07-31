# FINDINGS

Running log of mxcli bugs, surprises, and workarounds. Numbered, with the exact
command and output. Started in the toolchain-setup session (phase 1).

**Re-testing.** `TraceOps/scripts/findings-regression.sh` reproduces every entry
that is an mxcli behaviour, against whatever mxcli is installed, and reports
FIXED / STILL PRESENT / CHANGED. Run it after any mxcli update. The remaining
entries are Mendix semantics, Atlas CSS, environment or test methodology — mxcli
cannot fix those, and the script says so rather than pretending to test them.

Last run: a local build of branch **`claude/mxbuild-diagnostics-spike-emta6h`**
(`e47926f8`, 2026-07-31) — **9 fixed, 0 still present, 1 improved, 3 by design, 0
changed**, with `mx check` clean on the probe project. #36 is fixed there, and
more thoroughly than the patch I proposed. Nothing on this list is an open mxcli
defect.

Progress across four runs of the same harness: `nightly-68` 0 fixed →
`nightly-71` 5 → `nightly-72` 7 fixed + 1 improved + 2 reclassified →
`e47926f8` 9 fixed.

**#31–#35 are a different kind of entry.** They come from working out how to
analyse and extend a *large existing* app rather than from building this one, and
several correct earlier mistakes of mine rather than reporting tool defects.
#31–#34 are about view entities — what they are, what OQL can express, the
measured pushdown behaviour, and using one view object to edit several records.
#35 records the catalog and lint gaps that stop the common data-retrieval
anti-patterns from being detected automatically.

**#36 was the one open defect** found after the PR #58 run — `mxcli oql` could not
reach an app started with `mxcli run --local`. It is now fixed, and the fix also
closed the admin-password and misleading-hint problems recorded alongside it.
**#35's gap 3 is fixed too**: Starlark rules can now read a widget's datasource
microflow, which makes `TraceOps/.claude/lint-rules/perf001_microflow_datasource.star`
work — the rule that was inert when #35 was written. #35's other three gaps stand.

---

## 1. `go build` alone cannot build mxcli — the ANTLR parser is not committed

**Severity:** blocker for any from-source build
**Phase:** 1 (toolchain)

mxcli's README/`go.mod` suggest an ordinary Go build, but `mdl/grammar/parser/`
is gitignored in the mxcli repo:

```
$ grep -A2 'ANTLR4 parser' /opt/mxcli-src/.gitignore
# ANTLR4 parser (regenerate with: make grammar)
mdl/grammar/parser/
```

So the generated Go parser must be produced by ANTLR *before* compiling. On top
of that, `cmd/mxcli` uses `go:embed` for payloads that are **also** gitignored:

```
$ grep -n 'go:embed' /opt/mxcli-src/cmd/mxcli/*.go
cmd/mxcli/cmd_changelog.go:13://go:embed changelog.md
cmd/mxcli/skills_content.go:21://go:embed skills/*.md
cmd/mxcli/skills_content.go:26://go:embed commands/*.md
cmd/mxcli/skills_content.go:31://go:embed lint-rules/*.star
cmd/mxcli/skills_content.go:36://go:embed vscode-mdl.vsix
```

A bare `go build ./cmd/mxcli` therefore fails on missing embed directories.

**Workaround:** always build via the Makefile, whose `build` target chains the
prerequisites:

```
build: grammar sync-all completions
```

`scripts/setup-tools.sh` runs `make -C /opt/mxcli-src build`.

Note `sync-vsix` degrades gracefully — with no `.vsix` present it creates an
empty placeholder, so **bun is not required** for a working build.

---

## 2. `GOTOOLCHAIN` must be `auto` — go.mod outruns the image's Go

**Severity:** blocker on a pinned-toolchain image
**Phase:** 1 (toolchain)

```
$ go version
go version go1.24.7 linux/amd64

$ head -4 /opt/mxcli-src/go.mod
module github.com/mendixlabs/mxcli

go 1.26.0
toolchain go1.26.5
```

With `GOTOOLCHAIN` pinned to a local version the build fails outright. With
`auto`, Go fetches the declared toolchain and compiles cleanly:

```
$ cd /opt/mxcli-src && GOTOOLCHAIN=auto go version
go version go1.26.5 linux/amd64
```

`proxy.golang.org` is in the agent proxy's `noProxy` list, so the toolchain
download goes direct and works. `scripts/setup-tools.sh` exports
`GOTOOLCHAIN=auto` explicitly rather than relying on the image default.

---

## 3. ANTLR version skew: mxcli CI uses 4.13.2, go.mod runtime pins 4.13.1

**Severity:** low, but worth knowing before debugging a parser mismatch
**Phase:** 1 (toolchain)

The brief specifies ANTLR **4.13.1**, which matches the Go runtime dependency:

```
$ grep antlr4-go /opt/mxcli-src/go.mod
	github.com/antlr4-go/antlr/v4 v4.13.1
```

But mxcli's own CI generates the parser with **4.13.2**:

```
$ grep -n 'ANTLR4_TOOLS_ANTLR_VERSION' /opt/mxcli-src/.github/workflows/*.yml
.github/workflows/nightly.yml:37:          ANTLR4_TOOLS_ANTLR_VERSION: '4.13.2'
.github/workflows/push-test.yml:26:          ANTLR4_TOOLS_ANTLR_VERSION: '4.13.2'
```

We pin 4.13.1 as instructed — it matches the generated code to the runtime
exactly, which is the more defensible pin. Generator/runtime skew in ANTLR Go is
usually tolerated, so this is recorded rather than treated as a problem. Build
with 4.13.1 succeeded with no warnings.

---

## 4. `mx --version` is not a recognised verb, and exits 0 on the error

**Severity:** cosmetic, but it will break a naive health check
**Phase:** 1 (toolchain)

```
$ /root/.mxcli/mxbuild/11.12.1/modeler/mx --version
ERROR(S):
  Verb '--version' is not recognized.

Try '--help' for more information.
$ echo $?
0
```

Two surprises: there is no `--version` verb, **and** the unrecognised-verb error
still exits `0`. Any liveness probe built on `mx --version` succeeding would pass
vacuously.

**Workaround:** `scripts/setup-tools.sh` verifies the `mx` validator by checking
the binary exists and is executable, not by parsing a version. Reaching the
argument parser at all does confirm the native libraries loaded (see #5).

---

## 5. The libSkiaSharp/FreeType crash does *not* affect 11.12.1

**Severity:** none — negative result, recorded to save a future investigation
**Phase:** 1 (toolchain)

mxcli's `CLAUDE.md` warns that some bundled `mx` binaries (observed on 11.10.0)
abort with `symbol lookup error: .../libSkiaSharp.so: undefined symbol:
FT_Get_BDF_Property`, needing a system-libfreetype `LD_PRELOAD` workaround.

On **11.12.1** this does not reproduce — `mx` gets far enough to parse arguments
and emit its own CLI error (see #4), which means Skia and FreeType loaded fine.
No `LD_PRELOAD` shim is needed, so none was added.

---

## 6. PostgreSQL 16 server is installed but the `postgres` binary is off PATH

**Severity:** low — misleading during environment detection
**Phase:** 1 (toolchain)

```
$ postgres --version
bash: postgres: command not found

$ psql --version
psql (PostgreSQL) 16.13 (Ubuntu 16.13-0ubuntu0.24.04.1)
```

This reads like "client only, server missing". It is not — the full server is
installed via Ubuntu's `postgresql-common` layout, with the binaries under a
versioned directory and a cluster already registered but stopped:

```
$ ls -d /usr/lib/postgresql/*/bin
/usr/lib/postgresql/16/bin

$ pg_lsclusters
Ver Cluster Port Status Owner    Data directory              Log file
16  main    5432 down   postgres /var/lib/postgresql/16/main /var/log/postgresql/...
```

No PATH surgery is needed: mxcli's `--ensure-db` drives the cluster through the
`postgresql-common` wrappers, which *are* on PATH:

```
$ grep -n 'pg_ctlcluster\|pg_isready' /opt/mxcli-src/cmd/mxcli/docker/ensuredb.go
118:		{"pg_ctlcluster", "--", "start"},
145:	if _, err := exec.LookPath("pg_isready"); err != nil {
```

`scripts/setup-tools.sh` verifies `/usr/lib/postgresql/*/bin/postgres` by
globbing the versioned directory and additionally asserts `pg_ctlcluster` is on
PATH.

---

## 7. Base image drifts from the brief: Node 22, not Node 20

**Severity:** informational
**Phase:** 1 (toolchain)

Expected "Node 20+"; the image ships Node 22. Recorded because a future
`--watch`/rollup bundling issue would make the major version the first suspect.

```
$ node --version
v22.22.2
$ npm --version
10.9.7
```

A second drift, more consequential: the brief states
`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD` is already set. It is **not set at all** —
only `PLAYWRIGHT_BROWSERS_PATH` is:

```
$ env | grep PLAYWRIGHT
PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers

$ if [ -z "${PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD+x}" ]; then echo UNSET; fi
UNSET
```

(Testing with a bare `echo "$PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD"` is not enough —
it prints empty whether the variable is unset or set-to-empty. Use `${var+x}`.)

So nothing currently suppresses a Playwright browser download during an `npm
install` postinstall. Worth exporting `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` before
any npm work in a later phase. Chromium 141.0.7390.37 is present and was not
reinstalled; `playwright install` was never run.

---

## 8. `curl https://github.com/...` returns 403, but `git clone` works

**Severity:** low — a misleading preflight signal
**Phase:** 1 (toolchain)

An HTTP preflight against GitHub through the agent proxy returns 403:

```
$ curl -sS -o /dev/null -w '%{http_code}\n' https://github.com/ako/mxcli
403
```

This looks like an egress-policy denial, but it is not — `git clone` over the
same proxy succeeds, and the proxy's own status endpoint reports no failures:

```
$ curl -sS "$HTTPS_PROXY/__agentproxy/status" | grep recentRelayFailures
  "recentRelayFailures": [],

$ git clone --depth 1 https://github.com/ako/mxcli.git /tmp/probe
Cloning into '/tmp/probe'... done.
```

**Takeaway:** do not use a bare `curl` against a GitHub HTML URL to decide
whether the network is usable. Test with the protocol you actually need.

---

## 9. `Content: ''` on a DYNAMICTEXT persists as `Content: '{1}'` — an orphaned placeholder

**Severity:** blocker — 29 MxBuild errors from one idiom
**Phase:** 2 (TraceOps app)
**mxcli:** nightly-41-g0ed0359f

The prototype has many purely decorative elements (status dots, flex spacers,
progress-bar segments). Modelled as a styled `container` with an empty text
child, mxcli rewrites the empty content into a one-placeholder template with no
params:

```
$ grep -n "dynamictext x1" mdlsource/07-shell-snippets.mdl
          dynamictext x1 (Content: '')

$ ./mxcli -p TraceOps.mpr -c "DESCRIBE SNIPPET TraceOps.SNIPPET_Sidebar" | grep -A1 lgd1
        container lgd1 (Class: 'tr-legend-dot tr-legend-dot--verified') {
          dynamictext x1 (Content: '{1}')
```

`mxcli check` passes. MxBuild does not:

```
$ ~/.mxcli/mxbuild/11.12.1/modeler/mx check TraceOps.mpr
[error] [CE0720] "Place holder index 1 is greater than 0, the number of parameter(s)." at Text 'x1'
...
The app contains: 29 errors.
```

**Workaround:** use a single space, `Content: ' '`, which round-trips verbatim.
Note the empty container is not an option either — lint rule MPR006 flags empty
containers as a runtime crash risk.

**FIXED by mxcli PR #58** (`ako/mxcli`, verified on a local build of the PR, `nightly-71-g240e7d2c`, 2026-07-30). `Content: ''` now persists as a caption-less widget (`dynamictext empty9`) and builds clean — no CE0720.

---

## 10. A `Content:` literal starting with `$` + digits is parsed as a variable reference

**Severity:** blocker, and silent — `mxcli check` reports nothing
**Phase:** 2 (TraceOps app)
**mxcli:** nightly-41-g0ed0359f

The sessions view has a "Spend today · $318" tile. Written as a plain literal,
the `$318` is taken as a positional variable and persisted as an *unbound*
content param:

```
$ grep -n "s4v" mdlsource/14-page-sessions.mdl
            dynamictext s4v (Content: '$318', Class: 'tr-stat-value ...')

$ ./mxcli -p TraceOps.mpr -c "DESCRIBE PAGE TraceOps.AgentSessions" | grep -A2 s4v
            dynamictext s4v (
              Content: '{1}',
              ContentParams: [{1} = <unbound>],

$ ~/.mxcli/mxbuild/11.12.1/modeler/mx check TraceOps.mpr
[error] [CE0402] "No value specified." at Text 's4v'
```

`mxcli check --references` passes clean, so this only surfaces at MxBuild.

**Workaround:** pass the value as a literal content param. Three forms were
tested and all round-trip correctly; only a *leading* `$`+digits is affected:

```
dynamictext a (Content: '{1}318', ContentParams: [{1} = '$'])    -- ok
dynamictext b (Content: 'x$318')                                 -- ok (not leading)
dynamictext d (Content: '{1}', ContentParams: [{1} = '$318'])    -- ok — used
```

**FIXED by mxcli PR #58** (`ako/mxcli`, verified on a local build of the PR, `nightly-71-g240e7d2c`, 2026-07-30). `Content: '$318'` now round-trips as the literal `'$318'` — no CE0402. The `ContentParams` workaround is still valid, just no longer required.

---

## 11. MDL string literals cannot span lines

**Severity:** design constraint, not a bug — but it shapes the domain model
**Phase:** 2 (TraceOps app)

The prototype renders agent session logs, test-run output and a diff snippet as
pre-formatted multi-line blocks (`white-space: pre-wrap`). There is no way to
write one:

```
$ ./mxcli check /tmp/ml.mdl
  declare $S String = 'line one
line two';
  - line 6:5 missing END at 'two'
```

The checker's own hint confirms it is general to MDL, not just microflows:
*"dynamicclasses: 'if $x then ''a'' else ''b''' (correct — one line)"*.

**Workaround:** model multi-line text as ordered child rows and render with a
ListView. TraceOps has a `CodeLine` entity (LineKind / Text / Tone / SortIndex)
used for all three blocks. This turned out better than a wrapped string anyway —
each line carries its own tone, so `✗` failures render red and `›` steps grey.

**FIXED by mxcli PR #58** (verified on a local build, `nightly-72-gc55e2029`, 2026-07-30). A string literal spans lines, round-trips through `describe` with the newline intact, and builds clean. The `CodeLine` child-row modelling in this app was the workaround for it and is still worth keeping — an agent log is genuinely a list of lines, not one string — but it is no longer forced.

---

## 12. Reserved words silently blocked as *widget* names

**Severity:** low friction, good error message
**Phase:** 2 (TraceOps app)

Four natural widget names were rejected by the parser: `body`, `content`, `as`
and `search`.

```
$ ./mxcli check mdlsource/08-page-cockpit.mdl
  - line 17:14 mismatched input 'body' expecting {IDENTIFIER, QUOTED_IDENTIFIER}
  'Body' is a reserved keyword in MDL. Use a different name like:
    - Body_  (add underscore suffix)
```

The diagnostic names the conflict and suggests fixes, which is genuinely good.
Worth knowing up front, because `body`/`content` are the obvious names for an
app-shell container. Renamed to `appBody` / `mainContent` / `asx` / `searchBox`.

Separately, the enum value `new` is reserved and rejected at *check* time with
the platform error code:

```
  ✗ enumeration value 'new' is a reserved word (CE7247) [MDL010]
      at TraceOps.FileChange
```

**FIXED by mxcli PR #58** (verified on a local build, `nightly-72-gc55e2029`, 2026-07-30). `body`, `content` and `search` all work as widget names now, and the round-trip quotes them (`container "body"`) so re-applying stays safe. Builds clean. The `appBody` / `mainContent` / `searchBox` renames in this app are no longer needed, though they are harmless.

---

## 13. Layout classes never reach children — Mendix wrapper DOM

**Severity:** none (platform behaviour), but it silently breaks every grid
**Phase:** 2 (TraceOps app)

A `Class:` on a DataView or ListView lands on the widget's *outer* element, and
both widgets insert a wrapper before the children. So `display: grid` on the
widget class has no effect on the rows — the first render had all six KPI tiles
stacked vertically and the top bar centred instead of spread:

```
$ node dom.js
self: <DIV class="mx-dataview mx-name-dvTop tr-topbar form-horizontal">
  child: <DIV class="mx-dataview-content">
    gchild: <DIV class="mx-name-brand tr-brand">

self: <DIV class="mx-listview mx-name-lvKpi tr-kpi-grid tr-lv">
  child: <UL class="">
    gchild: <LI class="mx-name-index-0">
```

**Workaround (two different fixes, one per widget):**

```scss
// DataView — make the wrapper transparent so children join the parent's layout
.tr-app .mx-dataview > .mx-dataview-content { display: contents; }

// ListView — move the grid onto the `ul`, which is the real row container
.tr-kpi-grid { display: block; }
.tr-kpi-grid > ul { display: grid; grid-template-columns: repeat(6, minmax(0,1fr)); gap: 10px; }
```

`display: contents` is the cleaner half: one rule fixes every DataView-as-layout
in the app. The ListView half cannot use it, because the `li` must stay the grid
item.

---

## 14. A ListView row cannot read an ancestor DataView's object

**Severity:** design constraint — forced a domain-model change
**Phase:** 2 (TraceOps app)

The prototype highlights the selected tree row. The natural expression compares
the row to the shared selection state held on an ancestor DataView:

```
DynamicClasses: 'if $currentObject/ReqId = $Selected/SelectedReqId then ...'
```

Inside a ListView row, `$currentObject` is the row object and the ancestor
DataView's object is not addressable by name, so there is nothing to compare
against.

**Workaround:** denormalise the selection onto the rows as an `IsSelected`
boolean that the row can read directly:

```
DynamicClasses: 'if $currentObject/IsSelected then ''tr-tree-row--sel'' else '''''
```

The select microflow clears only the currently-flagged row rather than rewriting
the table (`retrieve ... where [IsSelected = true]`). Applied to all three
master/detail views (requirements, sessions, validation queue).

---

## 15. `mxcli check` is not a substitute for `mx check`

**Severity:** process note — cost two debug cycles
**Phase:** 2 (TraceOps app)

Both findings #9 and #10 pass `mxcli check --references` cleanly and fail at
MxBuild. The reference checker validates that named elements exist; it does not
re-validate what the writer actually persisted.

```
$ ./mxcli check mdlsource/14-page-sessions.mdl -p TraceOps.mpr --references
✓ Syntax OK (1 statements)
✓ All references valid
Check passed!

$ ~/.mxcli/mxbuild/11.12.1/modeler/mx check TraceOps.mpr
[error] [CE0402] "No value specified." at Text 's4v'
```

**Takeaway:** run `mx check` after every slice, not just `mxcli check` — and
`describe page` is the fastest way to see what was *actually* written when a
build error names a widget you believe is fine.

---

## 16. `alter entity` needs the `attribute` keyword; `DELETE_ME` is not a delete behavior

**Severity:** trivial, recorded for the exact syntax
**Phase:** 2 (TraceOps app)

```
$ ./mxcli exec alter.mdl -p TraceOps.mpr
Parse error: line 1:40 no viable alternative at input 'addGuardrailRef'
```

The working form is `alter entity M.E add attribute Name: type;` (the bare
`add Name: type` used by some ORMs is rejected). Multiple additions chain
without commas and take one trailing semicolon.

Association delete behavior accepts only
`DELETE_AND_REFERENCES | DELETE_BUT_KEEP_REFERENCES | DELETE_IF_NO_REFERENCES | CASCADE | PREVENT`.
For "delete the child when the parent goes", the value is `CASCADE`.

**IMPROVED by mxcli PR #58** (verified on a local build, `nightly-72-gc55e2029`, 2026-07-30). The grammar is deliberately unchanged — `attribute` is the documented form — but the unactionable parse error is gone. It now names the fix:

```
$ mxcli check p16.mdl
  - line 1:38 no viable alternative at input 'addZZProbe16'

  ALTER ENTITY needs the `attribute` keyword before a new attribute:
    alter entity Module.Entity add attribute ZZProbe16: <type>;   (correct)
    alter entity Module.Entity add ZZProbe16: <type>;             (wrong)
```

which is the right resolution for a finding whose whole content was "here is the exact syntax".

---

## 17. ListView `PageSize` cannot be set from MDL at all — hardcoded to 20

**Severity:** functional limitation with no MDL workaround
**Phase:** 2 (TraceOps app)
**mxcli:** nightly-41-g0ed0359f

The traceability tree shows 31 rows in its opening state. The rendered page stops
at 20 and shows a "Load more" button.

`PageSize` is documented for DATAGRID and is accepted by the parser on a
LISTVIEW without any warning — but it is silently discarded:

```
$ grep -n "PageSize" mdlsource/10-page-traceability.mdl
                PageSize: 200,

$ ./mxcli -p TraceOps.mpr -c "DESCRIBE PAGE TraceOps.Traceability" | grep -A3 "listview lvTree"
              listview lvTree (
                DataSource: database from TraceOps.Requirement where IsVisible = true,
                Class: 'tr-panel-body tr-fill tr-lv'
              ) {
```

The builder hardcodes it and never reads the property:

```go
// mdl/executor/cmd_pages_builder_v3_widgets.go:232
func (pb *pageBuilder) buildListViewV3(w *ast.WidgetV3) (*pages.ListView, error) {
	lv := &pages.ListView{
		...
		PageSize: 20,
	}
```

The SDK *does* expose a setter (`modelsdk/gen/pages/types.go:15319
`func (o *ListView) SetPageSize(v int32)`), so only the MDL wiring is missing.

`alter page` is not a way in either — it only reaches pluggable widgets:

```
$ ./mxcli exec ps.mdl -p TraceOps.mpr
Error: failed to set: failed to set PageSize on lvTree:
  property "PageSize" not found (widget has no pluggable Object)
```

A GALLERY (pluggable) *accepts* `alter page ... set pageSize = 200` without
error, but the value does not round-trip through `describe`, so it was not
trusted as a workaround. Gallery also drops `PageSize`/`DesktopColumns` when
given inline on `create page`.

**Status: unresolved — and the failure mode has since got worse.** Re-checked on
`nightly-58-g0580eadf`: an inline `PageSize: 500` on the `listview` is now
*accepted* rather than rejected. It parses, passes `mxcli check --references`,
applies without a warning, and `mx check` reports 0 errors — then the value is
silently discarded, because `buildListViewV3` still opens with a literal
`PageSize: 20` and never reads a `PageSize` property off the AST:

```go
// mdl/executor/cmd_pages_builder_v3_widgets.go:232
func (pb *pageBuilder) buildListViewV3(w *ast.WidgetV3) (*pages.ListView, error) {
	lv := &pages.ListView{ ... PageSize: 20 }      // never overridden from w.Properties
```

The writer downstream *does* honour a non-zero value
(`widget_write.go:535`, `if pageSize == 0 { pageSize = 20 }`), so only the builder
is missing the wiring. Verified end-to-end against the running app — still 20 rows
and a "Load more" — and the property does not round-trip through
`describe page` either. This now belongs in the same family as #9 and #10: a
silent writer drop that every available check passes.

Every other list in the app is under 20 rows, so this affects one view. Switching
the tree to a DATAGRID would fix the paging but costs the pixel-exact row markup
that the design needs (the migrate-design-prototype skill recommends ListView for
exactly this reason).

**FIXED by mxcli PR #58** (`ako/mxcli`, verified on a local build of the PR, `nightly-71-g240e7d2c`, 2026-07-30). `PageSize: 500` is honoured and round-trips. The traceability tree now renders all 81 rows with no "Load more": `after Expand all  rendered=81  loadMore=false`.

---

## 18. Atlas styles `.mx-dataview` as a *column* flex container

**Severity:** low, but it silently defeats a horizontal bar layout
**Phase:** 2 (TraceOps app)

Setting `display: flex` on a DataView's own class is not enough to get a row.
Atlas already declares the DataView a flex container in column direction, and a
class that only sets `display:flex` leaves that direction in place — so the top
bar's children stacked vertically and each was centred by the `align-items:
center` that was meant to centre them *vertically*:

```
$ node dom4.js
topbar dir=column align=center
statusbar dir=column
```

The children reported correct flex values and sizes, which made it look like a
working row until their x-positions were measured — all three centred on the same
axis at x≈1280 in a 2560 viewport.

**Workaround:** state the direction explicitly wherever a DataView is used as a
horizontal bar (`flex-direction: row`). Measuring `getBoundingClientRect()` on
the children is what identified it; `display` alone looked correct.

---

## 19. A DYNAMICTEXT bound to an enumeration renders the value *key*, not its caption

**Severity:** cosmetic, but it silently ships the wrong text
**Phase:** 2 (TraceOps app)

The guardrails table's "Enforced by" column bound the enum attribute directly:

```
dynamictext gEnf (Content: '{1}', ContentParams: [{1} = EnforcedBy], ...)
```

The enumeration declares captions that differ from the value names, because the
names cannot contain a space:

```
create enumeration TraceOps.Enforcement (
  cirule 'CI rule',
  review 'review',
  perfgate 'perf gate',
  blocked 'blocked'
);
```

The rendered column showed `cirule` and `perfgate` — the value names — rather
than `CI rule` and `perf gate`. Nothing warns: `mxcli check` and `mx check` both
pass, and it only shows up by reading the running page.

It went unnoticed longer than it should have because the other enums in this app
happen to have captions identical to their names (`domain`, `analytics`,
`proposed`, `accepted`), so those columns looked correct by coincidence.

**Workaround:** carry a companion label attribute and bind that instead — the
same approach already used for `Requirement.StatusLabel` and
`AgentSession.StatusLabel`:

```
EnforcedBy: enumeration(TraceOps.Enforcement) not null,
/** Caption of EnforcedBy — a bound enum renders its key, not its caption */
EnforcedLabel: string(20),
```

**Rule of thumb:** whenever an enumeration's caption differs from its value
name, do not bind the enum to a DYNAMICTEXT — bind a label attribute. Worth
checking every enum-bound text widget in an app, since the failure is invisible
for enums whose captions match their names.

---

## 20. `commit` without `refresh` updates the database but never the ListView

**Severity:** blocker — the tree's expand/collapse silently did nothing on screen
**Phase:** 2 (TraceOps app)

`ACT_ApplyTreeState` recomputes `IsVisible` for every requirement and committed
each row inside the loop:

```
    commit $Row;
  end loop;
```

That persists correctly, but never tells the client to re-query. The tree
ListView kept rendering its previous rows while the footer count — read from the
enclosing DataView, which *does* refresh when a widget microflow completes —
updated. So the list and its own row count disagreed:

```
$ node scripts/smoke-tree.js
initial              rendered= 9  footer="9 rows shown"     <- consistent
after Collapse all   rendered= 9  footer="6 rows shown"     <- list never re-queried
after Expand all     rendered= 9  footer="81 rows shown"    <- list never re-queried
```

Nothing catches this: `mxcli check` and `mx check` both pass, the microflow is
correct, and the data in Postgres is right. Only clicking the UI reveals it — and
a *static* screenshot of the initial page load looks perfect, because the first
render is a fresh query.

**Fix:** drop the per-row commit and commit the whole list once with a client
refresh, which is both cheaper and the thing that actually triggers the re-query:

```
  end loop;

  commit $All refresh;
```

After the fix, on the same script:

```
after Collapse all   rendered= 6  footer="6 rows shown"   roots: MES QMS PLM ANA PLT EDG
after expanding MES  rendered= 9  footer="9 rows shown"
after Expand all     rendered=20  footer="81 rows shown"  (20 = the PageSize cap, #17)
```

The same omission applied to `ACT_ToggleRequirement` and the three selection
microflows; all now commit with `refresh`.

**Takeaway — and the process failure worth naming:** screenshots verify
*rendering*, not *behaviour*. Every view was screenshotted and looked right, and
the bug still shipped, because no interaction was ever driven. Any state a
microflow changes needs a click-through test; `scripts/smoke-tree.js` is that
test for the tree.

---

## 21. `create microflow` is not idempotent — MDL sources must use `create or replace`

**Severity:** low, but it breaks the "re-apply from scratch" workflow
**Phase:** 2 (TraceOps app)

Re-applying an edited `mdlsource/*.mdl` fails on every flow that already exists:

```
$ ./mxcli exec mdlsource/05-microflows.mdl -p TraceOps.mpr
Error: microflow 'TraceOps.DS_AppState' already exists (use create or modify to overwrite)
```

Pages and snippets were already written as `create or replace`, but the
microflow files were not, so only the pages could be re-applied. All 43
microflow definitions are now `create or replace`.

`alter entity … add attribute` has the same problem with no `or replace` form
(`Error: attribute 'IsSelected' already exists`), so schema additions still have
to be applied once, or the file split at its first microflow.

**Not a defect — corrected 2026-07-30.** The maintainer's position is that a plain
`create` refusing to overwrite is intentional and SQL-shaped, and re-testing bears
that out: the documented idempotent forms exist and I simply was not using them.

```
$ mxcli exec mf.mdl -p proj.mpr          # second run
Error: microflow 'TraceOps.ZZ_V21' already exists (use create or modify to overwrite)

$ mxcli exec a2.mdl -p proj.mpr          # `add attribute if not exists`, twice
Attribute 'ZZV21' already exists on entity TraceOps.Requirement — skipped
Attribute 'ZZV21' already exists on entity TraceOps.Requirement — skipped
```

`ADD ATTRIBUTE IF NOT EXISTS` is documented (`mxcli syntax
domain-model.entity.alter` lists it under "idempotent") and works on **released**
mxcli, not just PR #58 — so this was never a defect at all, in either half.

**And the refusal is protective, not merely conservative.** `create or modify` on
an entity replaces the whole definition and drops anything it omits — verified:

```
$ mxcli -p proj.mpr -c "DESCRIBE ENTITY TraceOps.ZZPrune"   # after adding C
  A: String(10), B: String(10), C: String(10)
# re-apply the original two-attribute `create or modify` definition
  A: String(10), B: String(10)                              # C is gone
```

mxcli's own error says exactly this, which is a better diagnostic than most:

```
Error: entity already exists: TraceOps.ZZEnt2 — to add or change a member use
'alter entity ... add attribute ...' (leaves the rest intact); use 'create or
modify entity' only to replace the whole definition (it drops any attribute this
statement omits)
```

That matters here: `01-domain-model.mdl` defines `Requirement`, and files 17 and 21
add columns to it afterwards. Blanket-converting 01 to `create or modify` would
silently delete those columns on every re-apply. So plain `create` is right.

**What this cost me, and what it fixed.** Acting on this exposed that *four* source
files could not be re-applied, not the two I had assumed — `06`, `12`, `17` and
`21`, the last two of which are mine. All four now use `add attribute if not
exists` (plus `create or modify enumeration` in 21) and survive repeated
application with nothing pruned. The domain model is deliberately left alone.

---

## 22. Mendix has no integer division, and no way to get an Integer back from one

**Severity:** high — it blocks a whole class of arithmetic
**Phase:** 3 (CRUD)

The coverage bars are quantised to a 0–20 bucket, which is `value * 20 / leaves`.
Assigning that to an Integer attribute fails:

```
$ ~/.mxcli/mxbuild/11.12.1/modeler/mx check TraceOps.mpr
CE0117: Change 'Requirement': The value of type 'Decimal/Currency' cannot be
        used for the member 'VerifiedBucket' of type 'Integer'.
```

`Integer / Integer` is a **Decimal** in Mendix, and there is no Decimal→Integer
conversion function. Narrowing it down empirically, each as a single `change`
against an Integer attribute:

| Expression | Result |
| --- | --- |
| `20` | passes |
| `$SomeInteger` | passes |
| `$Req/RollVerified` | passes |
| `$Req/RollVerified * 20` | passes |
| `$Req/RollVerified * 20 / $Leaves` | **CE0117** |
| `round($Req/RollVerified * 20 / $Leaves)` | **CE0117** |
| `round($Req/RollVerified * 20 / $Leaves, 0)` | **CE0117** |
| `floor(...)` / `trunc(...)` / `ceil(...)` | **CE0117** |

So multiplication is closed over Integer but division is not, and every rounding
function returns Decimal too — they round the *value*, not the *type*. There is no
`toInteger()`; `toString()` + `parseInteger()` is not available in microflow
expressions either.

**Workaround —** do the division yourself, by repeated addition:

```
create or replace microflow TraceOps.ACT_IntDiv ($Numerator: Integer, $Denominator: Integer)
returns Integer as $Result
begin
  declare $Result Integer = 0;
  declare $Acc Integer = 0;
  if $Denominator <= 0 then
    return $Result;
  end if;
  set $Acc = $Denominator;
  while $Acc <= $Numerator
  begin
    set $Result = $Result + 1;
    set $Acc = $Acc + $Denominator;
  end while;
  return $Result;
end;
```

That is floor division; for round-to-nearest, call it with `(2n + d)` over `2d`:

```
  $VerifiedB = call microflow TraceOps.ACT_IntDiv (
    Numerator = $Requirement/RollVerified * 40 + $Leaves, Denominator = $Leaves * 2);
```

The loop is bounded by the quotient, which here is at most 100, so the cost is
irrelevant — but it is a microflow call per division, and a real product doing
this at scale would want a Java action instead.

**Related trap:** `$X = call microflow …` *declares* `$X`. Writing the natural

```
  declare $VerifiedB Integer = 0;
  $VerifiedB = call microflow TraceOps.ACT_IntDiv (...);
```

fails with `CE0111: The variable 'VerifiedB' already exists`. Drop the `declare`.

---

## 23. `combobox` cannot bind an association, only an attribute

**Severity:** medium
**Phase:** 3 (CRUD)

The obvious way to let a user re-parent a requirement is a reference selector on
`Requirement_Parent`. MDL's `combobox` will not do it:

```
combobox edParent (Label: 'Parent', Association: TraceOps.Requirement_Parent, ...)
→ CE0642: Combo box 'edParent': An attribute must be selected.
```

`Attribute:` is mandatory. Note *where* this fails, which the re-test pinned down
more precisely than the original write-up: the grammar **accepts**
`Association: …` — `mxcli check` passes — and the writer then drops it silently,
so the round-trip comes back bare and only MxBuild objects:

```
$ mxcli -p proj.mpr -c "DESCRIBE PAGE TraceOps.ZZ_Probe23"
    combobox cbParent (Label: 'Parent')        <- the Association is gone

$ mx check proj.mpr
[error] [CE0642] "Property 'Attribute' is required." at Combo box 'cbParent'
```

That puts it in the same family as #9, #10 and #17: a property the parser takes
and the writer discards. `referenceselector` is not a recognised widget type at
all, so the Atlas Combobox's association mode stays unreachable from MDL.

**Workaround —** carry the parent's business key in a plain attribute, and
resolve it to the association in the save microflow:

```
alter entity TraceOps.Requirement add ParentReqId: String(60);
...
  retrieve $Parent from TraceOps.Requirement where [ReqId = $Requirement/ParentReqId] limit 1;
  set $Requirement/TraceOps.Requirement_Parent = $Parent;
```

which turns out to be worth doing anyway: it is the natural place for the "no
such id", "cannot be its own parent" and cycle checks that a reference selector
would not have given.

**FIXED by mxcli PR #58** (`ako/mxcli`, verified on a local build of the PR, `nightly-71-g240e7d2c`, 2026-07-30). A combobox binds an association and builds with 0 errors. Association mode needs three properties, not one — `Association:`, `datasource:` (the option list) and `CaptionAttribute:` — and the new MDL-WIDGET16 check flags an incomplete one at check time rather than letting it reach MxBuild. My original probe supplied only `Association:`, so it was testing the incomplete form and wrongly read as unfixed.

---

## 24. Required-attribute validation fires on assignment, not on commit

**Severity:** high — the symptom points at entirely the wrong place
**Phase:** 3 (CRUD)

`+ New requirement` produced a red error dialog instead of the editor:

```
Title has an issue: Title is required
```

The obvious reading is that something committed the half-built object, so the
first fix attempt was to defer every commit in the create flow — which changed
nothing. `mxcli`'s own output confirmed there was no commit to defer:

```
$ ./mxcli -p TraceOps.mpr -c "DESCRIBE MICROFLOW TraceOps.ACT_NewRequirement"
  ... CreateObject  Commit: CommitTypeNo
```

The actual cause: `Title: String(300) not null error 'Title is required'` compiles
to a *required* member, and Mendix raises that validation the moment an empty
value is assigned — inside `create`, before any commit and before the page opens.
An omitted attribute and an explicitly-empty one behave identically.

**Fix —** give the draft a real placeholder value:

```
  $New = create TraceOps.Requirement (
    ReqId = 'NEW-' + toString($Next),
    Title = 'New requirement',      -- not '' — see above
    ...
  );
```

**Takeaway:** `not null` on an entity attribute is not a save-time constraint, so
any "create blank, let the user fill it in" page needs placeholder values for
every required attribute. Nothing in `mxcli check`, `mx check` or `lint` flags
this; it only appears at runtime, as an error that names the commit path.

---

## 25. A Mendix pop-up page is `.mx-window`, and only its content div is "visible"

**Severity:** low — test-harness sharp edge, not an mxcli bug
**Phase:** 3 (CRUD)

Worth recording because it cost a full debugging cycle. Driving the editor from
Playwright against `.mx-dialog` timed out:

```
page.waitForSelector: Timeout 20000ms exceeded.
  - waiting for locator('.mx-dialog') to be visible
```

`.mx-dialog` is the *error/confirmation* dialog. A pop-up **page** is
`div.modal-dialog.mx-window`, and that element is `position: fixed` with no
offsetParent, so Playwright's visibility check fails on it even when the pop-up is
plainly on screen. The child `.modal-content.mx-window-content` is the one that
tests visible.

```js
const DLG = '.mx-window-content';          // the pop-up page
const isError = '.mx-dialog-error';        // a runtime error dialog
```

Fields inside it render as `.mx-name-<widgetName>.form-group`, each wrapping its
own `<label>` and input, so targeting by widget name is stabler than by label
text — and note the Atlas Combobox is a pluggable widget rendering an `<input>`,
not a `<select>`, so `selectOption` does not work on it.

---

## 26. The denormalised-selection workaround bit back: delete took the selected row too

**Severity:** high — silent data loss
**Phase:** 3 (CRUD)

Not an mxcli bug, but a direct consequence of the workaround in #14, and worth
recording because the failure was invisible at the point of the mistake.

MDL microflows cannot recurse, so deleting a subtree is a mark-then-sweep: flag
the node, flag flagged nodes' children eight times, then delete flagged rows
deepest-first. The flag needs a boolean on `Requirement` — and there was already
one, `IsSelected`, added in #14 to denormalise the tree's row selection onto the
rows themselves. Reusing it looked free.

It is not. `IsSelected` is *true on whatever row the user has selected*, so the
sweep deleted the requested subtree **and the selected requirement's subtree**.
The traceability page selects a row by default, so this fired on the very first
delete: `PLM` and its nine descendants disappeared while the test was deleting
`REQ-SMOKE-1`.

```
$ sudo -u postgres psql -d traceops -c 'SELECT count(*) FROM "traceops$requirement";'
 count
-------
    71        -- was 81
```

Every assertion in `smoke-crud.js` still passed. It checked that the new row was
gone and that `MES`'s rollups came back to their original values, and both were
true — the damage was to a *different* branch, which nothing looked at.

**Fix —** a scratch attribute that exists for nothing else, plus a defensive clear
of stale marks at the start:

```
alter entity TraceOps.Requirement add attribute IsMarked: boolean default false;
```

and the assertion that would have caught it, now in the test:

```js
check('delete removed nothing else', after.join(' ') === before.join(' '));
```

**Takeaway:** a denormalised flag is part of the UI's state, not scratch space.
And #20's lesson generalises — it is not enough to assert that the thing you
changed changed; assert that nothing else did.

---

## 27. A doc comment between `add attribute` clauses is a syntax error — and it shipped

**Severity:** medium — it silently broke the repo's "re-apply from scratch" claim
**Phase:** 4 (live counters)

`/** … */` doc comments are accepted before a statement and between attributes
*inside* `create entity`, so putting one between two `add attribute` clauses of an
`alter entity` looks obviously fine. It is not:

```
$ mxcli check t1.mdl
alter entity TraceOps.ValidationItem
  add attribute Zz1: string(10)
  /** doc comment between add clauses */
  add attribute Zz2: string(10);
→ line 4:2 no viable alternative at input '/** doc comment between add clauses */add'
```

Isolated against a control: the same file with the comment removed, and one with an
enum default in the same position, both pass. It is the comment placement alone.

**How it shipped.** `17-crud-domain.mdl` was committed in exactly this state. The
attributes were all *in* the project, because each had been applied individually —
by `-c "ALTER ENTITY …"`, or before the comments were written — so every downstream
check was green. The file itself had not been parsed as a whole since the comments
went in:

```
$ mxcli check mdlsource/17-crud-domain.mdl
  - line 26:2 no viable alternative at input '/**\n * The parent, as the parent's ReqId …'
```

Nothing catches this. `mx check` validates the *project*, `lint` validates the
project, and the app built and ran perfectly. Only re-applying the source from
scratch — the thing the repo claims you can do — would have failed.

**Fix:** `--` line comments inside `alter entity`, and a guard so it cannot recur:

```
$ bash scripts/check-mdl.sh
ok    mdlsource/01-domain-model.mdl
...
24 file(s) checked, 0 failed
```

**Takeaway:** "the model is correct" and "the sources that produce the model are
correct" are different claims, and only the first one has a tool pointed at it by
default. If the source of truth is a directory of scripts, something has to check
the directory.

**Second-order trap while writing this up:** the fix comment itself contained the
character sequence that ends a doc comment, which terminated the block early and
produced a fresh wall of parse errors. Don't quote comment delimiters inside a doc
comment.

**FIXED by mxcli PR #58** (`ako/mxcli`, verified on a local build of the PR, `nightly-71-g240e7d2c`, 2026-07-30). A doc comment between `add attribute` clauses now parses.

---

## 28. `count()` is an activity, not an expression — and it declares its own variable

**Severity:** low — caught pre-build, unlike #22
**Phase:** 4 (live counters)

Aggregates read like functions and are not. Using one inline in a `change`:

```
change $State (ReqCount = count($All), GapNoImpl = count($NoImpl), …);
```

`mxcli check` rejects it with a precise diagnosis, which is a real improvement over
finding out at MxBuild:

```
✗ change 'State' attribute 'GuardrailViolations' calls 'count()', which is not a
  Mendix expression function — the build fails CE0117 "Error(s) in expression" [MDL044]
  → 'count' is an aggregate activity, not an expression function. Assign it to a
    variable first: $n = count($List); then use $n in the expression.
```

So every count needs its own variable. The follow-on trap: `set $n = count($List)`
**declares** `$n`, exactly like `$x = call microflow …` in #22, so pre-declaring it
is an error:

```
  declare $RelN Integer = 0;
  set $RelN = count($Releases);
→ duplicate variable name '$RelN' — aggregate list output variable is already
  declared in this scope (CE0111)
```

Useful counterpart to #22: `count()` returns an **Integer**, so counts are safe to
assign to Integer attributes. `sum()` returns a Decimal and hits the no-conversion
wall, so sums into Integer attributes still need an accumulator loop.

**Not a defect — confirmed 2026-07-30.** Requiring an aggregate to land in its own
variable is a Mendix platform rule, not an mxcli limitation; `$n = count($List)`
has always been the correct form and passes. What mxcli contributes is MDL044,
which catches the inline form at check time with an actionable message instead of
letting it reach MxBuild as a bare CE0117 — which is the good outcome, not a
remaining bug. This entry stays as a note about the *rule*, not as an open defect.

---

## 29. A DataView's edit is uncommitted, so a microflow that re-fetches the object cannot see it

**Severity:** high — the feature appears completely inert, with no error anywhere
**Phase:** 4 (live counters)

The new search box did nothing. Not "wrong results" — nothing: type, press Enter,
tree unchanged. No client error, no runtime error, `mx check` clean, and the
`OnChange` was demonstrably persisted on the widget:

```
$ mxcli -p TraceOps.mpr -c "DESCRIBE PAGE TraceOps.Traceability"
  textbox searchField (
    Attribute: SearchText,
    OnChange: microflow TraceOps.ACT_ApplySearch,
```

The input really did hold the text — checked in the DOM — and the DataView was
editable, not read-only:

```json
{"value": "trace", "dvCls": "mx-dataview mx-name-dvState …", "dvReadOnly": false}
```

But the database did not:

```
$ psql -c "SELECT '['||coalesce(searchtext,'NULL')||']' FROM \"traceops$appstate\";"
 []
```

**Cause.** The flow fetched its own copy of the object:

```
create or replace microflow TraceOps.ACT_ApplySearch ()
begin
  $State = call microflow TraceOps.DS_AppState ();   -- retrieves from the DATABASE
```

A DataView holds edits **uncommitted** until something commits them. `DS_AppState`
does a database retrieve, so the flow read the last *committed* value — an empty
string — while the field on screen plainly held the text. Every part worked; they
just weren't looking at the same object.

**Fix:** take the object as a parameter, from the DataView, and commit it.

```
create or replace microflow TraceOps.ACT_ApplySearch ($State: TraceOps.AppState)
begin
  commit $State;
  ...
```

with the page passing `$currentObject`:

```
OnChange: microflow TraceOps.ACT_ApplySearch(State: $currentObject),
```

**Takeaway:** any flow triggered by an input widget must be handed the edited
object. A convenience "get the state" datasource microflow is the wrong thing to
call from a widget action, because it re-reads what is on disk rather than what is
on screen. The mirror image of #20: there, a commit without `refresh` meant the
*client* never saw the server's change; here, a re-fetch meant the *server* never
saw the client's.

---

## 30. Two false-passing tests, both hidden by the PageSize cap

**Severity:** methodology — worth more than the bugs it hid
**Phase:** 4 (live counters)

The search assertions passed while the search was completely inert (#29):

```
PASS  search narrows the tree  — 20 rows: MES MES-1 MES-1-1 REQ-MES-1-1-1 …
PASS  every visible row is a match or an ancestor of one  — 1 direct match(es) of 20 rows
```

`20 < 81`, so "narrows the tree" was satisfied — by the ListView's 20-row page cap
(#17), not by the feature. The second check was written loosely enough
(`titles.length >= hits.length`) to be true of any tree at all. Two green lines,
zero working search. A third check failed only because 20 → 20 gave nothing to
compare.

The same cap then produced the opposite error, a genuine feature failing its test:
`the accepted requirement is verified in the tree — status="null"` — the row was
past row 20 and simply not in the DOM. The data was right the whole time.

**Fixes, in the test:**

- collapse the tree first, so the visible set is small and exact — the assertion
  became `searchRows.join(' ') === 'MES MES-2'`, which only a working search can
  satisfy;
- reach a deep row by searching for it rather than by expanding everything.

**Takeaway:** an assertion that a number got *smaller*, or that a list is
*non-empty*, will be satisfied by a platform quirk sooner or later. Assert the
exact expected set. And when a test and a feature disagree, the test is a suspect
too — here it was the culprit twice and the victim once.

---

## 31. What a view entity actually is — and the "read-only" mistake

**Severity:** high — I gave wrong architectural advice from this misunderstanding
**Phase:** 5 (large-app analysis)

I described view entities as "read-only", which is wrong in the way that matters
and led me to rule them out for editable screens. The accurate model:

| | View entity |
| --- | --- |
| Storage | **None.** Not a table, and *not* a database view either |
| Rows | Materialised per query by the runtime, from OQL |
| In memory | Behave like a **non-persistent** object — attributes can be changed |
| Persisting | `commit` does not write back; you write through the source entity |

The "not a database view" part is easy to assume wrong. After deploying an app
with two view entities, Postgres has no view objects at all:

```
$ psql -d traceops_vwtest -c "\dv"
Did not find any relations.
```

The runtime translates the OQL and issues it per query instead. That has a
practical consequence: **you cannot verify a view entity by inspecting the
schema.** It has to be exercised at runtime, which is how #33 was checked.

**The correction that matters:** a view row is editable in memory. This builds
with 0 errors:

```
create or replace microflow TraceOps.ZZ_ViewWriteBack ($Row: TraceOps.VW_ReqSummary)
begin
  change $Row (OwnerName = 'M. Koelewijn');        -- in-memory, like a non-persistent
  retrieve $Real from TraceOps.Requirement where [ReqId = $Row/ReqId] limit 1;
  change $Real (OwnerName = $Row/OwnerName);
  commit $Real;                                     -- write through the source entity
end;
```

So a view entity is a legitimate backing for an *editable* screen, not only a
read-only report. See #34 for what that enables.

**Gotcha when generating one:** the declared attribute type must match the source
column exactly. `OwnerName: String(60)` against a `String(100)` source gave:

```
[error] [CE6770] "View Entity is out of sync with the OQL Query." at Entity 'TraceOps.VW_ReqSummary'
```

Widening to `String(100)` cleared it. Useful corollary: mxbuild genuinely
type-checks the OQL, so a clean build is real evidence, not just a syntax pass.

**Takeaway:** "read-only" conflated three separate things — no storage, no
write-back on commit, and immutability. Only the first two are true.

---

## 32. Mendix OQL has no CTEs, but inline views make that a non-limitation

**Severity:** medium — I overstated a limitation and narrowed good advice
**Phase:** 5 (large-app analysis)

I recorded "no recursive CTEs and no window functions" and then let it imply that
multi-step queries were out of reach, so a view entity could not replace anything
complicated. That inference was wrong: **a non-recursive CTE is only syntactic
sugar for an inline view (a derived table in `FROM`), and Mendix OQL supports
inline views.**

Verified — this parses, applies and builds at **0 errors**, aggregate and outer
join included:

```sql
create or modify view entity TraceOps.VW_Inline (ReqId: string(60), LinkCount: integer) as (
  select t.ReqId as ReqId, t.LinkCount as LinkCount
  from (
    select r.ReqId as ReqId, count(gl.ID) as LinkCount
    from TraceOps.Requirement as r
    left outer join TraceOps.GuardrailLink_Requirement/TraceOps.GuardrailLink as gl
    group by r.ReqId
  ) as t
);
```

What is genuinely missing, re-checked on `nightly-93-gb344f999`:

| Construct | Result |
| --- | --- |
| Inline view / derived table | **works** |
| `WITH` (non-recursive) | not in the grammar — **but equivalent to the above, so nothing is lost** |
| `WITH RECURSIVE` | `mismatched input 'with'` — a real gap; recursion is not sugar |
| `row_number() over (…)` | `extraneous input 'over'` — a real gap |

So the exclusion list for "could this be a view entity?" is small: genuine
unbounded recursion, and ranking/windowing. Everything else — aggregate-then-join,
filter-then-join, multi-step shaping — is expressible today. Even recursion is
expressible at a *bounded* depth by unrolling into N self-joins, verbosely.

**Takeaway:** check whether a missing feature is sugar before treating it as a
capability gap. I let one grammar rejection rule out an entire class of designs.

---

## 33. Pushdown is the real argument for view entities — measured, not assumed

**Severity:** high — this is the whole performance case, and it is verifiable
**Phase:** 5 (large-app analysis)

The reason a datasource microflow hurts at scale is that filtering, sorting and
paging happen *after* the data reaches the runtime: the microflow returns the
whole set, the widget shows 20 rows, and the rest becomes browser state. A view
entity is queried like a table, so the database does that work.

That is a claim worth measuring rather than repeating. With Postgres statement
logging on, rendering a ListView over `VW_Inline` constrained to `LinkCount > 0`,
sorted by `ReqId`, produced exactly **one** statement:

```sql
SELECT "VW_Inline"."ReqId", "VW_Inline"."LinkCount"
FROM ( SELECT "t"."ReqId", "t"."LinkCount" FROM (
         SELECT "r"."reqid" AS "ReqId", COUNT("gl"."id") AS "LinkCount"
         FROM "traceops$requirement" "r"
         LEFT OUTER JOIN "traceops$guardraillink" "gl"
           ON "gl"."traceops$guardraillink_requirement" = "r"."id"
         GROUP BY "r"."reqid" ) "t" ) "VW_Inline"
WHERE "VW_Inline"."LinkCount" > $1
ORDER BY "VW_Inline"."ReqId" ASC
LIMIT $2
```

Three things this proves:

1. The inline view survives into SQL as a nested derived table — the aggregate is
   computed **in the database**.
2. `WHERE` on `LinkCount` is pushed down **even though that column exists on no
   table**. Constraining on a computed/aggregated column is exactly what a
   datasource microflow cannot do.
3. `ORDER BY` and `LIMIT` are pushed down, so unshown rows never leave the
   database — the browser-state problem solved at source.

Correctness was checked too, not just shape: every rendered row was diffed against
the equivalent SQL aggregate.

```
view rows=68  sql rows=68
view sum=91   sql sum=91
EXACT MATCH — every row and count identical
```

This also fixes the "grid with associated columns" pattern: one query replaces one
query per associated entity per page of rows.

**Method note:** because a view entity is not a database object (#31), none of
this is visible in the schema. Statement logging (`ALTER SYSTEM SET
log_statement='all'` + `pg_reload_conf()`, reset afterwards) is the way to see
what the runtime really issued. Worth keeping in the toolkit for any "is this
query doing what I think?" question.

---

## 34. One view-entity object can front an edit form over several records

**Severity:** medium — a design option I had ruled out
**Phase:** 5 (large-app analysis)

Following from #31: because a view row is editable in memory and written back
explicitly, a *single* view object can represent a join across several persistent
records, and one form can edit all of them.

Verified at build level — a view whose row spans a requirement and its parent:

```sql
create or modify view entity TraceOps.VW_ReqPair (
  ChildReqId: string(60),  ChildOwner: string(100),
  ParentReqId: string(60), ParentOwner: string(100)
) as (
  select c.ReqId as ChildReqId, c.OwnerName as ChildOwner,
         p.ReqId as ParentReqId, p.OwnerName as ParentOwner
  from TraceOps.Requirement as c
  inner join TraceOps.Requirement_Parent/TraceOps.Requirement as p
);
```

with one save flow writing back to both records — `mx check`: **0 errors**:

```
retrieve $Child  ... where [ReqId = $Pair/ChildReqId]  limit 1; change; commit;
retrieve $Parent ... where [ReqId = $Pair/ParentReqId] limit 1; change; commit;
```

Why this is worth knowing: the usual alternative is a non-persistent "form" entity
plus a microflow that populates it from several sources and another that fans the
values back out. The view entity replaces the populate step with one database
query that already does the join — less code, and the read is pushed down (#33).

**Constraints to respect:**

- The write-back flow is the *only* thing that persists. `commit` on the view row
  does nothing, so a form that forgets the save flow silently discards edits —
  the failure is quiet, which makes it worth a test rather than a review.
- Validation belongs in the write-back flow, not on the view entity.
- Concurrency is on you: the row was read at query time and written later, with no
  optimistic locking. For contended records, re-read and compare before writing.

**Not yet verified:** I checked this to `mx check`, not through a rendered form
with a real user edit. The in-memory editability behind it *is* runtime-verified
(#31), but the multi-record form itself is a build-level result only.

---

## 35. Catalog and lint gaps that block detecting the real performance anti-patterns

**Severity:** medium — the analysis is possible, the tooling just cannot express it
**Phase:** 5 (large-app analysis)
**Status:** gap 3 **fixed** on `claude/mxbuild-diagnostics-spike-emta6h` (`babc41a9`);
gaps 1, 2 and 4 unchanged. Gap 2 was never a defect — see the table below.

**Update — gap 3 is closed, and the rule it blocked now works.** `Widget` carries
`MicroflowRef`/`NanoflowRef` through the projection and Starlark exposes
`microflow_ref` / `nanoflow_ref`. `TraceOps/.claude/lint-rules/perf001_microflow_datasource.star`
is the rule that returned zero hits at any threshold before; on the fixed build it
finds all 10 microflow-datasource ListViews in this app:

```
$ mxcli lint -p TraceOps.mpr        # fixed build
  ⚠ ListView 'lvTests' on TraceOps.ValidationQueue takes its data from microflow
    'TraceOps.DS_ValTests' — no database pushdown, so search, sort and paging
    happen in memory over the full result set. [PERF001]
  … 10 findings

$ mxcli lint -p TraceOps.mpr        # stock nightly-93, same rule, same project
  ✗ Starlark rule error: "widget" struct has no .microflow_ref attribute [PERF001]
```

That the old build *errors* rather than silently reporting nothing is worth noting:
it is the loud failure mode, not the quiet one. The rule guards on
`getattr(w, "microflow_ref", None)` so it degrades to one explanatory finding on
older builds instead of breaking every lint run.

The two data-retrieval problems that dominate real Mendix performance work are:

1. **A grid with columns over associations** — each association becomes a separate
   query, so one table renders as many queries.
2. **A microflow datasource** — filters, sorting and paging are not pushed to the
   database, so more rows are returned than are displayed, and the surplus sits in
   browser state.

Both are model-visible in principle. Neither is fully detectable with today's
catalog and lint API. What I found probing it:

**Gap 1 — grid columns are absent from the catalog.** A datagrid with three
columns, two of them over an association, produces exactly **one** widget row,
with no columns and an empty `AttributeRef`:

```
| Name    | WidgetType                              | EntityRef              | AttributeRef |
| dgLinks | com.mendix.widget.web.datagrid.Datagrid | TraceOps.GuardrailLink |              |
```

But the model reader sees them perfectly — `DESCRIBE PAGE` round-trips the
association paths:

```
column "GuardrailLink_Requirement/ReqId"     (Attribute: GuardrailLink_Requirement/ReqId)
column "GuardrailLink_Requirement/OwnerName" (Attribute: GuardrailLink_Requirement/OwnerName)
```

So this is a **catalog** gap, not a reader gap — the fix is to emit a row per grid
column with its attribute path. Then anti-pattern 1 is a one-line query: count
columns whose `AttributeRef` contains `/`, grouped by grid.

**Gap 2 — `REFS` conflates a datasource with an action.** Every `datasource` ref
targets an ENTITY (37 of them; none to a microflow). A page→microflow reference is
always `RefKind = 'action'` (51), whether it is a DataView's datasource or a
button's click handler. `CATALOG.WIDGETS` *does* record it correctly —
`MicroflowRef` is populated for `Forms$ListView` and the pluggable Datagrid alike,
and is distinguishable from `Forms$ActionButton` — so anti-pattern 2 **is**
detectable in catalog SQL today.

**Gap 3 — the Starlark projection drops what the rule needs.** The widget struct
omits the one field that would disambiguate, though the catalog table has it:

```go
// mdl/linter/starlark.go — widgetToStarlark
"widget_type", "container_qualified_name", "entity_ref", "attribute_ref"
// no microflow_ref / nanoflow_ref
```

A prototype rule keyed on `refs_to(mf, "datasource")` therefore returned zero
hits at *any* threshold. Bisecting confirmed the rest of the API is fine —
`violation()`, `microflows()` (77) and `activities_for()` (1628 activities) all
work; only the datasource link is missing.

**Gap 4 — activities are flat.** The Starlark activity struct has no sequence,
parent or depth, so a custom rule can say "this microflow contains a loop *and* a
retrieve" but not "this retrieve is *inside* that loop". The built-in Go rule
CONV011 gets it right because Go rules get the real AST via `ctx.FullMicroflow()`
and recurse through `LoopedActivity.ObjectCollection`.

**Where each rule can live today:**

| Anti-pattern | Go built-in | Catalog SQL | Starlark |
| --- | --- | --- | --- |
| Association columns → query fan-out | yes | **no** (gap 1) | no |
| Microflow datasource without pushdown | yes | **yes** | **yes** (gap 3 fixed) |
| Retrieve/commit nested in a loop | **yes** (CONV011 does commits) | no | no (gap 4) |
| Unconstrained retrieve on a large entity | yes | yes | **yes** |

**Suggested changes, smallest first:**

1. ~~Add `microflow_ref` / `nanoflow_ref` to `widgetToStarlark`~~ — **done** in
   `babc41a9`; anti-pattern 2 is now detectable from a custom rule (PERF001 above).
2. Emit grid columns into `CATALOG.WIDGETS` with their attribute paths — the
   reader already parses them; this unblocks anti-pattern 1 for everyone.
3. Add `sequence`/parent to the activity struct, or accept that nesting-aware rules
   are Go-only.

**On the suggestion side**, `violation()` already carries a `Suggestion` field
(CONV011: "Move the commit outside the loop, or collect objects in a list and
commit once after the loop"), so "here is the better approach" is first-class. And
a view-entity suggestion can be *specific* rather than generic: the catalog knows
the target entity and the XPath, so a rule can emit skeleton OQL — provided it
respects the real limits (#32: no recursion, no windowing; #31: match the source
attribute types; and skip any flow that also writes, which the activity list shows).

**Takeaway:** the blocker is not analysis capability — the model has everything.
It is that two small projections drop fields the detectors need, and the tier with
full access (Go) is the one custom rules cannot reach.

---

## 36. `mxcli oql` cannot reach a `mxcli run --local` app — the runtime is booted without the live-preview dev flags

**Severity:** the documented verification tool is unusable from the documented dev loop
**Phase:** 8 (large-app analysis)
**Status:** **FIXED** on `claude/mxbuild-diagnostics-spike-emta6h` (`48c7d9af`).
All three parts — the boot flags, the password, and the misleading hint — were
addressed. Re-test at the end of this entry.

`mxcli oql` is how the toolchain says to verify data — there is a whole
`verify-with-oql` skill for it. `mxcli run --local` is how the same toolchain says
to run the app during development. The two do not meet: against a `--local` app,
every OQL query fails.

Reproduced end to end this session. Two hurdles, in order.

**Hurdle 1 — the admin password is undiscoverable.**

```
$ mxcli oql -p TraceOps.mpr "SELECT r.ReqId FROM TraceOps.Requirement AS r LIMIT 1"
Error: admin password required: set --token, M2EE_ADMIN_PASS env var, or configure .docker/.env
```

`resolveM2EEDefaults` resolves the token from `--token` > `M2EE_ADMIN_PASS` >
`.docker/.env` (`cmd/mxcli/docker/m2ee.go:334`). A local run has no `.docker/`, and
`mxcli run --local` never prints or writes the password it used. It is a constant
in the source:

```go
// cmd/mxcli/docker/runlocal.go:131
const defaultLocalAdminPass = "mxcli-local-dev"
```

so `export M2EE_ADMIN_PASS='mxcli-local-dev'` gets past this — but only if you read
mxcli's source to find it.

**Hurdle 2 — the endpoint is not mounted.** With the password set:

```
$ export M2EE_ADMIN_PASS='mxcli-local-dev'
$ mxcli oql -p TraceOps.mpr "SELECT r.ReqId FROM TraceOps.Requirement AS r LIMIT 3"
Error: OQL error: Action not found. -- the running app does not expose the OQL preview
endpoint. If your .docker/ predates this fix, regenerate it with `mxcli docker init
--force`, then `mxcli docker build && mxcli docker up` (this starts the runtime with
the live-preview dev flags)
```

The error is accurate about the cause and useless about the cure: it only tells
docker users what to do. There is no `--local` equivalent, and `mxcli run --help`
lists no flag that would enable it.

**Root cause.** The Mendix runtime mounts `/dev/preview_execute_oql` only when two
JVM system properties are set. Docker mode passes them:

```yaml
# cmd/mxcli/docker/templates/docker-compose.yml:16
command: ["./bin/start", "-J", "-Dmendix.live-preview=enabled",
                        "-J", "-Dmendix.running.locally.by.studiopro=true"]
```

The local boot path does not:

```go
// cmd/mxcli/docker/localboot.go:380 — spawnAndConfigure
cmd := exec.Command(javaExe, "-jar", rt.opts.launcherJar(), rt.opts.DeployDir)
```

**Proof, both directions.** The flags can be smuggled in through
`JAVA_TOOL_OPTIONS`, which the JVM honours and mxcli passes through (it only
rewrites that variable under `--trace`). Same app, same database, same query — the
only difference is the two properties:

```
$ export JAVA_TOOL_OPTIONS='-Dmendix.live-preview=enabled -Dmendix.running.locally.by.studiopro=true'
$ mxcli run --local -p TraceOps.mpr --db-name traceops_oqltest &
$ export M2EE_ADMIN_PASS='mxcli-local-dev'
$ mxcli oql -p TraceOps.mpr "SELECT r.ReqId, r.Title FROM TraceOps.Requirement AS r LIMIT 5"
| Title                                          | ReqId   |
|------------------------------------------------|---------|
| OEE definition configurable per plant          | ANA-2-2 |
| Non-conformance workflow                       | QMS-3   |
...
(5 rows)

$ # restart with the ambient JAVA_TOOL_OPTIONS, nothing else changed:
$ mxcli oql -p TraceOps.mpr "SELECT r.ReqId FROM TraceOps.Requirement AS r LIMIT 3"
Error: OQL error: Action not found. -- ...
```

View entities work too, which is the point — this is exactly the verification
#31–#34 needed:

```
$ mxcli oql -p TraceOps.mpr \
    "SELECT v.ReqId, v.LinkCount FROM TraceOps.VW_Inline AS v WHERE v.LinkCount > 0 ORDER BY v.LinkCount DESC LIMIT 6"
| LinkCount | ReqId         | ID                |
|-----------|---------------|-------------------|
| 2         | REQ-MES-1-1-2 | 14355223812243457 |
...
(6 rows)
```

**Fix, verified.** Two lines in `spawnAndConfigure`:

```diff
--- a/cmd/mxcli/docker/localboot.go
+++ b/cmd/mxcli/docker/localboot.go
@@ func (rt *LocalRuntime) spawnAndConfigure() error {
 	javaExe := filepath.Join(rt.opts.JavaHome, "bin", "java")
-	cmd := exec.Command(javaExe, "-jar", rt.opts.launcherJar(), rt.opts.DeployDir)
+	cmd := exec.Command(javaExe,
+		"-Dmendix.live-preview=enabled",
+		"-Dmendix.running.locally.by.studiopro=true",
+		"-jar", rt.opts.launcherJar(), rt.opts.DeployDir)
```

Built and run: `go build -o mxcli-patched ./cmd/mxcli`, then
`mxcli-patched run --local -p TraceOps.mpr`. The app serves normally (HTTP 200) and
the *stock* `mxcli oql` binary queries it, including view entities, with no
`--direct` and no `JAVA_TOOL_OPTIONS`. The JVM command line confirms the properties
are attached. `run --local` is a development loop that already forces `DTAPMode=D`,
so always-on matches what docker mode does; an opt-out flag would only be needed if
someone wants `--local` to model a production boot.

**Two smaller things worth fixing alongside:**

- `mxcli run --local` should print or write the admin password (or `mxcli oql`
  should default to `defaultLocalAdminPass` when the target is a local run). Right
  now the only way to find it is to read `runlocal.go`.
- The "Action not found" hint should branch: the docker instructions are wrong
  advice for a `--local` user, and a stale `.docker/docker-compose.yml` in the
  project directory additionally makes `mxcli oql` route through
  `docker compose exec` unless `--direct` is passed
  (`cmd/mxcli/docker/m2ee.go:227`), even when the app is running locally.

**What this cost.** In the #31–#34 work I fell back to building a page over the
view entity, scraping it with Playwright, and turning on Postgres `log_statement`
to capture the generated SQL. Every row-level assertion there is one `mxcli oql`
command with the flags in place.

### Re-test — fixed

Built `claude/mxbuild-diagnostics-spike-emta6h` (`e47926f8`) and ran the whole
scenario again with a clean environment: no `M2EE_ADMIN_PASS`, no
`JAVA_TOOL_OPTIONS`, no `--direct`, no `--token`.

The fix went further than the two lines I proposed — it covers all three points
above:

| Part | Change |
| --- | --- |
| Boot flags | `LocalRuntimeOptions.jvmArgs()` always passes both `-Dmendix.*` properties |
| Password | `resolveM2EEDefaults` falls back to `defaultLocalAdminPass` (the admin API is loopback-only) |
| Hint | The "Action not found" message now branches between `run --local` and docker |
| Discoverability | The `run --local` banner prints a ready-to-copy `mxcli oql` line |

```
$ mxcli run --local -p TraceOps.mpr --ensure-db --db-name traceops_fix36
...
App is running at http://127.0.0.1:8080/
Query data:  mxcli oql -p .../TraceOps.mpr "SELECT ..."

$ mxcli oql -p TraceOps.mpr "SELECT r.ReqId, r.Title FROM TraceOps.Requirement AS r LIMIT 4"
| Title                                    | ReqId   |
|------------------------------------------|---------|
| OPC UA client                            | EDG-1   |
| Row-level plant scoping on every query   | PLT-3-1 |
...
(4 rows)
```

Both view-entity cases from #31–#34 now answer in one command each — the inline
view with pushdown applied, and the multi-record pair view:

```
$ mxcli oql -p TraceOps.mpr "SELECT v.ReqId, v.LinkCount FROM TraceOps.VW_Inline AS v
                             WHERE v.LinkCount > 0 ORDER BY v.LinkCount DESC LIMIT 3"
(3 rows)
$ mxcli oql -p TraceOps.mpr "SELECT v.ChildReqId, v.ParentReqId FROM TraceOps.VW_ReqPair AS v LIMIT 3"
(3 rows)
```

**The two halves are independently useful.** Pointing the *stock* `nightly-93`
`oql` client at a runtime booted by the fixed build works as soon as the password
is supplied — so the boot-flag change alone unblocks anyone on an older client:

```
$ M2EE_ADMIN_PASS='mxcli-local-dev' mxcli oql -p TraceOps.mpr "SELECT r.ReqId FROM TraceOps.Requirement AS r LIMIT 2"
(2 rows)
$ mxcli oql -p TraceOps.mpr "SELECT r.ReqId FROM TraceOps.Requirement AS r LIMIT 1"   # no password
Error: admin password required: set --token, M2EE_ADMIN_PASS env var, or configure .docker/.env
```

The token fallback is what makes it zero-config. `go test ./cmd/mxcli/docker/ -run
'TestJVMArgs|TestResolveM2EEDefaults'` passes.

**No regressions.** The full harness against this build: **9 fixed, 0 still
present, 1 improved, 3 by design, 0 changed**, and `mx check` on the probe project
reports 0 errors.
