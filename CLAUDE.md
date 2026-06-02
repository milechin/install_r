# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

System-administration scripts for installing R from source and migrating R packages
on a shared HPC cluster (Boston University SCC). There is no build system, test suite,
or application — these are operational scripts run by hand on the cluster, in sequence,
by an admin with write access to `/share/pkg.8`. They depend on the cluster's
environment-module system (`module load ...`) and a fixed directory layout under
`/share/pkg.8/r/$VERSION/` (`DIST`, `src`, `build`, `install`), all of which the admin
creates before running the build.

## The two workflows

**1. Build a new R version from source — the [install_R/](install_R/) subdirectory**
This workflow (run infrequently) lives in `install_R/`:
[install_R/install_R.sh](install_R/install_R.sh),
[install_R/config.sh](install_R/config.sh),
[install_R/install_bioconductor.R](install_R/install_bioconductor.R).
Edit `config.sh` (at minimum `VERSION`), then:
```bash
cd install_R
source config.sh
./install_R.sh
```
`config.sh` is sourced (not executed) because it both exports parameters
(`VERSION`, `R_PKG_BASE`, `CRAN_SRC_URL`, `SOURCE_TARBALL`, the configure-option
strings) **and** runs the `module load`s (texlive/gcc/flexiblas) so the build
environment is ready; those exported vars and loaded modules propagate into the
`install_R.sh` child process.

`install_R.sh` runs `set -e`/`pipefail`, validates that `config.sh` was sourced and
that the version directory layout exists, then: obtains the source into `DIST/`
(downloads from CRAN, or uses `SOURCE_TARBALL` if set — a local tarball for offline
builds), extracts into `src/R-$VERSION`, configures, builds, `make install`s (with
`make check` kept non-fatal), copies GCC runtime shared libs (`libgfortran`,
`libstdc++`, `libgcc_s`) into the R `lib` so R starts without the gcc module loaded,
and runs `R CMD javareconf` against `/usr/java/default` so R tracks the system default
Java (a Java upgrade re-points the symlink and R follows, without breaking rJava).
It is **location-independent** — all paths derive from the config vars, so it no
longer matters which directory you launch it from.

Installing BiocManager + tidyverse via [install_R/install_bioconductor.R](install_R/install_bioconductor.R)
is **a separate post-install step** (run it by hand after confirming R works); the
build script prints the exact command at the end.
Toolchain is pinned in `install_R/config.sh`: `gcc/12.2.0`, `texlive/2022`, `flexiblas/3.3.1`.

**2. Migrate packages from an old R version to a new one — [install_packages.sh](install_packages.sh)**
`./install_packages.sh <old_version> <new_version>`. Loads `R/<old>`, dumps the
installed package names to `installed_r_packages.txt` via
[list_packages.R](list_packages.R), then `module purge`s, loads `R/<new>` +
`gcc/12.2.0` + `cmake/3.22.2`, and reinstalls that list with
[install_packages.R](install_packages.R) (logs per-package SUCCESS/FAILED to
`package_installation_log.txt`).

## Things that aren't obvious from reading one file

- The two `install_packages.*` scripts reference their `.R` counterparts by the
  **deployed** absolute path `/share/pkg.8/r/...`, not the repo copy. Editing a script
  here has no effect until it is copied to that location on the cluster.
- `install_R.sh` is run via `bash`/`sh` but `install_packages.sh` needs a **login
  shell** (`#!/bin/bash -l`) because `module` is only defined in login shells.
  `install_R.sh` gets `module` because the modules are loaded in `config.sh`, which
  you `source` in an (already module-enabled) interactive/login shell beforehand.
- `install_R.sh` locates the GCC runtime libs dynamically via
  `gcc -print-file-name` + `objdump` SONAME (matching the loaded gcc), rather than
  hard-coding versioned paths — so it tracks whatever `gcc` module `config.sh` loads.
  A missing runtime lib is fatal (intentionally); a failing `make check` is not.
- The flexiblas `--with-blas`/`--with-lapack` configure options are added **only if a
  flexiblas module is loaded** (`install_R.sh` checks `module list`); the option string
  itself lives in `config.sh` as `R_FLEXIBLAS_CONFIGURE_OPTS` (single-quoted so its
  `pkg-config` substitution is deferred until build time, then `eval`'d).
- [install_packages.R](install_packages.R) force-reinstalls `Matrix` unconditionally —
  a deliberate workaround (Nov 2025) for a bad Matrix build shadowing the CRAN one.
  Don't "clean up" that line.
- Hard-coded versions (`gcc/12.2.0`, `flexiblas/3.3.1`, `cmake/3.22.2`, the
  `pkg.7`→`pkg.8`/alma8 paths, `R-4/` URL path) are environment facts, not defaults to
  generalize. Changing them is a real migration decision.
- The header comments in [install_R/install_R.sh](install_R/install_R.sh) record the change history
  (pkg.7→pkg.8, flexiblas added) — keep updating them when modifying the build.
