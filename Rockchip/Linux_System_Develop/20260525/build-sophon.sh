#!/bin/bash -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_TOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCH="${ARCH:-arm64}"

SOPHON_ARTIFACT_DIR="$SCRIPT_DIR/packages/$ARCH/sophon"
SOPHON_DRIVER_DIR="$SDK_TOP_DIR/external/sophon-driver/opt/sophon/driver-0.5.1"
SOPHON_LIB_DIR="$SDK_TOP_DIR/external/sophon-libsophon"
SOPHON_LIB_DEB="$SOPHON_ARTIFACT_DIR/sophon-libsophon_0.5.1-LTS_arm64.deb"
KERNEL_DIR="$SDK_TOP_DIR/kernel"
CROSS_COMPILE_DEFAULT="$SDK_TOP_DIR/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"

mkdir -p "$SOPHON_ARTIFACT_DIR"

if [ ! -d "$SOPHON_DRIVER_DIR" ]; then
	echo "WARN: sophon driver source not found: $SOPHON_DRIVER_DIR"
	exit 0
fi

echo "Build sophon kernel module..."
make -C "$SOPHON_DRIVER_DIR" \
	ARCH=arm64 \
	CROSS_COMPILE="${CROSS_COMPILE:-$CROSS_COMPILE_DEFAULT}" \
	LINUX_SRC="$KERNEL_DIR" \
	KCFLAGS=-mno-outline-atomics \
	SOC_MODE=0 \
	PLATFORM=asic \
	SYNC_API_INT_MODE=1 \
	TARGET_PROJECT=sg_pcie_device \
	FW_SIMPLE=0 \
	PCIE_MODE_ENABLE_CPU=1

cp -av "$SOPHON_DRIVER_DIR/bmsophon.ko" "$SOPHON_ARTIFACT_DIR/bmsophon.ko"

if [ -f "$SOPHON_LIB_DIR/sophon-libsophon_0.5.1-LTS_arm64.deb" ]; then
	cp -av "$SOPHON_LIB_DIR/sophon-libsophon_0.5.1-LTS_arm64.deb" "$SOPHON_LIB_DEB"
	exit 0
fi

if [ -d "$SOPHON_LIB_DIR/DEBIAN" ]; then
	find "$SOPHON_LIB_DIR/DEBIAN" -maxdepth 1 -type f \( -name postinst -o -name preinst -o -name prerm -o -name postrm \) -exec chmod 755 {} \;
	dpkg-deb -Zxz -z6 -b "$SOPHON_LIB_DIR" "$SOPHON_LIB_DEB"
	exit 0
fi

echo "WARN: sophon libsophon deb source not found under $SOPHON_LIB_DIR"
