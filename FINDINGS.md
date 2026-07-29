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
