#!/bin/bash
#
# Test configuration for running install_R.sh in CI (e.g. GitHub Actions).
#
# This mirrors config.sh but with NO `module load` lines - a CI runner has no
# environment-module system; the toolchain (gcc, gfortran, make, ...) is provided
# by the system package manager instead. Source this before running the build,
# exactly like config.sh:
#
#     source test/install_R/test_config.sh
#     bash test/install_R/run_test.sh

# Root of the test sandbox. Defaults to a "test_pkg" dir next to this script;
# override by exporting TEST_ROOT before sourcing.
: "${TEST_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_pkg}"

# Build R in parallel to keep CI fast (install_R.sh runs plain `make`, which
# honors MAKEFLAGS from the environment).
export MAKEFLAGS="-j$(nproc)"

# --- the same variables config.sh defines (minus the module loads) ---

# R version to build/install. Honors a VERSION already set in the environment
# (e.g. from a GitHub Actions workflow_dispatch input); otherwise uses the default.
export VERSION="${VERSION:-4.4.3}"

# Base directory under which R versions are installed (no trailing slash),
# pointed into the test sandbox instead of /share/pkg.8/r.
export R_PKG_BASE="$TEST_ROOT/r"

# CRAN source base URL (no trailing slash)
export CRAN_SRC_URL="https://cran.r-project.org/src/base/R-4"

# Minimal configure options for a CI runner: no X11, no valgrind instrumentation,
# and skip the recommended packages so the build stays fast. (Production uses the
# fuller set in config.sh.)
export R_CONFIGURE_OPTS="--enable-R-shlib --with-x=no --without-recommended-packages"

# flexiblas is not present in CI. install_R.sh only appends these when a flexiblas
# module is loaded (it won't be here), but define the variable so it is always set.
export R_FLEXIBLAS_CONFIGURE_OPTS='--with-blas="`pkg-config flexiblas --libs`" --with-lapack'
