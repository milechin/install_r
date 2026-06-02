#!/bin/bash
#
# Shared helpers for the R install/migration scripts.
#
# This file is meant to be SOURCED, not executed. It is pure shell and makes no
# `module` calls, so it is safe to source on any machine - including a module-less
# download host. Keep it free of build/toolchain assumptions.
#
#     source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# parse_phase [verb]
#   Normalize and validate the phase verb used by the phase-aware scripts.
#   Echoes the normalized phase (download|install|all) on stdout. An empty/missing
#   verb defaults to "all" (the historical "do everything" behavior). An unknown
#   verb prints a usage message to stderr and returns 1.
#
#   Call as:  PHASE=$(parse_phase "${1:-all}") || exit 1
parse_phase() {
    local verb="${1:-all}"
    case "$verb" in
        download|install|all)
            echo "$verb"
            ;;
        *)
            echo "ERROR: unknown phase '$verb' - expected one of: download, install, all" >&2
            echo "       download: fetch source/artifacts (network, no toolchain)" >&2
            echo "       install : build/install from fetched artifacts (toolchain, no network)" >&2
            echo "       all     : download then install (default)" >&2
            return 1
            ;;
    esac
}

# ensure_dirs MODULE_DIR
#   Create the standard version-directory skeleton (DIST src build install) under
#   the given version directory. Idempotent (mkdir -p). Used by the download phase
#   so the transferred tree is install-ready.
ensure_dirs() {
    local module_dir="$1"
    mkdir -p "$module_dir/DIST" \
             "$module_dir/src" \
             "$module_dir/build" \
             "$module_dir/install"
}

# require_dirs DIR...
#   Exit 1 if any of the given directories is missing. Used by the install phase
#   to assert the (downloaded + transferred) layout exists before building.
require_dirs() {
    local d
    for d in "$@"; do
        if [ ! -d "$d" ]; then
            echo "ERROR: required directory does not exist: $d" >&2
            echo "       Run the 'download' phase first, or transfer the version directory here." >&2
            exit 1
        fi
    done
}

# require_artifact PATH [gzip]
#   Exit 1 if PATH is not a regular non-empty file. If the second arg is "gzip",
#   also verify it is a valid gzip stream (catches a truncated/corrupt transfer).
#   Used by the install phase to confirm the downloaded tarball is present.
require_artifact() {
    local path="$1"
    local verify="${2:-}"
    if [ ! -s "$path" ]; then
        echo "ERROR: required file is missing or empty: $path" >&2
        echo "       Run the 'download' phase first, or transfer the version directory here." >&2
        exit 1
    fi
    if [ "$verify" = "gzip" ] && ! gzip -t "$path" 2>/dev/null; then
        echo "ERROR: file is not a valid gzip archive (corrupt or truncated transfer?): $path" >&2
        exit 1
    fi
}
