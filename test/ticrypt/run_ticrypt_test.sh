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
assert_file "dl/TICRYPT_TARGET.dcf" "download-target metadata"
grep -q "RVersion: $RV" dl/TICRYPT_TARGET.dcf || fail "TICRYPT_TARGET.dcf missing RVersion $RV"
grep -q "BiocVersion: $BV" dl/TICRYPT_TARGET.dcf || fail "TICRYPT_TARGET.dcf missing BiocVersion $BV"
pass "target metadata records R $RV / Bioconductor $BV"

# ---------------------------------------------------------------------------
echo "=== 2. CRAN install leg: install from the COPIED folder's own script, no network ==="
# Source dl/ticrypt_packages.R (the self-copied one) to prove the transferred folder is
# self-contained, and install into a fresh library. The download target equals the running
# R here, so the version check must pass and announce the match.
out=$("$RSCRIPT" -e '
source("dl/ticrypt_packages.R")
ticrypt_install(dir = "dl", lib = "lib_cran")
' 2>&1)
echo "$out" | grep -q "Environment matches download target" || fail "version check did not confirm a match"
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

# ---------------------------------------------------------------------------
echo "=== 5. version mismatch: install stops, force = TRUE overrides ==="
# Tamper a copy's recorded R version so it no longer matches the running R.
cp -r dl dlm
sed -i 's/^RVersion:.*/RVersion: 1.2.0/' dlm/TICRYPT_TARGET.dcf
if "$RSCRIPT" -e 'source("dlm/ticrypt_packages.R"); ticrypt_install(dir = "dlm", lib = "lib_mm")' >mm.out 2>&1; then
  fail "install did not stop on an R-version mismatch"
fi
grep -q "downloaded for a different environment" mm.out || fail "mismatch message not shown"
[ -d "$SANDBOX/lib_mm/lgr" ] && fail "packages were installed despite the mismatch"
pass "install stopped on mismatch and installed nothing"
# The guidance must include a ready-to-copy download command with this system's R + OS.
grep -q "ticrypt_download(" mm.out || fail "no copy-pasteable ticrypt_download command shown"
grep -q "target_r = \"$RV\"" mm.out || fail "suggested command missing correct target_r ($RV)"
grep -q 'target_os = "linux"' mm.out || fail "suggested command missing target_os"
grep -q '"lgr"' mm.out || fail "suggested command not pre-filled with the requested packages"
pass "mismatch output includes a copy-pasteable download command for this system"

"$RSCRIPT" -e 'source("dlm/ticrypt_packages.R"); ticrypt_install(dir = "dlm", lib = "lib_mm", force = TRUE)' >mmf.out 2>&1 \
  || { cat mmf.out; fail "force = TRUE did not install"; }
grep -q "proceeding despite an environment mismatch" mmf.out || fail "force override notice not shown"
assert_installed "$SANDBOX/lib_mm" lgr
pass "force = TRUE overrode the mismatch and installed"

# ---------------------------------------------------------------------------
echo "=== 6. offline: undeterminable Bioconductor release is skipped, not a mismatch ==="
# Simulate TICrypt (no internet): make BiocManager::version() fail as it would when it
# can't validate online. The Bioc check must be SKIPPED (not turned into a mismatch), the
# R check still passes, and the install proceeds without force.
out=$("$RSCRIPT" -e '
suppressWarnings(assignInNamespace("version", function(...) stop("offline"), "BiocManager"))
source("dl/ticrypt_packages.R")
ticrypt_install(dir = "dl", lib = "lib_offline_bioc")
' 2>&1) || { echo "$out"; fail "install failed when Bioc release was undeterminable"; }
echo "$out" | grep -q "could not determine this system's Bioconductor release" \
  || fail "did not note the skipped Bioconductor check"
echo "$out" | grep -q "Bioconductor: downloaded for" && fail "reported a bogus Bioc mismatch offline"
assert_installed "$SANDBOX/lib_offline_bioc" lgr
pass "undeterminable Bioc release was skipped and install proceeded"

# ---------------------------------------------------------------------------
echo "=== 7. a determinable Bioconductor mismatch does stop ==="
# When BiocManager CAN report a release (online here), a genuinely wrong recorded Bioc
# version is caught as a mismatch.
cp -r dl dlb2
sed -i 's/^BiocVersion:.*/BiocVersion: 1.0/' dlb2/TICRYPT_TARGET.dcf
if "$RSCRIPT" -e 'source("dlb2/ticrypt_packages.R"); ticrypt_install(dir = "dlb2", lib = "lib_bmm")' >bmm.out 2>&1; then
  fail "install did not stop on a Bioconductor mismatch"
fi
grep -q "Bioconductor: downloaded for 1.0" bmm.out || fail "Bioconductor mismatch not reported"
pass "determinable Bioconductor mismatch stopped the install"

echo
echo "=== ALL TICRYPT TESTS PASSED ==="
