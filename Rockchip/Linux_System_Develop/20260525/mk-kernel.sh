#!/bin/bash -e

KERNELS=$(ls | grep kernel- || true)

update_kernel()
{
	# Fallback to current kernel
	RK_KERNEL_VERSION=${RK_KERNEL_VERSION:-$(kernel_version)}

	# Fallback to 5.10 kernel
	RK_KERNEL_VERSION=${RK_KERNEL_VERSION:-5.10}

	# Update .config
	KERNEL_CONFIG="RK_KERNEL_VERSION=\"$RK_KERNEL_VERSION\""
	if ! grep -q "^$KERNEL_CONFIG$" "$RK_CONFIG"; then
		sed -i "s/^RK_KERNEL_VERSION=.*/$KERNEL_CONFIG/" "$RK_CONFIG"
		"$RK_SCRIPTS_DIR/mk-config.sh" olddefconfig &>/dev/null
	fi

	[ "$(kernel_version)" != "$RK_KERNEL_VERSION" ] || return 0

	# Update kernel
	KERNEL_DIR=kernel-$RK_KERNEL_VERSION
	notice "switching to $KERNEL_DIR"
	if [ ! -d "$KERNEL_DIR" ]; then
		error "$KERNEL_DIR not exist!"
		exit 1
	fi

	rm -rf kernel
	ln -rsf $KERNEL_DIR kernel
}

do_build()
{
	check_config RK_KERNEL RK_KERNEL_CFG || false

	if [ "$DRY_RUN" ]; then
		notice "Commands of building $1:"
	else
		message "=========================================="
		message "          Start building $1"
		message "=========================================="
	fi

	run_command $KMAKE $RK_KERNEL_CFG $RK_KERNEL_CFG_FRAGMENTS

	if [ -z "$DRY_RUN" ]; then
		"$RK_SCRIPTS_DIR/check-kernel.sh"
	fi

	case "$1" in
		kernel-config | kconfig)
			KERNEL_CONFIG_DIR="kernel/arch/$RK_KERNEL_ARCH/configs"
			run_command $KMAKE menuconfig
			run_command $KMAKE savedefconfig
			run_command mv kernel/defconfig \
				"$KERNEL_CONFIG_DIR/$RK_KERNEL_CFG"
			;;
		kernel*)
			run_command $KMAKE "$RK_KERNEL_DTS_NAME.img"

			# The FIT image for initrd would be packed in rootfs stage
			if [ -n "$RK_BOOT_FIT_ITS" ] && \
				[ -z "$RK_ROOTFS_INITRD" ]; then
				run_command "$RK_SCRIPTS_DIR/mk-fitimage.sh" \
					"kernel/$RK_BOOT_IMG" \
					"$RK_BOOT_FIT_ITS" \
					"$RK_KERNEL_IMG" "$RK_KERNEL_DTB" \
					"kernel/resource.img"
			fi

			if [ "$RK_SECURITY" ]; then
				if [ "$RK_SECURITY_CHECK_BASE" ]; then
					run_command \
						"$RK_SCRIPTS_DIR/mk-security.sh" \
						sign boot "kernel/$RK_BOOT_IMG" \
						$RK_FIRMWARE_DIR/
				fi
			else
				run_command ln -rsf "kernel/$RK_BOOT_IMG" \
					"$RK_FIRMWARE_DIR/boot.img"
			fi

			[ -z "$DRY_RUN" ] || return 0

			"$RK_SCRIPTS_DIR/check-power-domain.sh"
			"$RK_SCRIPTS_DIR/check-security.sh" kernel dts

			if [ "$RK_WIFIBT_CHIP" ] && \
				! grep -wq wireless-bluetooth "$RK_KERNEL_DTB"; then
				error "Missing wireless-bluetooth in $RK_KERNEL_DTS!"
			fi
			;;
		modules) run_command $KMAKE modules ;;
	esac
}

build_recovery_kernel()
{
	check_config RK_KERNEL || false

	if [ "$DRY_RUN" ]; then
		notice "Commands of building $1:"
	else
		message "=========================================="
		message "          Start building $1"
		message "=========================================="
	fi

	if [ -z "$RK_KERNEL_RECOVERY_CFG" ]; then
		RECOVERY_KERNEL_DIR=kernel
		do_build kernel
	else
		RECOVERY_KERNEL_DIR="$RK_OUTDIR/recovery-kernel"
		run_command mkdir -p "$RECOVERY_KERNEL_DIR"

		# HACK: Fake mrproper
		run_command tar cf "$RK_OUTDIR/kernel.tar" \
			--remove-files --ignore-failed-read \
			kernel/.config kernel/include/config \
			kernel/arch/$RK_KERNEL_ARCH/include/generated

		KMAKE="$KMAKE O=$RECOVERY_KERNEL_DIR"
		run_command $KMAKE $RK_KERNEL_RECOVERY_CFG
		run_command $KMAKE "$RK_KERNEL_DTS_NAME.img"

		run_command tar xf "$RK_OUTDIR/kernel.tar"
		run_command rm -f "$RK_OUTDIR/kernel.tar"
	fi

	run_command ln -rsf \
		"$RECOVERY_KERNEL_DIR/${RK_KERNEL_IMG#kernel/}" \
		"$RK_OUTDIR/recovery-kernel.img"
	run_command ln -rsf \
		"$RECOVERY_KERNEL_DIR/${RK_KERNEL_DTB#kernel/}" \
		"$RK_OUTDIR/recovery-kernel.dtb"
	run_command ln -rsf \
		"$RECOVERY_KERNEL_DIR/resource.img" \
		"$RK_OUTDIR/recovery-resource.img"
}

# Hooks

usage_hook()
{
	for k in $KERNELS; do
		echo -e "$k[:cmds]               \tbuild kernel ${k#kernel-}"
	done

	echo -e "kernel[:cmds]                    \tbuild kernel"
	echo -e "recovery-kernel[:cmds]           \tbuild kernel for recovery"
	echo -e "modules[:cmds]                   \tbuild kernel modules"
	echo -e "linux-headers[:cmds]             \tbuild linux-headers"
	echo -e "kernel-config[:cmds]             \tmodify kernel defconfig"
	echo -e "kconfig[:cmds]                   \talias of kernel-config"
	echo -e "kernel-make[:<arg1>:<arg2>]      \trun kernel make"
	echo -e "kmake[:<arg1>:<arg2>]            \talias of kernel-make"
}

clean_hook()
{
	[ ! -d kernel ] || make -C kernel distclean

	rm -rf "$RK_OUTDIR/recovery-*"
	rm -f "$RK_OUTDIR"/bsp-debs/linux-headers-*.deb
	rm -rf "$RK_FIRMWARE_DIR/boot.img"
}

INIT_CMDS="default $KERNELS"
init_hook()
{
	load_config RK_KERNEL_CFG
	check_config RK_KERNEL_CFG &>/dev/null || return 0

	# Priority: cmdline > custom env > .config > current kernel/ symlink
	if echo $1 | grep -q "^kernel-"; then
		export RK_KERNEL_VERSION=${1#kernel-}
		notice "Using kernel version($RK_KERNEL_VERSION) from cmdline"
	elif [ "$RK_KERNEL_VERSION" ]; then
		export RK_KERNEL_VERSION=${RK_KERNEL_VERSION//\"/}
		notice "Using kernel version($RK_KERNEL_VERSION) from environment"
	else
		load_config RK_KERNEL_VERSION
	fi

	update_kernel
}

PRE_BUILD_CMDS="kernel-config kconfig kernel-make kmake"
pre_build_hook()
{
	check_config RK_KERNEL RK_KERNEL_CFG || false
	source "$RK_SCRIPTS_DIR/kernel-helper"

	message "Toolchain for kernel:"
	message "${RK_KERNEL_TOOLCHAIN:-gcc}"
	echo

	case "$1" in
		kernel-make | kmake)
			shift
			[ "$1" != cmds ] || shift

			if [ "$DRY_RUN" ]; then
				notice "Commands of building ${@:-stuff}:"
			else
				message "=========================================="
				message "          Start building $@"
				message "=========================================="
			fi

			if [ ! -r kernel/.config ]; then
				run_command $KMAKE $RK_KERNEL_CFG \
					$RK_KERNEL_CFG_FRAGMENTS
			fi
			run_command $KMAKE $@
			;;
		kernel-config | kconfig)
			do_build $@
			;;
	esac

	if [ -z "$DRY_RUN" ]; then
		finish_build $@
	fi
}

pre_build_hook_dry()
{
	DRY_RUN=1 pre_build_hook $@
}

BUILD_CMDS="$KERNELS kernel recovery-kernel modules"
build_hook()
{
	check_config RK_KERNEL RK_KERNEL_CFG || false
	source "$RK_SCRIPTS_DIR/kernel-helper"

	message "Toolchain for kernel:"
	message "${RK_KERNEL_TOOLCHAIN:-gcc}"
	echo

	case "$1" in
		recovery-kernel) build_recovery_kernel $@ ;;
		kernel-*)
			if [ "$RK_KERNEL_VERSION" != "${1#kernel-}" ]; then
				notice "Kernel version overrided: " \
					"$RK_KERNEL_VERSION -> ${1#kernel-}"
			fi
			;&
		*) do_build $@ ;;
	esac

	finish_build build_$1
}

build_hook_dry()
{
	DRY_RUN=1 build_hook $@
}

POST_BUILD_CMDS="linux-headers"
post_build_hook()
{
	check_config RK_KERNEL RK_KERNEL_CFG || false
	source "$RK_SCRIPTS_DIR/kernel-helper"

	[ "$1" = "linux-headers" ] || return 0
	shift

	[ "$1" != cmds ] || shift
	OUTPUT_DIR="${1:-"$RK_OUTDIR/bsp-debs"}"
	mkdir -p "$OUTPUT_DIR"

	HEADER_FILES_SCRIPT=$(mktemp)
	HEADER_TAR=$(mktemp --suffix=.tar)
	HEADER_PKG_ROOT=$(mktemp -d)
	trap 'rm -f "$HEADER_FILES_SCRIPT" "$HEADER_TAR"; rm -rf "$HEADER_PKG_ROOT"' EXIT

	run_command $KMAKE $RK_KERNEL_CFG $RK_KERNEL_CFG_FRAGMENTS
	run_command $KMAKE modules_prepare
	run_command $KMAKE $RK_KERNEL_IMG_NAME

	KERNEL_RELEASE=$(cat "$RK_SDK_DIR/kernel/include/config/kernel.release")
	HEADER_PKG_NAME="linux-headers-$KERNEL_RELEASE"
	HEADER_DST="$HEADER_PKG_ROOT/usr/src/$HEADER_PKG_NAME"
	case "$RK_KERNEL_ARCH" in
		arm) DEB_ARCH=armhf ;;
		arm64) DEB_ARCH=arm64 ;;
		*) DEB_ARCH="$RK_KERNEL_ARCH" ;;
	esac
	OUTPUT_DEB="$OUTPUT_DIR/${HEADER_PKG_NAME}_${KERNEL_RELEASE}-1_${DEB_ARCH}.deb"

	if [ "$DRY_RUN" ]; then
		notice "Commands of building linux-headers:"
	else
		notice "Saving linux-headers to $OUTPUT_DEB"
	fi


	cat << EOF > "$HEADER_FILES_SCRIPT"
{
	# Based on kernel/scripts/package/builddeb
	find . arch/$RK_KERNEL_ARCH -maxdepth 1 -name Makefile\*
	find include -type f -o -type l
	find scripts -type f -o -type l
	if [ -d tools/objtool ]; then
		find tools/objtool -type f -o -type l
	fi
	find arch/$RK_KERNEL_ARCH -name Kbuild.platforms -o -name Platform
	find \$(find arch/$RK_KERNEL_ARCH -name include -o -name scripts -type d) -type f
	find arch/$RK_KERNEL_ARCH/include Module.symvers System.map -type f
	echo .config
	echo scripts/module.lds
	echo scripts/module.lds.S
	echo scripts/Makefile
	echo scripts/basic/Makefile
} | tar --no-recursion --ignore-failed-read -T - \
	-cf "$HEADER_TAR"
EOF

	run_command cd "$RK_SDK_DIR/kernel"

	if [ -z "$DRY_RUN" ]; then
		. "$HEADER_FILES_SCRIPT"
	fi

	mkdir -p "$HEADER_DST"
	tar -xf "$HEADER_TAR" -C "$HEADER_DST"

	KBUILD_DIR=
	for d in \
		"$RK_KBUILD_DIR/$RK_KERNEL_KBUILD_ARCH/linux-kbuild-$RK_KERNEL_VERSION_REAL" \
		"$RK_KBUILD_DIR/$RK_KERNEL_ARCH/linux-kbuild-$RK_KERNEL_VERSION_REAL" \
		"$RK_KBUILD_DIR/aarch64/linux-kbuild-$RK_KERNEL_VERSION_REAL" \
		"$RK_KBUILD_DIR/$RK_KERNEL_ARCH/linux-kbuild-$(echo "$RK_KERNEL_VERSION_REAL" | cut -d. -f1,2)" \
		"$RK_KBUILD_DIR/aarch64/linux-kbuild-$(echo "$RK_KERNEL_VERSION_REAL" | cut -d. -f1,2)"
	do
		if [ -d "$d" ]; then
			KBUILD_DIR="$d"
			break
		fi
	done

	if [ -n "$KBUILD_DIR" ]; then
		notice "Overlay target kbuild from $KBUILD_DIR"
		mkdir -p "$HEADER_DST/scripts"
		cp -a "$KBUILD_DIR/scripts/." "$HEADER_DST/scripts/"
		if [ -d "$KBUILD_DIR/tools" ]; then
			mkdir -p "$HEADER_DST/tools"
			cp -a "$KBUILD_DIR/tools/." "$HEADER_DST/tools/"
		fi
	else
		notice "No target kbuild dir found, keep in-tree scripts/tools"
	fi

	if [ ! -f "$HEADER_DST/scripts/module.lds" ]; then
		error "module.lds was not packaged into headers"
		exit 1
	fi

	if [ ! -f "$HEADER_DST/scripts/basic/fixdep" ]; then
		error "Missing fixdep in headers package"
		exit 1
	fi

	if [ ! -f "$HEADER_DST/scripts/mod/modpost" ]; then
		error "Missing modpost in headers package"
		exit 1
	fi

	if ! file "$HEADER_DST/scripts/basic/fixdep" | grep -Eq 'ARM aarch64|ARM64|AArch64'; then
		error "fixdep is not an arm64/aarch64 binary"
		file "$HEADER_DST/scripts/basic/fixdep" || true
		exit 1
	fi

	if ! file "$HEADER_DST/scripts/mod/modpost" | grep -Eq 'ARM aarch64|ARM64|AArch64'; then
		error "modpost is not an arm64/aarch64 binary"
		file "$HEADER_DST/scripts/mod/modpost" || true
		exit 1
	fi

	mkdir -p \
		"$HEADER_PKG_ROOT/DEBIAN" \
		"$HEADER_PKG_ROOT/lib/modules/$KERNEL_RELEASE"

	ln -snf "/usr/src/$HEADER_PKG_NAME" \
		"$HEADER_PKG_ROOT/lib/modules/$KERNEL_RELEASE/build"
	ln -snf "/usr/src/$HEADER_PKG_NAME" \
		"$HEADER_PKG_ROOT/lib/modules/$KERNEL_RELEASE/source"

	cat << EOF > "$HEADER_PKG_ROOT/DEBIAN/control"
Package: $HEADER_PKG_NAME
Version: ${KERNEL_RELEASE}-1
Section: devel
Priority: optional
Architecture: $DEB_ARCH
Maintainer: Rockchip
Description: Linux kernel headers for $KERNEL_RELEASE
EOF

	if [ -z "$DRY_RUN" ]; then
		dpkg-deb -Zgzip --build "$HEADER_PKG_ROOT" "$OUTPUT_DEB"
	fi
}

post_build_hook_dry()
{
	DRY_RUN=1 post_build_hook $@
}

source "${RK_BUILD_HELPER:-$(dirname "$(realpath "$0")")/../build-hooks/build-helper}"

case "${1:-kernel}" in
	kernel-config | kconfig | kernel-make | kmake) pre_build_hook $@ ;;
	kernel* | recovery-kernel | modules)
		init_hook $@
		build_hook ${@:-kernel}
		;;
	linux-headers) post_build_hook $@ ;;
	*) usage ;;
esac
