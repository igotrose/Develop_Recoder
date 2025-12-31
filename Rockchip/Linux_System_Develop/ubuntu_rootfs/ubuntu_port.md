# ubuntu移植
## 准备工作
1. 编译好SDK提供buildroot系统，包含uboot、kernel等镜像
    ```bash
    ./build.sh 
    ```
2. 在另外的虚拟机建立`ubuntu-rootfs`文件夹，从官网获取最小`ubuntu`系统镜像，并解压到`ubuntu-rootfs`文件夹下
    ```bash
    mkdir -p ubuntu-rootfs
    wget http://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.1-base-arm64.tar.gz
    tar -zxvf ubuntu-base-20.04.1-base-arm64.tar.gz -C ubuntu-rootfs
    ```
3. 在虚拟机上安装qume-user-static，模拟运行最小`arm64`架构的文件系统
    ```bash 
    sudo apt-get install qemu-user-static
    ```
## 修改最小文件系统镜像
1. 模拟运行arm架构
    ```bash
    sudo cp /usr/bin/qemu-aarch64-static ubuntu-rootfs/usr/bin/
    ```
2. 将主机的 resolv.conf 复制到 rootfs 中
    ```bash
    sudo cp /etc/resolv.conf ubuntu-rootfs/etc/resolv.conf
    ```
3. chroot进入系统，并开始配置
    ```bash
    ./ch-root.sh -m ubuntu-rootfs
    sudo chroot ubuntu-rootfs
    ```
4. 更新最小系统中原有的内容
    ```bash
    apt update && apt upgrade -y
    ```
5. 安装systemd，并设置系统时区，制作启动脚本的时候需要
    ```bash
    apt install systemd -y
    ```
6. 安装一些必要的软件
    ```bash 
    apt install apt-utils dialog vim sudo ssh rsync udev htop rsyslog bash-completion net-tools iperf3 iputils-ping ifupdown ethtool tcpdump wpasupplicant wireless-tools network-manager bluetooth bluez* blueman* lsof gcc tree rfkill usbutils i2c-tools
    ```
    - 音视频相关
        ```bash
        apt install -y v4l-utils:arm64 ffmpeg gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good
        ```
    - GPU/NPU安装
7. 配置网络
    - 安装netplan 
    ```bash 
    apt install netplan.io -y
    ```
    - 修改配置文件 `/etc/netplan/01-netcfg.yaml`
    ```yaml
    network:
    version: 2
    renderer: networkd
        ethernets:
            eth0:
            dhcp4: true
        enP2p33s0:
            addresses: [192.168.10.1/24]
            dhcp4: no
    ```
    - 应用配置文件
    ```bash
    netplan apply
    ```
8. 设置主机名，添加默认用户密码ubuntu，配置权限
    ```bash
    echo "SS-RK3588" | sudo tee /etc/hostname
    useradd -m -s /bin/bash ubuntu
    echo "ubuntu:ubuntu" | chpasswd
    usermod -aG sudo ubuntu
    ```
9. 设置自启动时自动扩展内存
    - 创建扩容服务并写入 `/etc/systemd/system/firstboot-init.service`
        ```bash
        vim /etc/systemd/system/firstboot-init.service
        ```
    - 应用服务
        ```bash
        systemctl enable firstboot-init.service
        ```
10. ssh远程中端设置
    ```bash
    # 修复 SSH 主机密钥文件权限
    chmod 600 /etc/ssh/ssh_host_*_key
    chown root:root /etc/ssh/ssh_host_*_key
    # 创建特权分离运行目录
    mkdir -p /run/sshd
    chmod 755 /run/sshd
    chown root:root /run/sshd
    # 验证配置无误
    /usr/sbin/sshd -t
    # 启动 SSH 服务
    systemctl start ssh
    # 确保重启后仍有效
    cat > /etc/tmpfiles.d/sshd.conf << 'EOF'
    d /run/sshd 0755 root root -
    EOF
    ```
11. 基于`ubuntu-base`生成的根文件系统，没有wifi/bt驱动，需要自行挂载添加
    - 创建目录`/lib/firmware`放置驱动固件，项目使用的是`ap6398S`，对应固件的位置位于`<SDK>/external/rkwifibt/firmware/broadcom/AP6398S`
        ```bash
        sudo mkdir -p /lib/firmware/brcm
        # BCM4359C0.hcd放入brcm，其他放在firware中就好了
        # 通过ftp把固件上传
        tree
        ├── bt
        │   └── BCM4359C0.hcd
        └── wifi
            ├── fw_bcm4359c0_ag.bin
            ├── fw_bcm4359c0_ag_mfg.bin
            └── nvram_ap6398s.txt
        ```
    - 创建模块目录加载内核模块，驱动位于`<SDK>/kernel/drivers/net/wireless/rockchip_wlan/rkwifi/bcmdhd`
        ```bash
        sudo mkdir -p /lib/modules/5.10.198/kernel/drivers/
        # 通过ftp把驱动上传，bcmdhd.ko  dhd_static_buf.ko
        ```
    - 挂载驱动
        ```bash
        # 挂载驱动
        cd /lib/modules/5.10.198/kernel/drivers/
        depmod -a -5.10.198
        ```
12. 编译镜像并拉入SDK中打包
    ```bash
    # 清除机器码
    sudo rm -rf /etc/machine-id
    sudo rm -rf /var/lib/dbus/machine-id
    # rootfs_maker
    ./mkimage.sh ubuntu_rootfs/ rootfs.img
    # sdk
    ./build.sh updateimg
    ```