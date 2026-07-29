# FINDINGS

Running log of mxcli bugs, surprises, and workarounds. Numbered, with the exact
command and output. Started in the toolchain-setup session (phase 1).

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

**Status: unresolved.** The tree paginates at 20 with a working "Load more".
Every other list in the app is under 20 rows, so this affects one view. Switching
the tree to a DATAGRID would fix the paging but costs the pixel-exact row markup
that the design needs (the migrate-design-prototype skill recommends ListView for
exactly this reason).

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
