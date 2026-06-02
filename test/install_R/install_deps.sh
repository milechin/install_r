#!/bin/bash
#
# Install the system packages needed to build R from source, plus a JDK, on the
# distro the test is running on. Supports the RHEL family (AlmaLinux, Rocky -
# matching the cluster's alma8) via dnf/yum, and Ubuntu/Debian via apt.
#
# Also creates the /usr/java/default symlink that install_R.sh's `R CMD
# javareconf` step expects (the cluster maintains it; a plain CI image does not).
#
# Idempotent. Uses sudo when not already root (containers usually run as root).
set -e

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

install_rhel() {
    echo "Detected RHEL-family distro - installing build deps with $1"
    local pm="$1"

    # Several build deps (texinfo, and many -devel packages) live in the
    # PowerTools (el8) / CRB (el9) repo and in EPEL, which are not enabled by
    # default in the stock container images. Enable them first.
    local elver
    elver="$(. /etc/os-release && echo "${VERSION_ID%%.*}")"
    $SUDO "$pm" install -y dnf-plugins-core epel-release
    if [ "$elver" -ge 9 ] 2>/dev/null; then
        $SUDO "$pm" config-manager --set-enabled crb
    else
        $SUDO "$pm" config-manager --set-enabled powertools
    fi

    $SUDO "$pm" install -y \
        gcc gcc-c++ gcc-gfortran make wget which tar gzip pkgconfig texinfo \
        pcre2-devel bzip2-devel xz-devel zlib-devel readline-devel \
        libcurl-devel libicu-devel openssl-devel \
        java-17-openjdk-devel
}

install_debian() {
    echo "Detected Debian-family distro - installing build deps with apt-get"
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update
    $SUDO apt-get install -y --no-install-recommends \
        build-essential gfortran make wget pkg-config texinfo \
        libpcre2-dev libbz2-dev liblzma-dev zlib1g-dev libreadline-dev \
        libcurl4-openssl-dev libicu-dev libssl-dev \
        openjdk-17-jdk-headless
}

if command -v dnf >/dev/null 2>&1; then
    install_rhel dnf
elif command -v yum >/dev/null 2>&1; then
    install_rhel yum
elif command -v apt-get >/dev/null 2>&1; then
    install_debian
else
    echo "ERROR: no supported package manager (dnf/yum/apt-get) found" >&2
    exit 1
fi

# Point /usr/java/default at the JDK we just installed, derived from javac's
# real location, so install_R.sh's hard-coded JAVA_HOME=/usr/java/default works.
JAVA_BIN="$(command -v javac || command -v java)"
if [ -z "$JAVA_BIN" ]; then
    echo "ERROR: no java/javac on PATH after install" >&2
    exit 1
fi
JDK_HOME="$(dirname "$(dirname "$(readlink -f "$JAVA_BIN")")")"
echo "Linking /usr/java/default -> $JDK_HOME"
$SUDO mkdir -p /usr/java
$SUDO ln -sfn "$JDK_HOME" /usr/java/default
ls -l /usr/java/default
