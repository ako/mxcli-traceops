# Tooling

This project is authored entirely through **mxcli / MDL**. The `.mpr` is never
hand-edited and Studio Pro is never used.

## Why this file exists

The container this project runs in is **ephemeral**. When it is recycled,
everything installed at runtime is gone:

| Path | Contents | Survives recycling? |
| --- | --- | --- |
| `/opt/antlr/` | ANTLR 4.13.1 jar | No |
| `/opt/mxcli-src/` | mxcli clone + build tree | No |
| `/usr/local/bin/{mxcli,antlr4}` | built binary + shim | No |
| `~/.mxcli/mxbuild/<ver>/` | Mendix build engine (~822 MB) | No |
| `~/.mxcli/runtime/<ver>/` | Mendix runtime (~341 MB) | No |
| this git repo | source of truth | **Yes** |

So reproducibility comes from **committed files, not installed state**. The one
committed file that matters is `scripts/setup-tools.sh`; everything above is
derived from it. No clone, no jar, no `*.mda` and no `deployment/` is committed —
see `.gitignore`. The one binary exception is `TraceOps/widgets/*.mpk`, which the
app genuinely needs to build (see the end of this file).

## How the toolchain is re-established

`scripts/setup-tools.sh` rebuilds the whole toolchain and is wired to run on
every session start via `.claude/settings.json`:

```jsonc
"SessionStart": [{ "hooks": [{ "type": "command",
  "command": "bash \"$CLAUDE_PROJECT_DIR/scripts/setup-tools.sh\"",
  "timeout": 1800 }] }]
```

It is idempotent and detect-then-install, so it is safe (and cheap) to run every
time:

- **cold** (fresh container): ~4 min — clone, ANTLR download, `make build`, ~1.2 GB of Mendix downloads
- **warm** (everything cached): **~1 s** — it only resolves the remote `main` SHA and re-verifies

Run it by hand any time with `bash scripts/setup-tools.sh`.

### What it does

1. **Detects** what the base image already provides and never reinstalls it:
   Go, JDK, Node, PostgreSQL, and Chromium at `$PLAYWRIGHT_BROWSERS_PATH/chromium`.
   `playwright install` is never run.
2. **Pins ANTLR 4.13.1** — jar at `/opt/antlr/antlr-4.13.1-complete.jar`, with a
   shim at `/usr/local/bin/antlr4` that `exec`s `java -jar` on it. Skipped if the
   jar is already there. The build verifies the reported version and fails if it
   is anything other than 4.13.1.
3. **Builds mxcli** from `https://github.com/ako/mxcli.git` at `main` and installs
   to `/usr/local/bin/mxcli`. The built commit is stamped to
   `/opt/mxcli-src/.installed-sha`; if that stamp already matches the current
   remote `main` HEAD, the build is skipped entirely.
4. **Pre-caches** the Mendix build engine and runtime for the target version so
   the first build is not a cold download. Skipped if already cached.
5. **Verifies** every component and **fails loudly** (non-zero exit, red `[FAIL]`)
   rather than letting a half-built toolchain look healthy.
6. Prints a **version summary**.

### Knobs

- `MENDIX_VERSION` (default `11.12.1`) selects which engine/runtime to cache.

## Two things that are easy to get wrong

### `go build` alone is not enough — use the Makefile

`make build` is required, not plain `go build`. The Makefile's `build` target
also does two things the compile depends on:

- generates the ANTLR parser into `mdl/grammar/parser/`, which is **not committed**
  to mxcli — hence the hard ANTLR dependency;
- syncs the `go:embed` payloads (`cmd/mxcli/skills/`, `commands/`, `lint-rules/`,
  `changelog.md`, `vscode-mdl.vsix`), which are also gitignored.

A bare `go build` fails on the missing embed directories.

### `GOTOOLCHAIN=auto` is mandatory

mxcli's `go.mod` declares a newer toolchain than the image's Go. The script
exports `GOTOOLCHAIN=auto` so Go fetches and uses the declared toolchain
(`go1.26.5` at time of writing) instead of failing against the image's `go1.24.7`.

## Hook wiring — do not add a second SessionStart entry

When a script that launches the app is added later, it goes in the **same hook
command**, chained with `&&`:

```json
"command": "bash \"$CLAUDE_PROJECT_DIR/scripts/setup-tools.sh\" && bash \"$CLAUDE_PROJECT_DIR/scripts/run-app.sh\""
```

Two entries in one `SessionStart` `hooks` array run **concurrently, not
sequentially**. That race launches the app against the *previous* mxcli binary
while the rebuild is still in flight, and the symptom is invisible — the process
just holds a deleted inode.

## Credentials

Hub credentials (`MXCLI_HUB_URL`, `MXCLI_HUB_KEY`, `MXCLI_HUB_SECRET`) come from
the Claude Code environment configuration and are **never** committed. A
gitignored file would not survive container recycling either, so the environment
is the only durable place for them.

`MXCLI_HUB_KEY` must be minted in a browser at <https://hub.mxcli.org/cli>. This
container cannot reach GitHub's OAuth device-flow endpoints, so
`mxcli auth hub login` cannot complete here.

## Working rules

- mxcli's default engine is `modelsdk`. Do **not** pass `--engine legacy`.
- Author everything in `.mdl` files under `<App>/mdlsource/`, numbered so they
  apply in dependency order. Re-apply them from scratch rather than patching the
  `.mpr`.
- Use `mxcli -c "REFRESH CATALOG FULL"` — a plain `REFRESH` leaves
  `activities_data` and refs empty.
- Never run `mx check` while a `--watch` loop is live; it wedges the loop.
- Use anchored `pgrep`/`pkill` patterns (e.g. `^mxcli run`). A bare
  `pgrep -f mxcli` matches your own shell and kills the command chain.

---

# The TraceOps app

`TraceOps/` is a Mendix 11.12.1 app reproducing the **Requirements Delivery
Tracker** design prototype (TraceOps — Requirements & Delivery Assurance).

## How it is authored

Everything is authored in MDL under `TraceOps/mdlsource/`, numbered so the files
apply in dependency order. Re-apply from scratch rather than patching the `.mpr`:

```bash
cd TraceOps
for f in mdlsource/*.mdl; do ./mxcli exec "$f" -p TraceOps.mpr; done
~/.mxcli/mxbuild/11.12.1/modeler/mx check TraceOps.mpr     # expect 0 errors
./mxcli run --local -p TraceOps.mpr --ensure-db            # http://127.0.0.1:8080
```

| File | Contents |
| --- | --- |
| `01-domain-model.mdl` | 10 enums, 17 entities, associations |
| `02-seed-tree.mdl` | **generated** — the 81-node requirement tree |
| `03-seed-reference.mdl` | guardrails, ADRs, KPIs, risks, changes, releases, baselines |
| `04-seed-sessions.mdl` | 9 agent sessions + the validation queue |
| `05-microflows.mdl` | tree state, filters, selections, startup seed |
| `06-navigation-flows.mdl` | view navigation + cockpit drill-downs |
| `07-shell-snippets.mdl` | top bar, sidebar, status bar |
| `08`–`16` | the six pages and the navigation profile |

`02-seed-tree.mdl` is generated by `TraceOps/scripts/gen-tree-seed.py`, which
holds the requirement tree transcribed from the prototype and reuses the
prototype's own `roll()` / `pct()` algorithms. Regenerate with:

```bash
python3 TraceOps/scripts/gen-tree-seed.py
```

Editing the tree by hand in the `.mdl` would desynchronise the rollups from the
design — change the Python and regenerate.

## Design fidelity

The theme lives in `TraceOps/theme/web/_traceops.scss`, imported last from
`main.scss` so it wins the cascade over Atlas. Atlas supplies the layout
document, the widget DOM and its utility classes; the partial adds the
brand-identity delta the prototype needs and Atlas cannot express — the dark
chrome, 26px grid rows, fractional table tracks, and the status/kind chip
palettes. Every class and custom property is prefixed `tr-` / `--tr-`.

Two things about the prototype's chrome are worth knowing:

- **The shell is snippets, not the Atlas navigation.** The top bar and sidebar
  carry live data (running-session count, per-area health bars), which the Mendix
  navigation model and CSS pseudo-elements cannot render. So the Atlas
  topbar/sidebar regions are hidden in the theme and the shell is rebuilt as
  three shared snippets. The navigation profile still exists and drives routing.
- **Data-driven widths use the bucket-class idiom.** A widget has no computed
  inline style, so every coverage bar's width is quantised to a 0–20 bucket at
  seed time and selected with `DynamicClasses: '''tr-w-'' + toString(...)'`.

## Seeding

Demo data is created by `ACT_Startup`, wired as the after-startup microflow and
guarded to run once (it returns immediately if any requirement exists). To
re-seed, truncate the `traceops$*` tables and restart the runtime.

## Known gap

The traceability tree renders 20 rows and a "Load more" button rather than all
31. mxcli's ListView builder hardcodes `PageSize: 20` and exposes no way to
change it from MDL — see FINDINGS.md #17. No other list in the app exceeds 20
rows.

## Why `TraceOps/widgets/*.mpk` is committed

The `.gitignore` excludes `*.mpk` but re-includes `TraceOps/widgets/*.mpk`. Those
archives are required to build — verified by moving the directory aside and
rebuilding, which fails with `CE0462 "Could not find widget 'Image' in the
'widgets' directory"`. They are app dependencies rather than toolchain binaries,
and the container is ephemeral, so they have to be in git.
