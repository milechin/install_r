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
[install_R/config.sh](install_R/config.sh).
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

Populating the freshly built R with packages (CRAN, Bioconductor, tidyverse) is **a
separate post-install step** — the package-migration workflow below, run by hand after
confirming R works; the build script prints the exact commands at the end. (There is no
longer a standalone Bioconductor bootstrap: the migration carries Bioconductor packages.)
Toolchain is pinned in `install_R/config.sh`: `gcc/12.2.0`, `texlive/2022`, `flexiblas/3.3.1`.

**2. Migrate packages from an old R version to a new one — the [install_packages/](install_packages/) subdirectory**
Two `Rscript` steps, environment-agnostic (no module/SCC coupling; you provide each R
yourself, e.g. `module load R/<ver>` on the SCC or any R elsewhere):
- Under the **old** R: `Rscript install_packages/list_packages.R` — [list_packages.R](install_packages/list_packages.R)
  dumps the installed packages to `installed_r_packages.txt` as a tab-separated
  `Package` + `Repository` table, tagging each `CRAN` or `Bioconductor` (detected
  offline from the `biocViews` DESCRIPTION field).
- Under the **new** R: `Rscript install_packages/install_packages.R [mode] [list.txt]` —
  [install_packages.R](install_packages/install_packages.R) reads the list (default
  `installed_r_packages.txt`, or an optional path arg), `setdiff`s against what's
  already installed, and installs the missing packages (logs per-package
  SUCCESS/FAILED to `build/package_install/package_installation_log.txt`). `mode` is `online` (default,
  install from CRAN — and Bioconductor when the list has Bioc packages), `download`
  (fetch source tarballs + hard deps into a `DIST` folder for transfer to an air-gapped
  machine), `offline` (install from a copied `DIST` as a `file://` repo), or `index`
  (just rebuild the `DIST` `PACKAGES` index — no list needed). See the air-gap section
  in the README.

(The old `install_packages.sh` wrapper, which hard-coded `module load`s and was tied
to the SCC, was removed in favor of these two portable steps.)

## Things that aren't obvious from reading one file

- The migration `.R` scripts (`list_packages.R`, `install_packages.R`) are
  environment-agnostic — they take no module/SCC dependency and read/write
  `installed_r_packages.txt` by relative path. You provide the right R for each step
  (e.g. `module load R/<ver>` on the SCC) rather than a committed wrapper doing it.
- `install_R.sh` gets `module` because the build modules are loaded in `config.sh`,
  which you `source` in an (already module-enabled) interactive/login shell
  beforehand; the modules' environment then propagates to the `install_R.sh` child.
- `install_R.sh` locates the GCC runtime libs dynamically via
  `gcc -print-file-name` + `objdump` SONAME (matching the loaded gcc), rather than
  hard-coding versioned paths — so it tracks whatever `gcc` module `config.sh` loads.
  A missing runtime lib is fatal (intentionally); a failing `make check` is not.
- The flexiblas `--with-blas`/`--with-lapack` configure options are added **only if a
  flexiblas module is loaded** (`install_R.sh` checks `module list`); the option string
  itself lives in `config.sh` as `R_FLEXIBLAS_CONFIGURE_OPTS` (single-quoted so its
  `pkg-config` substitution is deferred until build time, then `eval`'d).
- [install_packages.R](install_packages/install_packages.R)'s `download` mode resolves the dependency
  closure against the **target** R version and OS (`TARGET_R_VERSION` / `TARGET_OS`
  env vars, defaulting to the running R and `linux`) via custom `available.packages()`
  filters — not just the machine running the download — so an online box on a newer R
  doesn't fetch packages the air-gapped target can't install. The air-gap approach
  uses **source** tarballs (compiler/glibc-independent); they compile on the target,
  so the target needs a compatible toolchain. CRAN metadata carries no compiler/glibc
  constraint, so there is nothing to filter on that axis. By default the download
  closure is hard deps only (`Depends`/`Imports`/`LinkingTo`); `INCLUDE_SUGGESTS=1`
  also pulls the listed packages' `Suggests` (top-level, plus their hard deps) to
  mirror `install.packages(dependencies = TRUE)` — a much larger closure. Set
  `INCLUDE_SUGGESTS` **the same** for the `download` and the `offline` step: download
  decides what tarballs land in `DIST`, and offline now restricts its
  `install.packages(dependencies = ...)` to match (hard deps only by default), so a
  mismatch would have offline request `Suggests` that were never downloaded.
- The `DIST` `PACKAGES` index (what `install.packages` reads to discover the available
  tarballs) is (re)built by the `index_dist()` helper, which wraps
  `tools::write_PACKAGES`. It must be rewritten whenever `DIST`'s contents change, so
  three paths call it: `download` (after fetching), `offline` (**before** installing —
  so tarballs dropped into `DIST` by hand are picked up automatically), and the
  standalone `index` mode (rebuild the index alone, e.g. after adding packages to an
  existing `DIST`). Because `offline` reindexes first, its guard only requires that
  `DIST` *exists* — it no longer demands a pre-existing `PACKAGES` file (the reindex
  creates one), so a `DIST` that only ever received tarballs still installs in one step.
  `index_dist()` prints a "Indexing DIST … N tarball(s) to scan" line before the scan,
  because `write_PACKAGES` opens every tarball's `DESCRIPTION` and runs for minutes on a
  large `DIST` with no other output (it looked like a hang). `offline`'s reindex can be
  skipped with `SKIP_REINDEX=1` when `DIST` is unchanged since `download` (which already
  wrote the index) — that path then requires a pre-existing `PACKAGES` file, since it
  won't be creating one.
- `offline` **pre-filters the requested list against the `DIST` index** (via
  `available.packages(contriburl = file://DIST, filters = character(0))` — no R-version/OS
  filter, so it's pure "is it in DIST") and **skips** names not present, logging them as
  `SKIPPED (not in DIST)` rather than passing them to `install.packages` to attempt and
  fail. This is what keeps `download`'s **dropped** packages (archived/removed from CRAN,
  GitHub-only, Bioc-release miss) out of `failed_packages.txt` on the air-gap target —
  they were never installable offline, so they're skipped, not failed. Genuine build
  failures among the packages that *are* in `DIST` still go to `failed_packages.txt`.
- `download` mode is **re-runnable**: it skips any package whose exact-version tarball
  is already in `DIST` (version-aware — a newer CRAN version still gets fetched), so a
  re-run only grabs what's missing. `OVERWRITE=1` forces re-fetching everything. It
  writes `download_log.txt` (under `LOG_DIR`) recording requested→resolved counts, the
  full skipped/downloaded lists, the **dropped** names (split into CRAN vs Bioconductor
  — a dropped Bioc name signals a wrong `TARGET_BIOC_VERSION`, not "Bioc unsupported"),
  and any download failures — the only durable record, since the tarballs + `PACKAGES`
  index are otherwise all that `download` leaves behind.
- **Bioconductor is carried by the migration itself.** `list_packages.R` tags each
  package `CRAN` or `Bioconductor` in the list's `Repository` column, detected
  **offline** from the installed package's `biocViews` DESCRIPTION field (Bioc packages
  have it; CRAN packages don't) — so no network/BiocManager is needed where the *list*
  is produced. `install_packages.R` reads that column (`read_package_list` returns a
  `Package`+`Repository` data.frame; a legacy single-column list defaults all to CRAN,
  preserving old behavior) and, when any package is tagged Bioconductor, adds the
  Bioconductor repos to the combined `available.packages()`/`download.packages()`
  (download) or `install.packages` `repos` (online) via the `bioc_repositories()`
  helper. `BiocManager` is required **only when the list actually contains Bioconductor
  packages** — `download` fails clearly if it's absent; `online` bootstraps it from
  CRAN (it is itself a CRAN package). The Bioc *release* must match the **target** R:
  defaults to the running R's release, overridable with `TARGET_BIOC_VERSION` (required
  when the download machine's R differs from the target R). Versions are not pinned —
  each named package installs at its current version (intended). `offline` needs no
  Bioc-specific logic: once the Bioc source tarballs are in `DIST` and indexed they
  install by name like any other source package. `biocViews` won't flag GitHub/local
  packages, so those read as CRAN and are dropped if not on CRAN (as before).
- `LOG_DIR` (default `build/package_install`) is where all log/output artifacts go —
  `package_installation_log.txt`, `install_logs/`, `failed_packages.txt`,
  `download_log.txt` — created if missing. It is a sibling of `build/r_install/` (where
  `install_R.sh` builds R and writes its `config.out`/`make.*.output`), so the build dir
  holds one subfolder per action rather than both actions' logs intermixed. `failed_packages.txt` is written in the same
  2-column `Package`+`Repository` format the scripts read, so a failed **Bioconductor**
  package retried via that file stays tagged Bioconductor instead of silently reverting
  to CRAN. `DIST_DIR` is unrelated (the package repo) and independent of `LOG_DIR`.
- **Install is version-aware** (`install_from_repo`): a package is (re)installed when it
  is **missing** or the repo offers a **strictly newer** version (an upgrade), and skipped
  when already at >= the repo version. The repo versions come from
  `available.packages()` with **default** filters (R-version/OS aware — the version
  `install.packages` would actually install here), unlike the offline not-in-DIST
  pre-filter which uses `filters=character(0)` (pure presence). The loop re-checks the
  *current* installed version each iteration, so a package an earlier entry pulled in as a
  dependency (now current) is skipped rather than rebuilt — that re-check is what keeps a
  ~1800-package run from recompiling everything. Success is judged by the installed
  version **afterwards** (`packageVersion >= repo version`), **not** `tryCatch`/mere
  presence — a failed source build emits a *warning* (not an error), and a failed
  *upgrade* can leave the old version in place, so a naive "is it present" check would log
  a false SUCCESS. Don't "simplify" that back. It passes `keep_outputs` to
  `install.packages` and keeps each **failed** build's full output as
  `install_logs/<pkg>.out`, deleting the successes' outputs. Failures are also collected
  into `failed_packages.txt` (a re-feedable list) with a printed retry command.
- Hard-coded versions (`gcc/12.2.0`, `flexiblas/3.3.1`, `cmake/3.22.2`, the
  `pkg.7`→`pkg.8`/alma8 paths, `R-4/` URL path) are environment facts, not defaults to
  generalize. Changing them is a real migration decision.
- The header comments in [install_R/install_R.sh](install_R/install_R.sh) record the change history
  (pkg.7→pkg.8, flexiblas added) — keep updating them when modifying the build.
