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
# Notes: This script installs a new version of R.
# Source config.sh (parameters) first; for the install/build phase also source
# modules.sh (build toolchain). See the usage in those files.
#
# Phases (subcommand):
#   ./install_R.sh download   - fetch the R source tarball (network, no toolchain;
#                               creates the DIST/src/build/install skeleton)
#   ./install_R.sh install    - build + install from the fetched source (toolchain,
#                               no network; requires the skeleton + tarball present)
#   ./install_R.sh            - "all": download then install (default; backward
#                               compatible with the original one-shot behavior)
#
# Modified: <today> - split into download/install phases; modules moved to modules.sh
# Modified: April 30, 2024 - configure step modified - added flexblas option
# Modified: June 18, 2023 - modified for pkg.8 (alma8), use gcc/12.2.0 (current default gcc version 8.5.0)



# Locate this script's directory and source the shared helpers (pure shell, no
# module calls - safe even on a module-less download host).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# These come from config.sh - fail clearly if it was not sourced first.
: "${R_PKG_BASE:?R_PKG_BASE is not set - did you 'source config.sh'?}"
: "${VERSION:?VERSION is not set - did you 'source config.sh'?}"

# Which phase to run (download|install|all); default "all".
PHASE=$(parse_phase "${1:-all}") || exit 1

MODULE_DIR="$R_PKG_BASE/$VERSION"
INSTALL_DIR="$R_PKG_BASE/$VERSION/install"
SRC_DIR="$R_PKG_BASE/$VERSION/src"
BUILD_DIR="$R_PKG_BASE/$VERSION/build"

# Directory the R source tarball extracts into (holds the configure script)
R_SOURCE_DIR="$SRC_DIR/R-$VERSION"

# Path to the downloaded source tarball (the transferable artifact)
SRC_TARBALL="$MODULE_DIR/DIST/R-$VERSION.tar.gz"


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


# ---------------------------------------------------------------------------
# DOWNLOAD phase: fetch the R source into DIST. Network required; no toolchain.
# Creates ONLY the DIST folder - the build-side directories (src/build/install)
# are created by the install phase from the target machine's own config. DIST
# (the tarball) is the unit you transfer to the build/target machine.
# ---------------------------------------------------------------------------
run_download() {
    echo "=== download: R $VERSION -> $MODULE_DIR/DIST ==="
    ensure_dirs "$MODULE_DIR/DIST"

    # Download source from https://cran.r-project.org/ . -O writes to a fixed
    # path so a re-run overwrites cleanly instead of creating R-$VERSION.tar.gz.1
    wget -O "$SRC_TARBALL" "$CRAN_SRC_URL/R-$VERSION.tar.gz"

    echo "Downloaded $SRC_TARBALL"
    echo "To build on another machine, transfer the DIST folder, e.g.:"
    echo "    tar czf r-$VERSION-dist.tar.gz -C $MODULE_DIR DIST"
    echo "then on the target (after 'source config.sh'): place it at \$MODULE_DIR/DIST and run './install_R.sh install'"
}


# ---------------------------------------------------------------------------
# INSTALL phase: build + install from the fetched source. Toolchain required
# (source config.sh + modules.sh); no network. Needs the DIST tarball present
# (downloaded here, or transferred to $MODULE_DIR/DIST from another machine).
# ---------------------------------------------------------------------------
run_install() {
    echo "=== install: building R $VERSION into $INSTALL_DIR ==="

    # Require the source tarball (the only thing the download phase / transfer
    # provides); fail clearly up front instead of mid-build. gzip -t also catches
    # a truncated transfer.
    require_artifact "$SRC_TARBALL" gzip

    # Create the build-side directories at the location from this machine's config
    # (the target owns its own layout via config.sh). Idempotent.
    ensure_dirs "$SRC_DIR" "$BUILD_DIR" "$INSTALL_DIR"

    # untar the sources into the R source directory
    mkdir -p "$R_SOURCE_DIR"
    tar xzf "$SRC_TARBALL" -C "$R_SOURCE_DIR" --strip-components=1

    # configure
    # (build modules - texlive, gcc, flexiblas - are loaded by modules.sh)
    cd "$BUILD_DIR"

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
    cd "$INSTALL_DIR"
    ln -s share/man man

    # Copy gcc runtime shared libraries into R's lib dir (see function above).
    cd lib64/R/lib
    copy_gcc_runtime_lib libgfortran.so    # Fortran runtime
    copy_gcc_runtime_lib libstdc++.so      # needed by Rcpp and packages that use it
    copy_gcc_runtime_lib libgcc_s.so.1     # gcc low-level support library

    # Go back to the main install directory
    cd "$INSTALL_DIR"

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
    "$INSTALL_DIR/bin/R" CMD javareconf JAVA_HOME="$JAVA_HOME"

    echo ""
    echo "================================================================"
    echo "R $VERSION built and installed to: $INSTALL_DIR"
    echo ""
    echo "Next steps (run separately, after confirming R works):"
    echo "  - Install BiocManager + tidyverse:"
    echo "      $INSTALL_DIR/bin/Rscript $R_PKG_BASE/install_bioconductor.R |& tee $BUILD_DIR/install_bioconductor.output"
    echo "================================================================"
}


# --- dispatch ---
case "$PHASE" in
    download) run_download ;;
    install)  run_install ;;
    all)      run_download; run_install ;;
esac
