#!/bin/bash

# Setting up the environment to build everything - download packages, build them, etc.

# Enable "unofficial bash strict mode"
set -eou

# Check for gcc version.
(gcc -v |& egrep "^gcc version 4.9") || (echo "needs gcc 4.9"; exit 1)

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
export BUILDDIR="$ROOT/build-local"
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
export PATH=$LLVM_BIN:$PATH
export LLVM_CONFIG=$PWD/llvm-install/bin/llvm-config

# -- GASnet --------------------------------------------------------------------
# Right now GASnet does not seem to be available in any modules on cluster.

cd $BUILDDIR

# getting GASnet.
clonepull https://github.com/SKA-ScienceDataProcessor/gasnet.git gasnet

# Build it for default config - MPI and UDP, nothing else.
cd gasnet
make || exit 1
cd ..

export GASNET_ROOT="$PWD/gasnet/release"
export GASNET_BIN="$GASNET_ROOT/bin"

# -- Terra ---------------------------------------------------------------------
# Terra also unavailable on cluster.

git clone https://github.com/zdevito/terra.git terra	# won't pull for a while.

cd terra

# Known good commit.
git checkout c501af43915


make all || exit 1
cd ..

export TERRA_DIR=$BUILDDIR/terra/release

# -- Legion --------------------------------------------------------------------
# We will build Legion by compiling one of the applications.

git clone https://github.com/SKA-ScienceDataProcessor/legion.git Legion

cd Legion
git pull origin master
git checkout -b master
cd ..

# Go to Regent place.
cd Legion/language

# Running the installation, enabling the GASnet.
# TODO: optionally enable CUDA.
CONDUIT=udp ./install.py --with-terra=$TERRA_DIR --gasnet || exit 1

$GASNET_BIN/amudprun -n 2 -spawn L ./regent.py examples/circuit.rg || exit 1

export REGENT_BIN=$BUILDDIR/Legion/language

# Up from Regent.
cd $BUILDDIR

# Setting up the runner script.
cat >runner <<EOF
#!/bin/bash

# Runner script, generated automatically by setup-local-udp.sh
# If you append a line $RUN_CMD <filename of regent program> to it, it should get
# you to a complete script to run you Regent code with options -nodes=NN and -tasks=NT

# Setting up the environment.
export GASNET_BIN=$GASNET_BIN
export LLVM_BIN=$LLVM_BIN
export PATH=$LLVM_BIN:$PATH
export REGENT_BIN=$REGENT_BIN

# Parsing command line args.
nodes=1
tasks=1
usage="usage: \$0 [-[-]nodes=nodes to use] [-[-]tasks=tasks to run] [-[-]threads=CPU cores to allocate per task] [-[-]mem=MB per task] [--] [other arguments]"
while ((\$#)); do
    arg=\$1
    case \$arg in
        -nodes=*|--nodes=*)
            nodes="\${arg#*=}"
            shift
            ;;
        -tasks=*|--tasks=*)
            tasks="\${arg#*=}"
            shift
            ;;
        -net=*|--net=*)
            shift
            ;;
        -threads=*|--threads=*)
            shift
            ;;
        -mem=*|--mem=*)
            shift
            ;;
        -h|--help)
            echo \$usage
            exit 1
            ;;
        --)
            break
            ;;
        -*)
            echo "invalid option \$arg"
            echo "(use -- to delimite RT and program arguments)"
            echo ""
            echo \$usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Emulating SLURM: number of nodes in local run is always 1.
export SLURM_NNODES=1

# Emulating SLURM: list of nodes is always single local computer.
export SLURM_NODELIST="`hostname`"

# Setting the Lua path to our modules. We will use pattern "MODULE/MODULE.lua" for our modules.
export LUA_PATH="$SCRIPT_DIR/../?/?.lua;\$LUA_PATH"

export RUN="\$GASNET_BIN/amudprun -n \$tasks -spawn L \$REGENT_BIN/regent.py"
EOF

cat >$SCRIPT_DIR/build-rules.mk <<EOF
# AUTOGENERATED FILE!!!!
# Makefile include file to provide "compilation" for local runs of Regent files.
# Defines implicit rule to compile executable ("make" or "make exec") and cleanup rule ("make clean").
# Runs first executable (in EXEC list below) by "make run" and any executable using "make run-EXECUTABLE".
# Use in Makefile like the following:
# -------------------------------------
# # Makefile example.
# EXEC=myprog
# include $BUILDDIR/makefile.inc
# -------------------------------------

# Set nodes counter if none given to 1.
NODES ?= 1

# Set task counter if none given to 1.
TASKS ?= 1

exec: \$(EXEC)

run: \$(EXEC)
	./\${word 1, \$(EXEC)} -nodes=\$(NODES) -tasks=\$(TASKS) \$(EXEC_ARGS)

run-%: %
	./\$< -nodes=\$(NODES) -tasks=\$(TASKS) \$(EXEC_ARGS)

clean:
	rm -f \$(EXEC)

% : %.rg
	cp $BUILDDIR/runner \$@
	echo "\\\$\$RUN \$< \\\$\$@" >>\$@
	chmod a+x \$@
EOF