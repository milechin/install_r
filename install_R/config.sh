#!/bin/bash
#
# Configuration parameters for the R install/migration scripts.
# Source this file before running install_R.sh:
#
#     source config.sh
#     ./install_R.sh
#
# Edit the values below for the version you are building.

# Build toolchain modules. These are loaded when this file is sourced, so the
# environment is ready before install_R.sh runs. Comment out the flexiblas line
# to build R without flexiblas BLAS/LAPACK support (install_R.sh detects whether
# a flexiblas module is loaded).
module load texlive/2022
module load gcc/12.2.0
module load flexiblas/3.3.1

# R version to build/install (e.g. 4.2.3)
export VERSION="4.2.3"

# Base directory under which R versions are installed (no trailing slash)
export R_PKG_BASE="/share/pkg.8/r"

# CRAN source base URL (no trailing slash). The "R-4" segment tracks the R major
# version, so update it when building a different major release (e.g. R-5).
# install_R.sh downloads $CRAN_SRC_URL/R-$VERSION.tar.gz
export CRAN_SRC_URL="http://cran.r-project.org/src/base/R-4"

# Source tarball selection:
#   empty  -> download R-$VERSION.tar.gz from $CRAN_SRC_URL (the default)
#   a path -> use that already-downloaded tarball instead of fetching (e.g. a copy
#             transferred to a machine with no internet). It is copied into DIST.
export SOURCE_TARBALL=""

# R configure options applied on every build. The install --prefix is added by
# install_R.sh from $INSTALL_DIR, so it is not listed here.
export R_CONFIGURE_OPTS="--enable-R-shlib --enable-memory-profiling --enable-R-profiling --with-valgrind-instrumentation=2"

# Extra configure options used only when a flexiblas module is loaded, so the
# BLAS/LAPACK implementation can be switched at runtime. Single-quoted so the
# pkg-config command substitution is deferred until build time (after the
# flexiblas module is loaded); install_R.sh eval's the configure line.
export R_FLEXIBLAS_CONFIGURE_OPTS='--with-blas="`pkg-config flexiblas --libs`" --with-lapack'
