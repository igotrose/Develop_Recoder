# OpenSSH 定制笔记

本文档记录 BM1684 V24 SDK 中 OpenSSH / OpenSSL 的定制、制包、集成到 rootfs 以及验证方法。

SDK 路径：

```bash
/home/lzx/work/SOPHGO/BM1684/v24/bsp_code
```

## 1. 定制目标

目标组件版本：

| 组件 | 目标版本 | 说明 |
| --- | --- | --- |
| openssh-server | 1:10.2p1-1sophgo1 | 由 SDK 内脚本重新打包生成 |
| openssh-client | 1:10.2p1-1sophgo1 | 由 SDK 内脚本重新打包生成 |
| openssh-sftp-server | 1:10.2p1-1sophgo1 | server 依赖组件 |
| OpenSSL | 3.5.5 | 安装到 `/usr/local/openssl-3.5.5` |

安全配置要求：

```text
PermitRootLogin prohibit-password
PermitEmptyPasswords no
```

账号要求：

```text
仅保留一个用户名/密码账号：linaro / linaro
删除基础 rootfs 中默认的 admin 用户
```

注意：当前 V24 脚本中 `build_openssh_prebuilt()` 生成 OpenSSH 预编译包时，将 `PermitRootLogin` 写成了 `yes`。如果验收要求是“禁用 root 密码登录”，这里需要改成 `PermitRootLogin prohibit-password`，否则不满足配置要求。

## 2. 相关源码和脚本位置

OpenSSH / OpenSSL 源码包：

```bash
bootloader-arm64/third_party/openssh-portable-V_10_2_P1.tar.gz
bootloader-arm64/third_party/openssl-3.5.5.tar.gz
```

本仓库归档位置：

```bash
20260817/third_party/openssh-portable-V_10_2_P1.tar.gz
20260817/third_party/openssl-3.5.5.tar.gz
```

OpenSSH / OpenSSL 预编译输出包：

```bash
bootloader-arm64/third_party/prebuilt/openssh_openssl_prebuilt.tar.gz
```

本仓库归档位置：

```bash
20260817/third_party/prebuilt/openssh_openssl_prebuilt.tar.gz
```

OpenSSH Debian 制包脚本：

```bash
bootloader-arm64/scripts/build_openssh_debs.sh
```

主构建入口：

```bash
bootloader-arm64/scripts/envsetup.sh
```

rootfs overlay 配置：

```bash
bootloader-arm64/distro/sophgo-fs/
```

本次集成补丁：

```bash
20260817/0001-Change-the-SSH-version-to-the-latest-LTS-version.patch
```

## 3. OpenSSH 配置修改点

如果使用 SDK 中自定义 OpenSSH 10.2p1，最终 sshd 使用的配置文件不是系统默认的 `/etc/ssh/sshd_config`，而是：

```bash
/usr/local/openssh-10.2p1/etc/sshd_config
```

对应生成位置在 `envsetup.sh` 的 `build_openssh_prebuilt()` 中：

```bash
sed -i \
	-e 's/^#Port 22/Port 2222/' \
	-e 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' \
	-e 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' \
	/tmp/build-out/usr/local/openssh-10.2p1/etc/sshd_config
```

若要满足“禁用 root 密码登录”和“禁用空密码”，建议改为：

```bash
sed -i \
	-e 's/^#Port 22/Port 2222/' \
	-e 's/^#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' \
	-e 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' \
	-e 's/^#PermitEmptyPasswords no/PermitEmptyPasswords no/' \
	/tmp/build-out/usr/local/openssh-10.2p1/etc/sshd_config
```

说明：

- `PermitRootLogin prohibit-password`：禁止 root 使用密码登录，但仍允许 root 使用密钥登录。
- `PermitEmptyPasswords no`：禁止空密码账号登录。
- `PasswordAuthentication yes`：保留普通用户密码登录能力，便于使用 `linaro / linaro` 登录。

## 4. 预编译包制作流程

进入 SDK 根目录并加载环境：

```bash
cd /home/lzx/work/SOPHGO/BM1684/v24/bsp_code
source bootloader-arm64/scripts/envsetup.sh
```

生成 OpenSSH / OpenSSL 预编译压缩包：

```bash
build_openssh_prebuilt
```

该流程做的事情：

1. 解压 `distro/distro_focal.tgz` 到临时 rootfs。
2. 将 `bootloader-arm64/third_party/` 中的 OpenSSL 和 OpenSSH 源码复制进临时 rootfs。
3. 通过 `qemu-aarch64-static` 进入 arm64 chroot 环境。
4. 编译 OpenSSL 3.5.5，安装到 `/usr/local/openssl-3.5.5`。
5. 编译 OpenSSH 10.2p1，安装到 `/usr/local/openssh-10.2p1`。
6. 修改 OpenSSH 默认配置。
7. 打包生成：

```bash
bootloader-arm64/third_party/prebuilt/openssh_openssl_prebuilt.tar.gz
```

## 5. OpenSSH Debian 包制作流程

预编译包生成后，可单独执行 Debian 制包脚本：

```bash
bootloader-arm64/scripts/build_openssh_debs.sh \
  bootloader-arm64/third_party/prebuilt/openssh_openssl_prebuilt.tar.gz \
  deb/openssh-debs
```

默认包版本由脚本变量控制：

```bash
PKG_VERSION="1:10.2p1-1sophgo1"
ARCH="arm64"
```

输出文件：

```bash
deb/openssh-debs/openssh-client_1:10.2p1-1sophgo1_arm64.deb
deb/openssh-debs/openssh-sftp-server_1:10.2p1-1sophgo1_arm64.deb
deb/openssh-debs/openssh-server_1:10.2p1-1sophgo1_arm64.deb
```

制包脚本主要做的事情：

1. 解压 `openssh_openssl_prebuilt.tar.gz`。
2. 将 `/usr/local/openssl-3.5.5` 放入 `openssh-client` 包。
3. 将 OpenSSH 客户端命令链接到 `/usr/bin/ssh`、`/usr/bin/scp`、`/usr/bin/sftp` 等路径。
4. 将 `sshd` 链接到 `/usr/sbin/sshd`。
5. 生成 `ssh.service`，启动命令使用：

```text
/usr/sbin/sshd -D -f /usr/local/openssh-10.2p1/etc/sshd_config
```

6. 在 `openssh-server` 的 `postinst` 中创建 `/run/sshd`、`sshd` 系统用户和 host key。

## 6. 集成到 build_rootp

`build_rootp()` 中已经集成 OpenSSH Debian 包流程。

关键逻辑：

```bash
local OPENSSH_PREBUILT_TAR=$TOP_DIR/bootloader-arm64/third_party/prebuilt/openssh_openssl_prebuilt.tar.gz
local OPENSSH_DEB_DIR=$TOP_DIR/deb/openssh-debs

"$SCRIPTS_DIR/build_openssh_debs.sh" "$OPENSSH_PREBUILT_TAR" "$OPENSSH_DEB_DIR"

sudo cp -f "$OPENSSH_DEB_DIR"/openssh-client_*_arm64.deb \
	"$OPENSSH_DEB_DIR"/openssh-sftp-server_*_arm64.deb \
	"$OPENSSH_DEB_DIR"/openssh-server_*_arm64.deb \
	$OUTPUT_DIR/rootfs/debs/
```

进入 chroot 后安装：

```bash
dpkg -i -R /debs
```

随后脚本会清理旧的 OpenSSH 部署方式：

```bash
systemctl disable openssh-prebuilt.service firstboot-openssh.service 2>/dev/null || true
systemctl unmask ssh.service ssh.socket sshd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/openssh-prebuilt.service
rm -f /etc/systemd/system/multi-user.target.wants/firstboot-openssh.service
rm -f /etc/systemd/system/openssh-prebuilt.service
rm -f /etc/systemd/system/firstboot-openssh.service
rm -f /usr/sbin/firstboot-install-openssh.sh
rm -rf /opt/prebuilt
systemctl enable ssh.service 2>/dev/null || true
```

## 7. 仅保留一个用户名/密码

`build_rootp()` 中保留 `linaro / linaro`：

```bash
echo "linaro:linaro" | chpasswd
usermod -a -G sudo linaro
chown linaro.linaro -R /home/linaro
```

并删除默认 `admin` 用户：

```bash
if id -u admin >/dev/null 2>&1; then
	echo "remove admin user from base image"
	pkill -u admin 2>/dev/null || true
	userdel -r admin 2>/dev/null || userdel admin 2>/dev/null || true
fi
rm -rf /home/admin
if getent group admin >/dev/null 2>&1; then
	groupdel admin 2>/dev/null || true
fi
```

这样在最终 rootfs 中只保留 `linaro` 作为普通用户名/密码登录账号。

## 8. 推荐完整构建步骤

首次或源码更新后：

```bash
cd /home/lzx/work/SOPHGO/BM1684/v24/bsp_code
source bootloader-arm64/scripts/envsetup.sh
build_openssh_prebuilt
build_debs
build_rootp
```

如果已经提前执行过 `build_debs`，并且只想重新生成 rootfs：

```bash
cd /home/lzx/work/SOPHGO/BM1684/v24/bsp_code
source bootloader-arm64/scripts/envsetup.sh
build_rootp
```

如果只修改了 OpenSSH 配置，建议重新生成预编译包和 rootfs：

```bash
cd /home/lzx/work/SOPHGO/BM1684/v24/bsp_code
source bootloader-arm64/scripts/envsetup.sh
clean_openssh_prebuilt
build_openssh_prebuilt
build_rootp
```

最终 rootfs 包输出位置：

```bash
install/soc_bm1684/rootfs.tgz
```

## 9. 构建后检查方法

检查 rootfs 中 OpenSSH / OpenSSL 版本：

```bash
grep -E "^(Package|Version):" install/soc_bm1684/rootfs/var/lib/dpkg/status | \
  grep -A1 -E "Package: openssh-(server|client|sftp-server)"
```

检查 OpenSSH 程序版本：

```bash
install/soc_bm1684/rootfs/usr/bin/ssh -V
install/soc_bm1684/rootfs/usr/local/openssl-3.5.5/bin/openssl version
```

检查 sshd 配置：

```bash
grep -E "^(Port|PermitRootLogin|PasswordAuthentication|PermitEmptyPasswords)" \
  install/soc_bm1684/rootfs/usr/local/openssh-10.2p1/etc/sshd_config
```

期望结果：

```text
Port 2222
PermitRootLogin prohibit-password
PasswordAuthentication yes
PermitEmptyPasswords no
```

检查用户：

```bash
grep -E "^(root|linaro|admin):" install/soc_bm1684/rootfs/etc/passwd
```

期望结果：

```text
root 存在
linaro 存在
admin 不存在
```

检查 systemd 服务：

```bash
ls -l install/soc_bm1684/rootfs/etc/systemd/system/multi-user.target.wants/ssh.service
grep -n "ExecStart" install/soc_bm1684/rootfs/lib/systemd/system/ssh.service
```

期望 `ExecStart` 使用：

```text
/usr/sbin/sshd -D -f /usr/local/openssh-10.2p1/etc/sshd_config
```

## 10. 验收结论

当前 V24 代码已经包含：

- OpenSSH / OpenSSL 预编译流程。
- OpenSSH Debian 制包流程。
- `build_rootp` 中安装 OpenSSH Debian 包。
- `build_rootp` 中删除 `admin` 用户。
- 启用 `ssh.service`。
- 清理旧的 firstboot / prebuilt OpenSSH 服务。

需要重点确认的一项：

```text
PermitRootLogin 当前脚本写成 yes，不满足“禁用 root 密码登录”要求。
```

若改为：

```text
PermitRootLogin prohibit-password
PermitEmptyPasswords no
```

并重新执行：

```bash
build_openssh_prebuilt
build_rootp
```

则 OpenSSH 配置要求可以满足。

## 11. 总结

本次 OpenSSH 客制化不是单纯修改一个 `sshd_config`，而是把 OpenSSH / OpenSSL 从源码编译、预编译归档、Debian 制包、rootfs 集成到最终验收检查串成了一条完整流程。

这套记录也可以作为后续新 SDK 重新制作 OpenSSH 定制包的参考流程。后续如果换到新的 SDK 版本，建议仍以 2026-08-17 这套 Debian 包方式为主线：先生成 OpenSSL / OpenSSH 预编译产物，再制作 `openssh-client`、`openssh-server`、`openssh-sftp-server` 三个 deb 包，最后通过 rootfs 构建流程安装进去。这样版本、依赖、systemd 服务、dpkg 状态和验收检查都能落在系统包管理体系里，比单纯把文件拷进 rootfs 或首次启动时解压更清晰。

整体链路如下：

```text
OpenSSL / OpenSSH 源码
  -> build_openssh_prebuilt()
  -> openssh_openssl_prebuilt.tar.gz
  -> build_openssh_debs.sh
  -> openssh-client / openssh-server / openssh-sftp-server deb 包
  -> build_rootp()
  -> 安装到最终 rootfs
  -> systemd 启动 ssh.service
```

核心定制点：

- OpenSSL 使用 `3.5.5`，安装到 `/usr/local/openssl-3.5.5`。
- OpenSSH Portable 使用 `10.2p1`，安装到 `/usr/local/openssh-10.2p1`。
- OpenSSH 被重新打成 `openssh-client`、`openssh-server`、`openssh-sftp-server` 三个 Debian 包。
- `build_rootp()` 会把这三个 deb 包复制到 rootfs 的 `/debs` 目录，并在 chroot 阶段通过 `dpkg -i -R /debs` 安装。
- 最终 SSH 服务仍使用标准 `ssh.service` 启动，但 `ExecStart` 指向定制后的 `/usr/sbin/sshd` 和 `/usr/local/openssh-10.2p1/etc/sshd_config`。
- 旧的 `firstboot-openssh.service`、`openssh-prebuilt.service` 和 `/opt/prebuilt` 部署方式会被清理，避免两套 OpenSSH 启动逻辑并存。
- 默认登录账号只保留 `linaro / linaro`，基础 rootfs 中的 `admin` 用户会在 `build_rootp()` 阶段删除。

验收时重点看三类结果：

1. 包版本是否正确：`openssh-server`、`openssh-client`、`openssh-sftp-server` 应为 `1:10.2p1-1sophgo1`。
2. 服务配置是否正确：端口应为 `2222`，并显式配置 `PermitRootLogin prohibit-password`、`PermitEmptyPasswords no`。
3. rootfs 状态是否正确：`ssh.service` 正常启用，`admin` 用户不存在，`linaro` 用户可以通过密码登录。

当前需要特别注意的问题是 `build_openssh_prebuilt()` 中仍可能把 `PermitRootLogin` 写成 `yes`。如果客户验收要求是“禁止 root 密码登录”，这项必须改成：

```text
PermitRootLogin prohibit-password
```

同时补上：

```text
PermitEmptyPasswords no
```

修改后需要重新执行：

```bash
clean_openssh_prebuilt
build_openssh_prebuilt
build_rootp
```

最终以 `install/soc_bm1684/rootfs.tgz` 和解包后的 `install/soc_bm1684/rootfs` 检查结果为准。

后续迁移到新 SDK 时，可以按下面顺序复用：

1. 确认新 SDK 的 rootfs 基础发行版、架构和 systemd 路径是否仍一致。
2. 更新或复用 `openssl-3.5.5.tar.gz`、`openssh-portable-V_10_2_P1.tar.gz`。
3. 复用 `build_openssh_prebuilt()` 生成预编译压缩包。
4. 复用 `build_openssh_debs.sh` 生成三个 OpenSSH deb 包。
5. 在新 SDK 的 `build_rootp()` 中接入 deb 安装流程。
6. 检查 `sshd_config`、`ssh.service`、包版本、用户账号和端口。

除非新 SDK 的 rootfs 构建机制发生较大变化，否则不建议回退到“直接覆盖文件”或“firstboot 解压预编译包”的方式。
