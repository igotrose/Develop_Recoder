#!/bin/bash -e

# Directory contains the target rootfs
TARGET_ROOTFS_DIR="binary"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_TOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KERNEL_DEB_DIR="$SDK_TOP_DIR/output/bsp-debs"
KERNEL_HEADERS_DEB_DIR="$SDK_TOP_DIR/rockdev"
# kernel image + headers debs are both stored here

case "${ARCH:-$1}" in
	arm|arm32|armhf)
		ARCH=armhf
		KBUILD_ARCH=armhf
		;;
	*)
		ARCH=arm64
		KBUILD_ARCH=aarch64
		;;
esac

echo -e "\033[36m Building for $ARCH \033[0m"

if [ ! $VERSION ]; then
	VERSION="release"
fi

echo -e "\033[36m Building for $VERSION \033[0m"

DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://mirrors.ustc.edu.cn/debian/}"
DEBIAN_BACKPORTS_MIRROR="${DEBIAN_BACKPORTS_MIRROR:-$DEBIAN_MIRROR}"
ENABLE_BULLSEYE_BACKPORTS="${ENABLE_BULLSEYE_BACKPORTS:-false}"

if [ ! -e linaro-bullseye-alip-*.tar.gz ]; then
	echo "\033[36m Run mk-base-debian.sh first \033[0m"
	exit -1
fi

echo -e "\033[36m Extract image \033[0m"
sudo tar -xpf linaro-bullseye-alip-*.tar.gz

# packages folder
sudo mkdir -p $TARGET_ROOTFS_DIR/packages
sudo cp -rpf packages/$ARCH/* $TARGET_ROOTFS_DIR/packages

# kernel image deb package
if [ -d "$KERNEL_DEB_DIR" ]; then
	sudo mkdir -p "$TARGET_ROOTFS_DIR/packages/kernel"
	for pkg in "$KERNEL_DEB_DIR"/linux-image-*.deb; do
		[ -e "$pkg" ] || continue
		case "$pkg" in
			*-dbg_*.deb) continue ;;
		esac
		sudo cp -av "$pkg" "$TARGET_ROOTFS_DIR/packages/kernel/"
	done

	for pkg in "$KERNEL_DEB_DIR"/linux-headers-*.deb; do
		[ -e "$pkg" ] || continue
		case "$pkg" in
			*-dbg_*.deb) continue ;;
		esac
		sudo cp -av "$pkg" "$TARGET_ROOTFS_DIR/packages/kernel/"
	done
fi

# keep a copy of bsp debs in target user's home
if [ -d "$KERNEL_DEB_DIR" ]; then
	sudo mkdir -p "$TARGET_ROOTFS_DIR/home/linaro/bsp-debs"
	sudo find "$TARGET_ROOTFS_DIR/home/linaro/bsp-debs" -mindepth 1 -maxdepth 1 -exec rm -rf {} \;
	sudo cp -av "$KERNEL_DEB_DIR"/linux-*.deb "$TARGET_ROOTFS_DIR/home/linaro/bsp-debs/" 2>/dev/null || true
fi

if [ -d "packages/$ARCH/sophon" ]; then
	sudo mkdir -p "$TARGET_ROOTFS_DIR/home/linaro/bsp-debs/sophon"
	sudo find "$TARGET_ROOTFS_DIR/home/linaro/bsp-debs/sophon" -mindepth 1 -maxdepth 1 -exec rm -rf {} \;
	sudo cp -av packages/$ARCH/sophon/*.deb "$TARGET_ROOTFS_DIR/home/linaro/bsp-debs/sophon/" 2>/dev/null || true
fi

# overlay folder
sudo cp -rpf overlay/* $TARGET_ROOTFS_DIR/

# overlay-firmware folder
sudo cp -rpf overlay-firmware/* $TARGET_ROOTFS_DIR/

# overlay-debug folder
# adb, video, camera  test file
if [ "$VERSION" == "debug" ]; then
	sudo cp -rpf overlay-debug/* $TARGET_ROOTFS_DIR/
fi

echo -e "\033[36m Change root.....................\033[0m"

sudo cp -f /etc/resolv.conf $TARGET_ROOTFS_DIR/etc/


KERNEL_RELEASE_FILE="$SDK_TOP_DIR/kernel/include/config/kernel.release"
if [ -f "$KERNEL_RELEASE_FILE" ]; then
	KERNEL_RELEASE="$(cat "$KERNEL_RELEASE_FILE")"
else
	KERNEL_RELEASE=""
fi

ID=$(stat --format %u $TARGET_ROOTFS_DIR)

cat << EOF | sudo chroot $TARGET_ROOTFS_DIR

# Set up an effective DNS.
echo "nameserver 114.114.114.114" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf

# Fixup owners
if [ "$ID" -ne 0 ]; then
       find / -user $ID -exec chown -h 0:0 {} \;
fi
for u in \$(ls /home/); do
	chown -h -R \$u:\$u /home/\$u
done

ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

apt-get update
# apt-get upgrade -y
apt install --reinstall util-linux

export APT_INSTALL="apt-get install -fy --allow-downgrades"

#---------------kernel image--------------
echo -e "\033[36m Install kernel image.................... \033[0m"
KERNEL_IMAGE_PKG=
for pkg in /packages/kernel/linux-image-*.deb; do
	case "$pkg" in
		*-dbg_*.deb) continue ;;
	esac
	KERNEL_IMAGE_PKG="$pkg"
	break
done

if [ -n "$KERNEL_IMAGE_PKG" ]; then
	echo "Install kernel image package: $KERNEL_IMAGE_PKG"
	${APT_INSTALL} "$KERNEL_IMAGE_PKG"
else
	echo "WARN: no non-dbg linux-image package found in /packages/kernel"
fi

echo -e "\033[36m Install kernel headers.................... \033[0m"
KERNEL_HEADERS_PKG=
for pkg in /packages/kernel/linux-headers-*.deb; do
	[ -e "$pkg" ] || continue
	case "$pkg" in
		*-dbg_*.deb) continue ;;
	esac
	KERNEL_HEADERS_PKG="$pkg"
	break
done

if [ -n "$KERNEL_HEADERS_PKG" ]; then
	echo "Install kernel headers package: $KERNEL_HEADERS_PKG"
	${APT_INSTALL} "$KERNEL_HEADERS_PKG"
else
	echo "WARN: no linux-headers package found in /packages/kernel"
fi

# Common compatibility packages for kernel modules and legacy Python callers.
\${APT_INSTALL} dkms libncurses5 libtinfo5 python2 build-essential
if [ -x /usr/bin/python2 ] && [ ! -e /usr/bin/python ]; then
	ln -sf /usr/bin/python2 /usr/bin/python
fi

# enter root username without password
sed -i "s~\(^ExecStart=.*\)~# \1\nExecStart=-/bin/sh -c '/bin/bash -l </dev/%I >/dev/%I 2>\&1'~" /usr/lib/systemd/system/serial-getty@.service

#---------------power management --------------
\${APT_INSTALL} pm-utils triggerhappy bsdmainutils
cp /etc/Powermanager/triggerhappy.service  /lib/systemd/system/triggerhappy.service
sed -i "s/#HandlePowerKey=.*/HandlePowerKey=ignore/" /etc/systemd/logind.conf

#---------------Rga--------------
\${APT_INSTALL} /packages/rga2/*.deb

echo -e "\033[36m Setup Video.................... \033[0m"
\${APT_INSTALL} gstreamer1.0-plugins-bad gstreamer1.0-plugins-base gstreamer1.0-plugins-ugly gstreamer1.0-tools gstreamer1.0-alsa \
gstreamer1.0-plugins-base-apps qtmultimedia5-examples

\${APT_INSTALL} /packages/mpp/*
\${APT_INSTALL} /packages/gst-rkmpp/*.deb
\${APT_INSTALL} /packages/gstreamer/*.deb
\${APT_INSTALL} /packages/gst-plugins-base1.0/*.deb
\${APT_INSTALL} /packages/gst-plugins-bad1.0/*.deb
\${APT_INSTALL} /packages/gst-plugins-good1.0/*.deb
\${APT_INSTALL} /packages/gst-plugins-ugly1.0/*.deb

#---------Camera---------
echo -e "\033[36m Install camera.................... \033[0m"
\${APT_INSTALL} cheese v4l-utils
\${APT_INSTALL} /packages/libv4l/*.deb
\${APT_INSTALL} /packages/cheese/*.deb

#---------Xserver---------
echo -e "\033[36m Install Xserver.................... \033[0m"
\${APT_INSTALL} /packages/xserver/*.deb

apt-mark hold xserver-common xserver-xorg-core xserver-xorg-legacy

#---------------Openbox--------------
echo -e "\033[36m Install openbox.................... \033[0m"
\${APT_INSTALL} /packages/openbox/*.deb

#---------update chromium-----
\${APT_INSTALL} /packages/chromium/*.deb

#------------------libdrm------------
echo -e "\033[36m Install libdrm.................... \033[0m"
\${APT_INSTALL} /packages/libdrm/*.deb

#------------------libdrm-cursor------------
echo -e "\033[36m Install libdrm-cursor.................... \033[0m"
\${APT_INSTALL} /packages/libdrm-cursor/*.deb

#------------------blueman------------
echo -e "\033[36m Install blueman.................... \033[0m"
\${APT_INSTALL} blueman
echo exit 101 > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
\${APT_INSTALL} blueman
rm -f /usr/sbin/policy-rc.d

#------------------blueman------------
echo -e "\033[36m Install blueman.................... \033[0m"
\${APT_INSTALL} /packages/blueman/*.deb

#------------------rkwifibt------------
echo -e "\033[36m Install rkwifibt.................... \033[0m"
\${APT_INSTALL} /packages/rkwifibt/*.deb
ln -s /system/etc/firmware /vendor/etc/

if [ "$VERSION" == "debug" ]; then
#------------------glmark2------------
echo -e "\033[36m Install glmark2.................... \033[0m"
\${APT_INSTALL} /packages/glmark2/*.deb
fi

if [ -e "/usr/lib/aarch64-linux-gnu" ] ;
then
#------------------rknpu2------------
echo -e "\033[36m move rknpu2.................... \033[0m"
mv /packages/rknpu2/rknpu2.tar  /
fi

#------------------rktoolkit------------
echo -e "\033[36m Install rktoolkit.................... \033[0m"
\${APT_INSTALL} /packages/rktoolkit/*.deb

#------------------gl4es------------
# echo -e "\033[36m Install gl4es.................... \033[0m"
# \${APT_INSTALL} /packages/gl4es/*.deb

#------------------Install ffmpeg--------------------
echo -e "\033[36m Install ffmpeg.................... \033[0m"
\${APT_INSTALL} ffmpeg

#------------------Install tcpdump--------------------
echo -e "\033[36m Install tcpdump.................... \033[0m"
\${APT_INSTALL} tcpdump

echo -e "\033[36m Install English fonts.................... \033[0m"
# Uncomment en.UTF-8 for inclusion in generation
sed -i 's/^# *\(en.UTF-8\)/\1/' /etc/locale.gen
echo "LANG=en.UTF-8" >> /etc/default/locale

# Generate locale
locale-gen

\${APT_INSTALL} ttf-wqy-zenhei fonts-aenigma
\${APT_INSTALL} xfonts-intl-chinese

# HACK debian11.3 to fix bug
\${APT_INSTALL} fontconfig --reinstall

#\${APT_INSTALL} xfce4
#ln -sf /usr/bin/startxfce4 /etc/alternatives/x-session-manager

# HACK to disable the kernel logo on bootup
#sed -i "/exit 0/i \ echo 3 > /sys/class/graphics/fb0/blank" /etc/rc.local

cp /packages/libmali/libmali-*-x11*.deb /
cp -rf /packages/rkisp/*.deb /
cp -rf /packages/rkaiq/*.deb /
cp -rf /usr/lib/firmware/rockchip/ /

# reduce 500M size for rootfs
rm -rf /usr/lib/firmware
mkdir -p /usr/lib/firmware/
mv /rockchip /usr/lib/firmware/

# mark package to hold
apt list --installed | grep -v oldstable | cut -d/ -f1 | xargs apt-mark hold

#---------------Custom Script--------------
systemctl mask systemd-networkd-wait-online.service
systemctl mask NetworkManager-wait-online.service
rm /lib/systemd/system/wpa_supplicant@.service

#------remove unused packages------------
apt remove --purge -fy linux-firmware*

#---------------Clean--------------
if [ -e "/usr/lib/arm-linux-gnueabihf/dri" ] ;
then
        # Only preload libdrm-cursor for X
        sed -i "1aexport LD_PRELOAD=/usr/lib/arm-linux-gnueabihf/libdrm-cursor.so.1" /usr/bin/X
        cd /usr/lib/arm-linux-gnueabihf/dri/
        cp kms_swrast_dri.so swrast_dri.so rockchip_dri.so /
        rm /usr/lib/arm-linux-gnueabihf/dri/*.so
        mv /*.so /usr/lib/arm-linux-gnueabihf/dri/
elif [ -e "/usr/lib/aarch64-linux-gnu/dri" ];
then
        # Only preload libdrm-cursor for X
        sed -i "1aexport LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libdrm-cursor.so.1" /usr/bin/X
        cd /usr/lib/aarch64-linux-gnu/dri/
        cp kms_swrast_dri.so swrast_dri.so rockchip_dri.so /
        rm /usr/lib/aarch64-linux-gnu/dri/*.so
        mv /*.so /usr/lib/aarch64-linux-gnu/dri/
        rm /etc/profile.d/qt.sh
fi
cd -

rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/
rm -rf /packages/

EOF
