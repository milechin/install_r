#!/bin/bash
#
# Build toolchain modules for building R from source.
#
# Source this (in addition to config.sh) before running the install/build phase:
#
#     source config.sh      # parameters
#     source modules.sh      # build toolchain
#     ./install_R.sh         # build (= all)
#
# This is SEPARATE from config.sh so the download phase can source config.sh for
# its parameters on a machine that has no module system at all:
#
#     source config.sh
#     ./install_R.sh download
#
# Comment out the flexiblas line to build R without flexiblas BLAS/LAPACK support
# (install_R.sh detects whether a flexiblas module is loaded).
module load texlive/2022
module load gcc/12.2.0
module load flexiblas/3.3.1
