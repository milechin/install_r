# Installing R from source

System-administration scripts for building R from source on the Boston University
SCC cluster (under `/share/pkg.8/r/`), plus a test harness for exercising the build
on AlmaLinux / Rocky / Ubuntu.

The R-build workflow lives in [`install_R/`](install_R/) (it is run infrequently):

- [`install_R/install_R.sh`](install_R/install_R.sh) — build + install one R version from source.
- [`install_R/config.sh`](install_R/config.sh) — all the parameters and module loads for the build.
- [`install_R/install_bioconductor.R`](install_R/install_bioconductor.R) — installs BiocManager + tidyverse (separate step).
- [`test/`](test/) — run `install_R.sh` end-to-end in a sandbox (see [Running the tests](#running-the-tests)).

> For package migration between R versions, see `install_packages.sh` (not covered here).

---

## Building a new R version

### 1. Prerequisites

Run on the cluster in a shell where the `module` command is available (a login or
interactive shell). The toolchain modules are loaded for you by `config.sh`.

### 2. Create the version directory

`install_R.sh` expects a fixed layout under `$R_PKG_BASE/$VERSION` and will refuse
to run if it is missing. Create it first (replace `4.5.2` with your version):

```bash
mkdir -p /share/pkg.8/r/4.5.2/{DIST,src,build,install}
```

### 3. Edit the configuration

Open [`install_R/config.sh`](install_R/config.sh) and set at least `VERSION`. Review the rest:

| Variable | What it is |
|---|---|
| `VERSION` | R version to build, e.g. `4.5.2` |
| `R_PKG_BASE` | Base install dir (no trailing slash), e.g. `/share/pkg.8/r` |
| `CRAN_SRC_URL` | CRAN source base URL; the `R-4` segment tracks the R major version |
| `SOURCE_TARBALL` | Empty → download from CRAN. A path → use that already-downloaded tarball instead (for offline builds) |
| `R_CONFIGURE_OPTS` | configure flags applied on every build |
| `R_FLEXIBLAS_CONFIGURE_OPTS` | BLAS/LAPACK flags, added only when a flexiblas module is loaded |
| `module load …` (top of file) | Pinned toolchain: `texlive`, `gcc`, `flexiblas` |

**Downloading vs. a local tarball.** By default the source is downloaded from CRAN.
To build on a machine without internet, download `R-$VERSION.tar.gz` elsewhere, copy
it over, and set `SOURCE_TARBALL` to its path — `install_R.sh` then uses that file
(copying it into `DIST/`) instead of fetching.

### 4. Build

```bash
cd install_R
source config.sh      # exports the variables AND loads the toolchain modules
./install_R.sh
```

`config.sh` must be **sourced** (not executed) so its variables and loaded modules
carry into `install_R.sh`. The script runs with `set -e`/`pipefail`, verifies the
config was sourced and the directories exist, then obtains the source (download or
local tarball), configures, builds, `make install`s, copies the gcc runtime
libraries into R's `lib`, and runs `R CMD javareconf` against `/usr/java/default`.
`make check` is run but is non-fatal (failures are logged, not aborting).

Logs land in `$R_PKG_BASE/$VERSION/build/` (`config.out`, `make.output`,
`make.install.output`, `make.check.output`).

### 5. Install Bioconductor + tidyverse (separate step)

After confirming R works, install the base package set. `install_R.sh` prints the
exact command at the end; it is:

```bash
/share/pkg.8/r/4.5.2/install/bin/Rscript \
    /share/pkg.8/r/install_bioconductor.R |& tee \
    /share/pkg.8/r/4.5.2/build/install_bioconductor.output
```

---

## Running the tests

The [`test/`](test/) harness runs `install_R.sh` end-to-end in a throwaway sandbox,
with **no module system** — the toolchain is installed from the OS package manager.
It is meant to run on a fresh container image: the RHEL family — AlmaLinux or Rocky,
el8/el9 (el8 is closest to the cluster's alma8) — or Ubuntu.

### One command

```bash
./test/run_test.sh
```

This will, in order:

1. Install build dependencies + a JDK for the detected distro (`dnf`/`yum` or `apt`)
   and create the `/usr/java/default` symlink — see [`test/install_deps.sh`](test/install_deps.sh).
2. Load [`test/test_config.sh`](test/test_config.sh) (a `config.sh` with no module loads).
3. Create the sandbox directory layout — [`test/setup_test_env.sh`](test/setup_test_env.sh).
4. Run [`install_R/install_R.sh`](install_R/install_R.sh).
5. Smoke-test the built R (`R --version` and a script run).

### In containers (AlmaLinux / Rocky)

These are the images the CI workflow uses (the harness also supports Ubuntu, but
CI is currently scoped to the RHEL family that matches the cluster):

```bash
docker run --rm -v "$PWD:/repo" -w /repo almalinux:8  bash test/run_test.sh
docker run --rm -v "$PWD:/repo" -w /repo almalinux:9  bash test/run_test.sh
docker run --rm -v "$PWD:/repo" -w /repo rockylinux:9 bash test/run_test.sh
```

### Knobs

| Variable | Effect |
|---|---|
| `SKIP_DEPS=1` | Skip the system-package install step (toolchain + JDK already present) |
| `TEST_ROOT=/path` | Build the sandbox somewhere other than `test/test_pkg` |

```bash
SKIP_DEPS=1 ./test/run_test.sh
```

### Notes

- The test deliberately uses a **lighter configure** (`--with-x=no
  --without-recommended-packages`) and builds in parallel (`MAKEFLAGS=-j$(nproc)`)
  to keep CI fast; production options live in [`install_R/config.sh`](install_R/config.sh).
- `install_deps.sh` uses `sudo` only when not already root, so it works both in
  containers (root) and on a dev box.
- Build artifacts go to `test/test_pkg/` and are ignored by git.

---

## Continuous integration

[`.github/workflows/test-install-r.yml`](.github/workflows/test-install-r.yml)
runs the test harness on GitHub Actions across **AlmaLinux 8, AlmaLinux 9, and
Rocky 9** (the cluster is alma8; el9 is included to catch differences). Each
distro runs as a container job and executes `test/run_test.sh` — the same script
you run locally.

It triggers on:

- **push** to `main` and **pull requests** — but only when a build/test file
  changes (`install_R/**`, `test/**`, or the
  workflow itself), so unrelated commits don't kick off a ~build.
- **manual dispatch** (Actions tab → *Test install_R.sh* → *Run workflow*).

### Choosing the R version for a manual run

The manual *Run workflow* form has an **`R version to build`** field:

- Enter a version (e.g. `4.5.2`) to build that release on all three distros.
- Leave it blank to use the default in [`test/test_config.sh`](test/test_config.sh).

The version must exist on CRAN at
`https://cran.r-project.org/src/base/R-4/R-<version>.tar.gz`, otherwise the
download step fails the build. (Push/PR runs always use the test default.)

If a job fails, its build logs (`config.out`, `make.*.output`) are uploaded as a
workflow artifact for debugging.
