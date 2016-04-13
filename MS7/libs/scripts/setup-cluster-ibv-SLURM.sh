#!/bin/bash

# Setting up the environment to build everything - download packages, build them, etc.

# Enabling "unofficial bash strict mode".
# Errors are: non-zero exit codes, reference to unset vars and something else.
set -eou

# Check for gcc version.
(gcc -v |& egrep "^gcc version 4.9") || (echo "needs gcc 4.9; please execute 'module load gcc/4.9.2' before running"; exit 1)

# Bolierplate reduction.
function clonepull {
    git clone $1 $2 || (cd $2 ; git pull) || exit 1
}

# Location of script files.
export SCRIPT_DIR=`pwd`

# The root dir is a level above SKA-RC root.
export MS7_DIR="`pwd`/../.."
export ROOT="`pwd`/../../../.."

# The directory to have all builds in. Easier to clean.
export BUILDDIR="$ROOT/build"
mkdir -p $BUILDDIR

# Going to the root.
cd $BUILDDIR

# -- LLVM ----------------------------------------------------------------------
# Download and build LLVM.

# Download LLVM.
$SCRIPT_DIR/dl-llvm.sh || exit 1

# Build LLVM.
$SCRIPT_DIR/mk-llvm.sh || exit 1

# Provide one true LLVM.
export LLVM_BIN=$BUILDDIR/llvm-install/bin
export PATH=$LLV_BIN:$PATH
export LLVM_CONFIG=$PWD/llvm-install/bin/llvm-config

# -- GASnet --------------------------------------------------------------------
# Right now GASnet does not seem to be available in any modules on cluster.

cd $BUILDDIR

# getting GASnet. We use our GASNet version, cloned from Stanford Legion repo -
# it has config for the Cambridge cluster.
# It enables MPI, UDP (for local run), IBV (for cluster), disables MXM
# (also available on cluster).
clonepull https://github.com/SKA-ScienceDataProcessor/gasnet.git gasnet

# Build it for default config - cambridge-wilkes-ibv.
cd gasnet
make
cd ..

export GASNET_ROOT="$PWD/gasnet/release"
export GASNET_BIN="$GASNET_ROOT/bin"

# -- Terra ---------------------------------------------------------------------
# Terra also unavailable on cluster.

clonepull https://github.com/zdevito/terra.git terra

cd terra

# Known good commit.
git checkout c501af43915


make all || exit 1
cd ..

export TERRA_DIR=$BUILDDIR/terra/release

# -- Legion --------------------------------------------------------------------
# Legion build structure is such that we cannot easily build
# and install libraries/header files somewhere.
# Executables/libraries build with IBV conduit may or may not use UDP conduit.
# So we build two versions separately.

clonepull https://github.com/SKA-ScienceDataProcessor/legion.git Legion-udp
clonepull Legion-udp Legion-ibv

# Go to Regent place.
cd Legion-udp/language

# Running the installation, enabling the GASnet.
CONDUIT=udp ./install.py --with-terra=$TERRA_DIR --gasnet || exit 1

# Up from Regent.
cd $BUILDDIR

# Go to Regent place.
cd Legion-ibv/language

# Running the installation, enabling the GASnet.
CONDUIT=ibv ./install.py --with-terra=$TERRA_DIR --gasnet || exit 1

# Up from Regent.
cd $BUILDDIR

# Configuration of Makefile variables.
cat >$SCRIPT_DIR/build-rules.mk <<EOF
# AUTOGENERATED FILE!!!!
BUILDDIR = $BUILDDIR
SCRIPT_DIR = $SCRIPT_DIR
GASNET_ROOT = $GASNET_ROOT
EOF

# Makefile proper.
cat $SCRIPT_DIR/cluster_build_rules.mk >>$SCRIPT_DIR/build-rules.mk
