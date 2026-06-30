#!/bin/bash
#
# Exercise ticrypt/ticrypt_packages.R end-to-end: the researcher round-trip
# download -> (copy folder) -> install, for a CRAN package (+ dependency) and a
# Bioconductor package (+ dependency). Like run_package_test.sh this does NOT build R -
# it just needs an R/Rscript on PATH (e.g. a rocker/r-ver image), so it is fast.
#
#     bash test/ticrypt/run_ticrypt_test.sh
#
# The download leg needs network access to CRAN/Bioconductor. The install leg is purely
# local (a file:// repo), exactly as it runs inside the air-gapped TICrypt environment.
# The download "target" R is the running R (so resolution matches what we then install).
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
export SCRIPT="$REPO_ROOT/ticrypt/ticrypt_packages.R"

RSCRIPT="${RSCRIPT:-Rscript}"
command -v "$RSCRIPT" >/dev/null 2>&1 || { echo "ERROR: '$RSCRIPT' not found on PATH" >&2; exit 1; }

SANDBOX="${TEST_ROOT:-$HERE/ticrypt_test_sandbox}"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"; cd "$SANDBOX"
export R_LIBS="$SANDBOX/userlib"; mkdir -p "$R_LIBS"   # writable default library for bootstraps

pass() { echo "  OK: $1"; }
fail() { echo "  FAIL: $1" >&2; exit 1; }

assert_file()      { [ -e "$1" ] || fail "$2 missing ($1)"; pass "$2 present"; }
assert_installed() { [ -f "$1/$2/DESCRIPTION" ] || fail "$2 not installed in $1"; pass "$2 installed in ${1##*/}"; }

# Resolve the download target (R version + matching Bioconductor release) to the running R.
"$RSCRIPT" -e '
if (!requireNamespace("BiocManager", quietly = TRUE))
  install.packages("BiocManager", repos = "https://cran.r-project.org")
writeLines(c(as.character(getRversion()), as.character(BiocManager::version())), "target.txt")
'
RV="$(sed -n 1p target.txt)"; BV="$(sed -n 2p target.txt)"
echo "Target R $RV / Bioconductor $BV"

# ---------------------------------------------------------------------------
echo "=== 1. CRAN download leg: tarballs (+dep) + self-copied script land in the folder ==="
RV="$RV" BV="$BV" "$RSCRIPT" -e '
source(Sys.getenv("SCRIPT"))
ticrypt_download(c("lgr"), dir = "dl", target_r = Sys.getenv("RV"), bioc_version = Sys.getenv("BV"))
'
assert_file "dl/PACKAGES" "PACKAGES index"
assert_file "$(ls dl/lgr_*.tar.gz 2>/dev/null | head -1)" "lgr source tarball"
assert_file "$(ls dl/R6_*.tar.gz  2>/dev/null | head -1)" "R6 dependency tarball"
assert_file "dl/ticrypt_packages.R" "self-copied installer script"
assert_file "dl/REQUESTED.txt" "REQUESTED.txt manifest"

# ---------------------------------------------------------------------------
echo "=== 2. CRAN install leg: install from the COPIED folder's own script, no network ==="
# Source dl/ticrypt_packages.R (the self-copied one) to prove the transferred folder is
# self-contained, and install into a fresh library.
"$RSCRIPT" -e '
source("dl/ticrypt_packages.R")
ticrypt_install(dir = "dl", lib = "lib_cran")
'
assert_installed "$SANDBOX/lib_cran" lgr
assert_installed "$SANDBOX/lib_cran" R6   # dependency compiled from the local folder

# ---------------------------------------------------------------------------
echo "=== 3. Bioconductor round-trip: download a Bioc package (+dep), install offline ==="
RV="$RV" BV="$BV" "$RSCRIPT" -e '
source(Sys.getenv("SCRIPT"))
ticrypt_download(c("BiocGenerics"), dir = "dlb", target_r = Sys.getenv("RV"), bioc_version = Sys.getenv("BV"))
'
assert_file "$(ls dlb/BiocGenerics_*.tar.gz 2>/dev/null | head -1)" "BiocGenerics source tarball"
"$RSCRIPT" -e 'source("dlb/ticrypt_packages.R"); ticrypt_install(dir = "dlb", lib = "lib_bioc")'
assert_installed "$SANDBOX/lib_bioc" BiocGenerics

# ---------------------------------------------------------------------------
echo "=== 4. re-run install is idempotent (already-current packages skipped) ==="
out=$("$RSCRIPT" -e 'source("dl/ticrypt_packages.R"); ticrypt_install(dir = "dl", lib = "lib_cran")' 2>&1)
echo "$out" | grep -q "up to date, skipping: lgr" || fail "re-run did not skip already-installed lgr"
pass "re-run skipped already-current packages"

echo
echo "=== ALL TICRYPT TESTS PASSED ==="
