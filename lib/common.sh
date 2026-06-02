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

# ensure_dirs DIR...
#   Create each given directory (and parents). Idempotent (mkdir -p). The download
#   phase uses it to create just DIST; the install phase uses it to create the
#   build-side dirs (src/build/install) at the location from the target's config.
ensure_dirs() {
    mkdir -p "$@"
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
        echo "       Run the 'download' phase first, or copy the file (e.g. the DIST tarball) here." >&2
        exit 1
    fi
    if [ "$verify" = "gzip" ] && ! gzip -t "$path" 2>/dev/null; then
        echo "ERROR: file is not a valid gzip archive (corrupt or truncated transfer?): $path" >&2
        exit 1
    fi
}
