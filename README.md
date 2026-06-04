# Installing R from source

System-administration scripts for building R from source on the Boston University
SCC cluster (under `/share/pkg.8/r/`), plus a test harness for exercising the build
on AlmaLinux / Rocky / Ubuntu.

The R-build workflow lives in [`install_R/`](install_R/) (it is run infrequently):

- [`install_R/install_R.sh`](install_R/install_R.sh) — build + install one R version from source.
- [`install_R/config.sh`](install_R/config.sh) — all the parameters and module loads for the build.
- [`install_R/install_bioconductor.R`](install_R/install_bioconductor.R) — installs BiocManager + tidyverse (separate step).
- [`test/`](test/) — run `install_R.sh` end-to-end in a sandbox (see [Running the tests](#running-the-tests)).

A separate workflow in [`install_packages/`](install_packages/) migrates installed
packages from an old R version to a new one — see
[Migrating R packages to a new R version](#migrating-r-packages-to-a-new-r-version).

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

## Migrating R packages to a new R version

When a new R version is built, the packages a user had under the old version need to
be reinstalled under the new one. This is two plain `Rscript` steps — one under the
**old** R, one under the **new** R. The scripts are environment-agnostic; you decide
how each R is provided (`module load R/<ver>` on the SCC, or any R elsewhere).

1. **Dump the old version's package list** — under the **old** R:

   ```bash
   Rscript install_packages/list_packages.R
   ```

   [`list_packages.R`](install_packages/list_packages.R) calls `installed.packages()`, sorts by name,
   and writes the **package names** (one per line, with a `Package` header) to
   **`installed_r_packages.txt`** in the current directory. This file is the record of
   what was installed under the old R that needs to come across to the new one.

2. **Reinstall under the new version** — under the **new** R (with a compiler
   available, since packages build from source):

   ```bash
   Rscript install_packages/install_packages.R                    # reads ./installed_r_packages.txt
   Rscript install_packages/install_packages.R path/to/list.txt   # or point at a specific list file
   ```

   [`install_packages.R`](install_packages/install_packages.R) reads the package list, computes which
   packages are not yet present in the new R (`setdiff` against
   `installed.packages()`), and installs the missing ones from CRAN. Per-package
   results are logged to `package_installation_log.txt` (`SUCCESS:` / `FAILED:` with
   the error text per package). Success is determined by checking the package is
   actually present afterwards — a source build that fails only emits a warning, so a
   naive check would miss it.

   For each **failed** package the full build output (the `R CMD INSTALL` log, with
   the compiler error or the missing-dependency message — so you can see *why* it
   failed, including when the real culprit is a dependency) is saved to
   `install_logs/<pkg>.out`, and the summary log line points at it. Logs for
   successful builds are not kept.

   If any packages fail, their names are also written to `failed_packages.txt` (same
   format as the input list) and a ready-to-run retry command is printed. You can
   rerun that to attempt only the failures — and since the script skips
   already-installed packages, simply re-running with the original list works too.

Note: packages compile from source on the new R, so the build toolchain (and any
system `-devel` libraries a given package needs) must be available on the machine.

### Air-gapped target systems

[`install_packages.R`](install_packages/install_packages.R) takes a **mode** as its first argument.
The plain form above is the default `online` mode. For a target with no internet
access, do the install in two stages — **download** on an internet-connected machine,
then **offline** install on the air-gapped target:

```bash
# 1. On an internet-connected machine: fetch every package in the list PLUS its
#    hard dependencies (Depends/Imports/LinkingTo, recursive) as source tarballs
#    into a DIST folder, and write a PACKAGES index so DIST is a local repository.
Rscript install_packages/install_packages.R download installed_r_packages.txt

# 2. Copy the DIST folder to the air-gapped target.

# 3. On the target: install from DIST (a file:// repo) — no network access.
#    offline rebuilds the PACKAGES index first, so DIST need not arrive pre-indexed.
Rscript install_packages/install_packages.R offline installed_r_packages.txt
```

The target must have the same build toolchain R was built with (the packages still
compile from source there) plus any required system `-devel` libraries.

**Adding packages to an existing DIST.** To extend a DIST later, drop the extra source
tarballs into the DIST folder and re-index it. The `offline` step reindexes
automatically before installing, so new tarballs are picked up on the next install with
no extra step. To rebuild the index on its own (e.g. to verify DIST is a valid
repository without installing), use the `index` mode:

```bash
Rscript install_packages/install_packages.R index    # rebuilds DIST/PACKAGES (honors DIST_DIR)
```

Knobs (environment variables):

| Variable | Mode | Effect |
|---|---|---|
| `DIST_DIR` | download, offline, index | DIST folder location (default `./DIST`) |
| `CRAN_REPO` | download | CRAN mirror to download from (default `https://cran.r-project.org`) |
| `TARGET_R_VERSION` | download | R version the downloads must be compatible with (default: the R running the download). Set this when the online machine's R differs from the target's, so only target-compatible package versions are fetched. |
| `TARGET_OS` | download | OS the downloads must apply to: `linux` (default), `macos`, or `windows` |
| `INCLUDE_SUGGESTS` | download | Set to `1` to also download the `Suggests` of the listed packages (plus those packages' hard deps), matching what an `install.packages(dependencies = TRUE)` would pull. Off by default; this can grow the closure substantially (e.g. one small package went from 3 to 44 tarballs in testing). |

The download step prints the R-version, OS, and Suggests criteria it is resolving against.

---

## Running the tests

The [`test/`](test/) directory has two independent harnesses:

- [`test/install_R/run_test.sh`](test/install_R/run_test.sh) — builds R from source with `install_R.sh`
  (below).
- [`test/install_packages/run_package_test.sh`](test/install_packages/run_package_test.sh) — exercises
  `install_packages.R`'s three modes (see
  [Testing install_packages.R](#testing-install_packagesr)).

### Testing install_R.sh

`run_test.sh` runs `install_R.sh` end-to-end in a throwaway sandbox,
with **no module system** — the toolchain is installed from the OS package manager.
It is meant to run on a fresh container image: the RHEL family — AlmaLinux or Rocky,
el8/el9 (el8 is closest to the cluster's alma8) — or Ubuntu.

#### One command

```bash
./test/install_R/run_test.sh
```

This will, in order:

1. Install build dependencies + a JDK for the detected distro (`dnf`/`yum` or `apt`)
   and create the `/usr/java/default` symlink — see [`test/install_R/install_deps.sh`](test/install_R/install_deps.sh).
2. Load [`test/install_R/test_config.sh`](test/install_R/test_config.sh) (a `config.sh` with no module loads).
3. Create the sandbox directory layout — [`test/install_R/setup_test_env.sh`](test/install_R/setup_test_env.sh).
4. Run [`install_R/install_R.sh`](install_R/install_R.sh).
5. Smoke-test the built R (`R --version` and a script run).

#### In containers (AlmaLinux / Rocky)

These are the images the CI workflow uses (the harness also supports Ubuntu, but
CI is currently scoped to the RHEL family that matches the cluster):

```bash
docker run --rm -v "$PWD:/repo" -w /repo almalinux:8  bash test/install_R/run_test.sh
docker run --rm -v "$PWD:/repo" -w /repo almalinux:9  bash test/install_R/run_test.sh
docker run --rm -v "$PWD:/repo" -w /repo rockylinux:9 bash test/install_R/run_test.sh
```

#### Knobs

| Variable | Effect |
|---|---|
| `SKIP_DEPS=1` | Skip the system-package install step (toolchain + JDK already present) |
| `TEST_ROOT=/path` | Build the sandbox somewhere other than `test/install_R/test_pkg` |

```bash
SKIP_DEPS=1 ./test/install_R/run_test.sh
```

#### Notes

- The test deliberately uses a **lighter configure** (`--with-x=no
  --without-recommended-packages`) and builds in parallel (`MAKEFLAGS=-j$(nproc)`)
  to keep CI fast; production options live in [`install_R/config.sh`](install_R/config.sh).
- `install_deps.sh` uses `sudo` only when not already root, so it works both in
  containers (root) and on a dev box.
- Build artifacts go to `test/install_R/test_pkg/` and are ignored by git.

### Testing install_packages.R

[`test/install_packages/run_package_test.sh`](test/install_packages/run_package_test.sh) exercises the package script's
three modes. It does **not** build R — it only needs an `R`/`Rscript` on `PATH`, so
it is fast. It is meant to run in an image that ships R, e.g.
[`rocker/r-ver`](https://rocker-project.org/); a fresh such image has only
base + recommended packages, so the test's dependency packages are genuinely absent
and really get installed.

```bash
docker run --rm -v "$PWD:/repo" -w /repo rocker/r-ver:latest bash test/install_packages/run_package_test.sh
```

It needs network access to CRAN for the download/online steps; the offline step then
installs purely from the local `DIST` repo the download step produced. The checks, in
order: a `download` → `offline` air-gap round-trip (verifying a dependency is pulled
from `DIST`, not CRAN), a normal `online` install, the bare-argument back-compat path,
the `TARGET_R_VERSION` filter, and that `INCLUDE_SUGGESTS` enlarges the closure.

| Variable | Effect |
|---|---|
| `RSCRIPT=/path/to/Rscript` | Use a specific `Rscript` instead of the one on `PATH` |
| `TEST_ROOT=/path` | Build the sandbox somewhere other than `test/install_packages/pkg_test_sandbox` |

---

## Continuous integration

Two GitHub Actions workflows, each scoped by `paths:` so unrelated commits don't
trigger them:

### `test-install-r.yml` — the R build

[`.github/workflows/test-install-r.yml`](.github/workflows/test-install-r.yml)
runs the build harness across **AlmaLinux 8, AlmaLinux 9, and
Rocky 9** (the cluster is alma8; el9 is included to catch differences). Each
distro runs as a container job and executes `test/install_R/run_test.sh` — the same script
you run locally.

It triggers on:

- **push** to `main` and **pull requests** — but only when a file this build
  actually uses changes (`install_R/**`, the `run_test.sh` / `install_deps.sh` /
  `setup_test_env.sh` / `test_config.sh` harness scripts, or the workflow itself), so
  unrelated commits — including changes to the package-test script — don't kick off
  a ~90-minute build.
- **manual dispatch** (Actions tab → *Test install_R.sh* → *Run workflow*).

### `test-install-packages.yml` — the package workflow

[`.github/workflows/test-install-packages.yml`](.github/workflows/test-install-packages.yml)
runs [`test/install_packages/run_package_test.sh`](test/install_packages/run_package_test.sh) in a `rocker/r-ver`
container (R preinstalled, so nothing is built — the job is fast). It triggers on
changes to `install_packages.R`, `list_packages.R`, the test script, or the workflow
itself, and on manual dispatch (which takes an optional `image` input to pick the
`rocker/r-ver` tag / R version).

### Choosing the R version for a manual run of `test-install-r.yml`

The manual *Run workflow* form has an **`R version to build`** field:

- Enter a version (e.g. `4.5.2`) to build that release on all three distros.
- Leave it blank to use the default in [`test/install_R/test_config.sh`](test/install_R/test_config.sh).

The version must exist on CRAN at
`https://cran.r-project.org/src/base/R-4/R-<version>.tar.gz`, otherwise the
download step fails the build. (Push/PR runs always use the test default.)

If a job fails, its build logs (`config.out`, `make.*.output`) are uploaded as a
workflow artifact for debugging.
