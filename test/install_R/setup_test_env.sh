#!/bin/bash
#
# Create the version directory layout that install_R.sh expects, inside the test
# sandbox defined by test_config.sh (DIST, src, build, install under
# $R_PKG_BASE/$VERSION). Safe to re-run. Sourcing test_config.sh first is what
# defines VERSION and R_PKG_BASE.
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/test_config.sh"

VERSION_DIR="$R_PKG_BASE/$VERSION"

echo "Setting up test version directory: $VERSION_DIR"
mkdir -p "$VERSION_DIR/DIST" \
         "$VERSION_DIR/src" \
         "$VERSION_DIR/build" \
         "$VERSION_DIR/install"

echo "Created DIST, src, build, install under $VERSION_DIR"
