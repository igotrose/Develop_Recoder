#!/usr/bin/env bash
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

LINUX_HEADER=linux-headers-5.4.217-bm1684-g9f840964c225-dirty

TOOLCHAIN=./gcc-linaro-6.3.1-2017.05-x86_64_aarch64-linux-gnu
SOC_KERNEL=./soc_kernel
LIBSOPHON=./libsophon

SOC_LINUX_DIR=$SOC_KERNEL/usr/src/$LINUX_HEADER/

export PATH=$TOOLCHAIN/bin:$PATH
echo "[INFO] gcc: $(which aarch64-linux-gnu-gcc)"
echo "[INFO] SOC_LINUX_DIR: $SOC_LINUX_DIR"

mkdir -p "$LIBSOPHON/build"
cd "$LIBSOPHON/build"

cmake -DPLATFORM=soc \
  -DSOC_LINUX_DIR="$SCRIPT_DIR/$SOC_LINUX_DIR" \
  -DLIB_DIR="$SCRIPT_DIR/$LIBSOPHON/3rdparty/soc/" \
  -DCROSS_COMPILE_PATH="$SCRIPT_DIR/$TOOLCHAIN" \
  -DCMAKE_TOOLCHAIN_FILE="$SCRIPT_DIR/$LIBSOPHON/toolchain-aarch64-linux.cmake" \
  -DCMAKE_INSTALL_PREFIX="$SCRIPT_DIR/$LIBSOPHON/install" \
  ..

make -j"$(nproc)"
make driver
make vpu_driver
make jpu_driver
make package
