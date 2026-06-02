#!/bin/bash

# Exit on any error, and make pipelines fail if any stage fails (not just the
# last) - so the `... |& tee` build steps abort the script when make/configure
# fails, instead of being masked by tee's success.
set -e
set -o pipefail


# Author: Katia
# Date: March 15, 2023
# Version 1.2
# 
# Install new version of R
#
# Notes: This script installs a new version of R
# It should be run from within version directory, i.e. /share/pkg.7/r/4.2.3
# the environment variable must be set, i.e export VERSION="4.2.3"

# Modified: April 30, 2024 - configure step modified - added flexblas option
# Modified: June 18, 2023 - modified for pkg.8 (alma8), use gcc/12.2.0 (current default gcc version 8.5.0)



# These come from config.sh - fail clearly if it was not sourced first.
: "${R_PKG_BASE:?R_PKG_BASE is not set - did you 'source config.sh'?}"
: "${VERSION:?VERSION is not set - did you 'source config.sh'?}"

MODULE_DIR="$R_PKG_BASE/$VERSION"
INSTALL_DIR="$R_PKG_BASE/$VERSION/install"
SRC_DIR="$R_PKG_BASE/$VERSION/src"
BUILD_DIR="$R_PKG_BASE/$VERSION/build"

# Directory the R source tarball extracts into (holds the configure script)
R_SOURCE_DIR="$SRC_DIR/R-$VERSION"

# Confirm the expected version directory layout exists before doing anything.
# DIST, src, build and install are created when the R version directory is set
# up; bail out with a clear message if any is missing.
for d in "$MODULE_DIR" "$MODULE_DIR/DIST" "$SRC_DIR" "$BUILD_DIR" "$INSTALL_DIR"; do
    if [ ! -d "$d" ]; then
        echo "ERROR: required directory does not exist: $d" >&2
        echo "       Set up the R $VERSION version directory (DIST, src, build, install) first." >&2
        exit 1
    fi
done

# Obtain the R source tarball into DIST. Either download it from CRAN, or - if
# SOURCE_TARBALL (config.sh) points at an already-downloaded copy - use that
# instead (e.g. a tarball transferred to a machine with no internet access).
TARBALL="$MODULE_DIR/DIST/R-$VERSION.tar.gz"
if [ -n "$SOURCE_TARBALL" ]; then
    echo "Using local source tarball: $SOURCE_TARBALL"
    [ -f "$SOURCE_TARBALL" ] || { echo "ERROR: SOURCE_TARBALL not found: $SOURCE_TARBALL" >&2; exit 1; }
    cp -f "$SOURCE_TARBALL" "$TARBALL"
else
    # Download source from https://cran.r-project.org/ . -O writes a fixed path so
    # a re-run overwrites cleanly instead of creating R-$VERSION.tar.gz.1
    wget -O "$TARBALL" "$CRAN_SRC_URL/R-$VERSION.tar.gz"
fi


# untar the sources into the R source directory
mkdir -p $R_SOURCE_DIR
tar xzf "$TARBALL" -C $R_SOURCE_DIR --strip-components=1

# configure
# (build modules - texlive, gcc, flexiblas - are loaded by config.sh)
cd $BUILD_DIR

# Assemble configure options. Base options come from $R_CONFIGURE_OPTS (config.sh);
# the install prefix is added here.
CONFIGURE_OPTS="--prefix=$INSTALL_DIR $R_CONFIGURE_OPTS"

# April 30, 2024: add flexiblas option to allow switching between various blas
# implementations - but only when a flexiblas module is actually loaded.
if module list 2>&1 | grep -q flexiblas; then
    echo "flexiblas module detected - building R with flexiblas BLAS/LAPACK support"
    CONFIGURE_OPTS="$CONFIGURE_OPTS $R_FLEXIBLAS_CONFIGURE_OPTS"
fi

# eval so the (deferred) pkg-config command substitution in the flexiblas options
# runs now and its quotes group the BLAS libs into a single argument.
eval "$R_SOURCE_DIR/configure $CONFIGURE_OPTS" |& tee config.out


#build
make |&tee make.output
make install |&tee make.install.output
# make check runs R's test suite; keep it non-fatal (set -e) since individual
# test failures don't necessarily mean a broken/unusable R - just review the log.
make check |&tee make.check.output || echo "WARNING: make check reported failures - review make.check.output"



# Make a soft link to the man page
cd $INSTALL_DIR
ln -s share/man man


# Copy gcc runtime shared libraries into R's lib dir so R starts without the gcc
# module loaded. The library is located via the currently loaded gcc itself
# (gcc -print-file-name), so it always matches the gcc used to build R - no
# hard-coded paths or version numbers - and its version symlinks are recreated.
copy_gcc_runtime_lib() {
    local query="$1"                 # library to locate, e.g. libgfortran.so
    local src realfile soname devlink target

    src=$(readlink -f "$(gcc -print-file-name="$query")")
    if [ ! -f "$src" ]; then
        echo "WARNING: could not locate $query via gcc - skipping"
        return 1
    fi

    realfile=$(basename "$src")
    cp -f "$src" .
    echo "Found $query: copied $src"

    # Recreate the soname link, e.g. libgfortran.so.5 -> libgfortran.so.5.0.0
    soname=$(objdump -p "$src" 2>/dev/null | awk '/SONAME/ {print $2}')
    if [ -n "$soname" ] && [ "$soname" != "$realfile" ]; then
        ln -sf "$realfile" "$soname"
        echo "  linked $soname -> $realfile"
    fi

    # Recreate the bare .so link, e.g. libgfortran.so -> libgfortran.so.5
    devlink="${query%%.so*}.so"
    target="${soname:-$realfile}"
    if [ "$devlink" != "$realfile" ] && [ "$devlink" != "$target" ]; then
        ln -sf "$target" "$devlink"
        echo "  linked $devlink -> $target"
    fi
}

cd lib64/R/lib
copy_gcc_runtime_lib libgfortran.so    # Fortran runtime
copy_gcc_runtime_lib libstdc++.so      # needed by Rcpp and packages that use it
copy_gcc_runtime_lib libgcc_s.so.1     # gcc low-level support library


# Go back to the main install directory
cd $INSTALL_DIR


# Point R at the system default Java using R's supported javareconf tool, which
# rewrites the Java settings in etc/ldpaths and Makeconf. /usr/java/default is the
# system-maintained symlink to the current JDK, so if Mike upgrades Java the symlink
# is re-pointed and R picks up the newer version - without breaking rJava and the
# packages that depend on it. javareconf preserves the symlink path (it does not
# resolve it to a versioned path), so nothing here is pinned to a Java version.
JAVA_HOME="/usr/java/default"
[ -d "$JAVA_HOME/jre" ] && JAVA_HOME="$JAVA_HOME/jre"   # older JDKs (e.g. 8) nest the runtime under jre/
export JAVA_HOME

echo "Configuring R to use system default Java: $JAVA_HOME (currently resolves to $(readlink -f "$JAVA_HOME"))"
$INSTALL_DIR/bin/R CMD javareconf JAVA_HOME="$JAVA_HOME"
#--------------------------------------


#----------------------------
# Done
#----------------------------
echo ""
echo "================================================================"
echo "R $VERSION built and installed to: $INSTALL_DIR"
echo ""
echo "Next steps (run separately, after confirming R works):"
echo "  - Install BiocManager + tidyverse:"
echo "      $INSTALL_DIR/bin/Rscript $R_PKG_BASE/install_bioconductor.R |& tee $BUILD_DIR/install_bioconductor.output"
echo "================================================================"
