#!/bin/bash
#
# Run install_R.sh end-to-end against the test sandbox, then smoke-test the
# resulting R. Designed to run on AlmaLinux, Rocky, or Ubuntu images (the cluster
# is alma8). A single command on a fresh image does everything:
#
#     bash test/install_R/run_test.sh
#
# Set SKIP_DEPS=1 to skip the system-package install step (e.g. if the toolchain
# and /usr/java/default are already in place).
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# 1. Install build dependencies + JDK for this distro (unless told to skip).
if [ "${SKIP_DEPS:-0}" = "1" ]; then
    echo "SKIP_DEPS=1 - skipping system dependency install"
else
    bash "$HERE/install_deps.sh"
fi

# 2. Load the test config (exports VERSION, R_PKG_BASE, ...; no module loads).
source "$HERE/test_config.sh"

# 3. Create the directory layout install_R.sh requires.
bash "$HERE/setup_test_env.sh"

# 4. install_R.sh's final banner references $R_PKG_BASE/install_bioconductor.R;
#    copy it into the sandbox so that printed path is valid (it is only echoed).
cp "$REPO_ROOT/install_R/install_bioconductor.R" "$R_PKG_BASE/"

# 5. Build R. install_R.sh inherits the exported config vars from step 2.
echo "=== Running install_R.sh for R $VERSION ==="
bash "$REPO_ROOT/install_R/install_R.sh"

# 6. Smoke-test the freshly built R.
R_BIN="$R_PKG_BASE/$VERSION/install/bin/R"
echo "=== Verifying $R_BIN ==="
if [ ! -x "$R_BIN" ]; then
    echo "ERROR: expected R binary not found at $R_BIN" >&2
    exit 1
fi
"$R_BIN" --version
"$R_BIN" --slave -e 'cat("R runs OK:", R.version.string, "\n"); quit(status = 0)'

echo "=== TEST PASSED ==="
