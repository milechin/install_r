#!/bin/bash
#
# Configuration PARAMETERS for the R install/migration scripts. This file only
# exports variables and runs no `module load`s, so it is safe to source on any
# machine - including a module-less download host.
#
#   Download (network, no toolchain):
#       source config.sh
#       ./install_R.sh download
#
#   Build/install (needs the toolchain - also source modules.sh):
#       source config.sh
#       source modules.sh
#       ./install_R.sh                # = all (download + install)
#
# Edit the values below for the version you are building.

# R version to build/install (e.g. 4.2.3)
export VERSION="4.2.3"

# Base directory under which R versions are installed (no trailing slash)
export R_PKG_BASE="/share/pkg.8/r"

# CRAN source base URL (no trailing slash). The "R-4" segment tracks the R major
# version, so update it when building a different major release (e.g. R-5).
# install_R.sh downloads $CRAN_SRC_URL/R-$VERSION.tar.gz
export CRAN_SRC_URL="http://cran.r-project.org/src/base/R-4"

# R configure options applied on every build. The install --prefix is added by
# install_R.sh from $INSTALL_DIR, so it is not listed here.
export R_CONFIGURE_OPTS="--enable-R-shlib --enable-memory-profiling --enable-R-profiling --with-valgrind-instrumentation=2"

# Extra configure options used only when a flexiblas module is loaded, so the
# BLAS/LAPACK implementation can be switched at runtime. Single-quoted so the
# pkg-config command substitution is deferred until build time (after the
# flexiblas module is loaded); install_R.sh eval's the configure line.
export R_FLEXIBLAS_CONFIGURE_OPTS='--with-blas="`pkg-config flexiblas --libs`" --with-lapack'
