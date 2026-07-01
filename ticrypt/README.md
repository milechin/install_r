# Installing R packages in TICrypt

TICrypt has no internet access, so you can't `install.packages()` there directly.
`ticrypt_packages.R` lets you fetch the packages you want (and everything they depend on)
on an internet-connected machine, carry them into TICrypt as one folder, and install them.

Everything is done from the **R console** — no command line, no settings to edit.

## Step 1 — On an internet-connected machine (your laptop, an SCC node, …)

Put `ticrypt_packages.R` somewhere and, in R:

```r
source("ticrypt_packages.R")
ticrypt_download(c("dplyr", "ggplot2", "DESeq2"))
```

This creates a folder named `ticrypt_packages/` containing:
- the **source tarballs** for the packages you asked for, plus all their dependencies,
- a copy of `ticrypt_packages.R` itself (so the folder is self-contained),
- a small `PACKAGES` index and a `REQUESTED.txt` list.

You can list **CRAN and/or Bioconductor** packages together — you don't need to say which
is which. If a name can't be found you'll get a clear warning naming it.

## Step 2 — Copy the folder into TICrypt

Move the whole `ticrypt_packages/` folder into TICrypt using your normal transfer method.

## Step 3 — Inside TICrypt, install

In TICrypt's R console:

```r
source("ticrypt_packages/ticrypt_packages.R")
ticrypt_install()
```

The packages compile from source and install into your **personal R library**. When it
finishes you can `library(dplyr)` as usual. Re-running is safe — packages already
installed and up to date are skipped.

Before installing, `ticrypt_install()` checks that TICrypt's **R version** and
**Bioconductor release** match the ones the folder was downloaded for. If they don't match
it **stops** and prints a ready-to-copy `ticrypt_download(...)` command — pre-filled with
this system's R version and OS (and Bioconductor release when it can be determined) and the
packages you requested — so you can paste it on the internet machine, re-download a matching
set, and copy the folder back. Or install anyway with `ticrypt_install(force = TRUE)`.

## Options

- **Include `Suggests`** (optional extras some packages recommend). Set it the *same* on
  both steps:
  ```r
  ticrypt_download(c("tidyverse"), suggests = TRUE)   # download machine
  ticrypt_install(suggests = TRUE)                    # inside TICrypt
  ```
- **Install into a specific library:** `ticrypt_install(lib = "/path/to/library")`.
- **Different folder name:** `ticrypt_download(..., dir = "my_pkgs")` then
  `ticrypt_install(dir = "my_pkgs")`.
- **Target a different TICrypt R** than the script's built-in defaults (normally you don't
  need this — RCS keeps the defaults current). Each setting is an argument to
  `ticrypt_download`, defaulting to the `TICRYPT_*` constant at the top of the file:
  ```r
  ticrypt_download(c("dplyr"),
                   target_r     = "4.4.1",   # TICrypt R version to resolve for
                   bioc_version = "3.19",    # matching Bioconductor release
                   target_os    = "linux")   # linux | macos | windows
  ```
- Run `ticrypt_help()` any time for a reminder.

## If something fails to install

`ticrypt_install()` prints the names of any packages that failed and points to a build log
(`ticrypt_packages/install_logs/<pkg>.out`) with the compiler/error output. The usual
cause is a missing system library (a `-devel` package) on the TICrypt side — share the log
with RCS if you're unsure.

---

### Notes for RCS / admins

The three constants at the top of `ticrypt_packages.R` describe the TICrypt R the
downloads are resolved for. **Update them when TICrypt's R is upgraded** (the download
machine can't detect TICrypt's R on its own):

```r
TICRYPT_R_VERSION    <- "4.5.2"   # R version inside TICrypt
TICRYPT_BIOC_VERSION <- "3.22"    # Bioconductor release tied to that R
TICRYPT_OS           <- "linux"
```

`ticrypt_download()` records these into `TICRYPT_TARGET.dcf` inside the folder, and
`ticrypt_install()` verifies TICrypt's actual R (major.minor) and Bioconductor release
against them, stopping on a mismatch (overridable with `force = TRUE`). So if the constants
are stale relative to TICrypt, a researcher gets a clear error at install time rather than a
confusing build failure — a good signal to update them here. The **R version is the hard
gate**. The Bioconductor check is best-effort: `BiocManager::version()` needs the internet
to validate a release, which TICrypt doesn't have, so when the release can't be determined
offline the Bioc check is **skipped with a note** (the R match already implies the Bioc
release, since the two are locked together) — it never blocks on an unverifiable Bioc
version.

This tool is a researcher-friendly, single-file distillation of the admin air-gap workflow
in [`../install_packages/install_packages.R`](../install_packages/install_packages.R)
(`download` → `offline`). Tests: [`../test/ticrypt/run_ticrypt_test.sh`](../test/ticrypt/run_ticrypt_test.sh),
run in CI on `rocker/r-ver` (see `.github/workflows/test-ticrypt.yml`).
