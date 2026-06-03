#!/bin/bash
#
# Exercise install_packages.R end-to-end: the air-gap download -> offline install
# round-trip, the normal online install, and the download-mode resolution knobs
# (TARGET_R_VERSION filter, INCLUDE_SUGGESTS). Unlike run_test.sh this does NOT build
# R - it just needs an R/Rscript on PATH (e.g. a rocker/r-ver image), so it is fast.
#
#     bash test/install_packages/run_package_test.sh
#
# It needs network access to CRAN for the download/online steps. The offline step
# installs purely from the local DIST repo produced by the download step.
#
# Test packages (all pure R, no compilation, deterministic):
#   lgr      -> depends on R6   (both absent from a fresh R, so the dep is really
#                                pulled from DIST during the offline install)
#   fortunes, praise            -> zero-dependency, for the online / back-compat checks
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/install_packages/install_packages.R"

RSCRIPT="${RSCRIPT:-Rscript}"
command -v "$RSCRIPT" >/dev/null 2>&1 || { echo "ERROR: '$RSCRIPT' not found on PATH" >&2; exit 1; }

SANDBOX="${TEST_ROOT:-$HERE/pkg_test_sandbox}"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cd "$SANDBOX"

pass() { echo "  OK: $1"; }
fail() { echo "  FAIL: $1" >&2; exit 1; }

# A package is "installed" in a library if its directory holds a DESCRIPTION file.
assert_installed() {   # <lib> <pkg>
    [ -f "$1/$2/DESCRIPTION" ] || fail "$2 not installed in $1"
    pass "$2 installed in ${1##*/}"
}
assert_file() {        # <path> <label>
    [ -e "$1" ] || fail "$2 missing ($1)"
    pass "$2 present"
}

# ---------------------------------------------------------------------------
echo "=== 1. download mode: build a local DIST repo for lgr (+ dep R6) ==="
printf 'Package\nlgr\n' > list.txt
DIST="$SANDBOX/DIST"
DIST_DIR="$DIST" "$RSCRIPT" "$SCRIPT" download list.txt

assert_file "$DIST/PACKAGES" "PACKAGES index"
assert_file "$(ls "$DIST"/lgr_*.tar.gz 2>/dev/null | head -1)" "lgr source tarball"
assert_file "$(ls "$DIST"/R6_*.tar.gz  2>/dev/null | head -1)" "R6 dependency tarball"

# ---------------------------------------------------------------------------
echo "=== 2. offline mode: install lgr from DIST (no CRAN), dep R6 auto-pulled ==="
OFFLIB="$SANDBOX/lib_offline"
mkdir -p "$OFFLIB"
R_LIBS="$OFFLIB" DIST_DIR="$DIST" "$RSCRIPT" "$SCRIPT" offline list.txt
assert_installed "$OFFLIB" lgr
assert_installed "$OFFLIB" R6   # proves dependency resolution from the local repo

# ---------------------------------------------------------------------------
echo "=== 3. online mode: install a zero-dep package from CRAN ==="
ONLIB="$SANDBOX/lib_online"
mkdir -p "$ONLIB"
printf 'Package\nfortunes\n' > online.txt
R_LIBS="$ONLIB" "$RSCRIPT" "$SCRIPT" online online.txt
assert_installed "$ONLIB" fortunes

# ---------------------------------------------------------------------------
echo "=== 4. back-compat: no mode arg behaves as online (list file as first arg) ==="
BCLIB="$SANDBOX/lib_backcompat"
mkdir -p "$BCLIB"
printf 'Package\npraise\n' > bc.txt
out=$(R_LIBS="$BCLIB" "$RSCRIPT" "$SCRIPT" bc.txt 2>&1)
echo "$out" | grep -q "Mode: online" || fail "expected online mode when first arg is a file"
pass "first arg treated as list file, mode defaulted to online"
assert_installed "$BCLIB" praise

# ---------------------------------------------------------------------------
echo "=== 5. TARGET_R_VERSION filter: too-old target drops lgr (needs R >= 3.2) ==="
DIST_OLD="$SANDBOX/DIST_old"
out=$(TARGET_R_VERSION=3.0.0 DIST_DIR="$DIST_OLD" "$RSCRIPT" "$SCRIPT" download list.txt 2>&1)
echo "$out"
echo "$out" | grep -q "Resolving packages for R 3.0.0" || fail "criteria not printed"
[ -z "$(ls "$DIST_OLD"/lgr_*.tar.gz 2>/dev/null)" ] || fail "lgr should have been filtered out for R 3.0.0"
pass "lgr filtered out for target R 3.0.0"

# ---------------------------------------------------------------------------
echo "=== 6. INCLUDE_SUGGESTS grows the closure ==="
count() { ls "$1"/*.tar.gz 2>/dev/null | wc -l | tr -d ' '; }
DIST_H="$SANDBOX/DIST_hard"; DIST_S="$SANDBOX/DIST_sug"
DIST_DIR="$DIST_H" "$RSCRIPT" "$SCRIPT" download list.txt >/dev/null
INCLUDE_SUGGESTS=1 DIST_DIR="$DIST_S" "$RSCRIPT" "$SCRIPT" download list.txt >/dev/null
n_hard=$(count "$DIST_H"); n_sug=$(count "$DIST_S")
echo "  hard-deps closure: $n_hard tarballs;  with Suggests: $n_sug tarballs"
[ "$n_sug" -gt "$n_hard" ] || fail "INCLUDE_SUGGESTS did not enlarge the closure ($n_sug !> $n_hard)"
pass "INCLUDE_SUGGESTS enlarged the closure ($n_hard -> $n_sug)"

# ---------------------------------------------------------------------------
echo "=== 7. online mode falls back to a real mirror when none is configured ==="
# --vanilla skips the site/user profiles, so getOption('repos')['CRAN'] is the
# unresolved '@CRAN@' placeholder - the situation that used to fail with
# "trying to use CRAN without setting a mirror".
VLIB="$SANDBOX/lib_vanilla"
mkdir -p "$VLIB"
printf 'Package\nrmsfact\n' > vanilla.txt
out=$(R_LIBS="$VLIB" "$RSCRIPT" --vanilla "$SCRIPT" online vanilla.txt 2>&1)
echo "$out" | grep -qE "Installing from CRAN: https?://" || fail "online did not fall back to a real CRAN mirror"
if echo "$out" | grep -q "without setting a mirror"; then fail "hit the 'no CRAN mirror' error"; fi
assert_installed "$VLIB" rmsfact
pass "online fell back to a CRAN mirror under the @CRAN@ placeholder"

# ---------------------------------------------------------------------------
echo "=== 8. failures are logged and a retry list + command are produced ==="
# Offline-install a package that is not in DIST: it must be reported FAILED (not a
# false SUCCESS), recorded in the log, and written to failed_packages.txt with a
# printed retry command.
FLIB="$SANDBOX/lib_fail"
mkdir -p "$FLIB"
BOGUS="this_package_does_not_exist_zzz"
printf 'Package\n%s\n' "$BOGUS" > faillist.txt
out=$(R_LIBS="$FLIB" DIST_DIR="$DIST" "$RSCRIPT" "$SCRIPT" offline faillist.txt 2>&1)
echo "$out" | grep -q "FAILED: $BOGUS" || fail "failure not reported on console"
echo "$out" | grep -q "To retry only the failed packages" || fail "retry command not printed"
[ -f "$SANDBOX/failed_packages.txt" ] || fail "failed_packages.txt not written"
grep -q "$BOGUS" "$SANDBOX/failed_packages.txt" || fail "failed package missing from failed_packages.txt"
grep -q "FAILED: $BOGUS" "$SANDBOX/package_installation_log.txt" || fail "failure not recorded in log file"
pass "failure logged + failed_packages.txt + retry command produced"

echo
echo "=== ALL PACKAGE TESTS PASSED ==="
