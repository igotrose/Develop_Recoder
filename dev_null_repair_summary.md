# 现场物理开关机进入 GRUB 修复 `/dev/null` 指引

## 1. 问题背景

当前机器上的 `/dev/null` 已经损坏。

错误状态：

```bash
-rw-r--r-- 1 root root 0 Jun  2 08:47 /dev/null
```

正常状态应该是：

```bash
crw-rw-rw- 1 root root 1, 3 /dev/null
```

区别：

```text
错误：-rw-r--r--  普通文件
正确：crw-rw-rw-  字符设备
```

`/dev/null` 损坏后，很多程序会异常，例如：

```text
git
sudo
ssh
shell
make
编译脚本
systemd 服务
后台程序
```

典型报错：

```bash
fatal: could not open '/dev/null' for reading and writing: Permission denied
```

根本原因不是 Git 仓库损坏，而是系统设备节点 `/dev/null` 被误改成了普通文件。

---

## 2. 本文目标

本文只描述：

```text
现场物理开关机
进入 GRUB
进入 recovery mode 或 init=/bin/bash
修复 /dev/null
重启系统
验证恢复
```

不依赖 SSH，不依赖远程登录。

---

## 3. 现场需要准备

需要现场具备以下条件之一：

```text
显示器 + 键盘
服务器远程控制台
IPMI / iKVM
串口控制台
```

如果是普通服务器，最直接方式是：

```text
1. 给服务器接显示器
2. 接 USB 键盘
3. 现场按电源键重启
4. 开机时进入 GRUB
```

---

## 4. 物理重启方式

### 4.1 优先短按电源键

如果系统还在运行，先短按一次电源键。

正常情况下，Linux 会收到 ACPI power button 事件，然后执行正常关机。

等待机器关机后，再按电源键开机。

### 4.2 如果短按无反应

如果短按电源键没有反应，或者系统已经卡住，可以长按电源键强制断电。

一般操作：

```text
长按电源键 5 ~ 10 秒
等待机器完全断电
再按电源键开机
```

注意：强制断电可能导致未同步的数据丢失，但当前需要进入恢复环境修复系统设备节点。

---

## 5. 开机进入 GRUB

机器重新上电后，看到主板 Logo 或黑屏刚亮时，马上连续按键。

### 5.1 UEFI 启动方式

连续点按：

```text
Esc
```

### 5.2 Legacy BIOS 启动方式

按住或连续点按：

```text
Shift
```

### 5.3 不确定是哪种启动方式

不确定时可以这样操作：

```text
开机后连续点按 Esc
同时可以尝试按住 Shift
```

看到类似菜单，说明进入了 GRUB：

```text
Ubuntu
Advanced options for Ubuntu
UEFI Firmware Settings
```

---

## 6. 优先方案：进入 recovery mode 修复

### 6.1 选择高级启动项

在 GRUB 菜单中选择：

```text
Advanced options for Ubuntu
```

按回车。

### 6.2 选择 recovery mode 内核

选择带有：

```text
recovery mode
```

的启动项，例如：

```text
Ubuntu, with Linux 5.10.xxx-generic (recovery mode)
```

按回车进入。

### 6.3 进入 root shell

进入 recovery 菜单后，选择：

```text
root - Drop to root shell prompt
```

按回车。

如果提示按 Enter 继续，就按 Enter。

---

## 7. 在 recovery root shell 中修复 `/dev/null`

进入 root shell 后，先把根文件系统重新挂载为可写：

```bash
mount -o remount,rw /
```

删除错误的普通文件 `/dev/null`：

```bash
rm -f /dev/null
```

重新创建正确的字符设备：

```bash
mknod -m 666 /dev/null c 1 3
```

设置属主：

```bash
chown root:root /dev/null
```

检查结果：

```bash
ls -l /dev/null
```

正确结果必须类似：

```bash
crw-rw-rw- 1 root root 1, 3 /dev/null
```

测试写入：

```bash
echo test > /dev/null
```

如果没有报错，说明 `/dev/null` 修复成功。

同步磁盘：

```bash
sync
```

重启：

```bash
reboot -f
```

---

## 8. 如果 recovery mode 进不去：使用 `init=/bin/bash`

如果 recovery mode 进不去，或者菜单里没有 recovery mode，可以使用 `init=/bin/bash` 方式进入最小 root shell。

### 8.1 编辑 GRUB 启动项

在 GRUB 主菜单中，选中普通启动项：

```text
Ubuntu
```

不要回车，按：

```text
e
```

进入编辑界面。

### 8.2 修改 linux 启动参数

找到以 `linux` 开头的那一行，类似：

```text
linux /boot/vmlinuz-xxx root=UUID=xxx ro quiet splash
```

需要做两处修改。

第一，把：

```text
ro
```

改成：

```text
rw
```

第二，在这一行最后加上：

```text
init=/bin/bash
```

最终类似：

```text
linux /boot/vmlinuz-xxx root=UUID=xxx rw quiet splash init=/bin/bash
```

### 8.3 启动进入 root shell

按：

```text
Ctrl + X
```

或者：

```text
F10
```

启动。

系统会直接进入 root shell。

---

## 9. 在 `init=/bin/bash` 模式下修复 `/dev/null`

进入 shell 后执行：

```bash
mount -o remount,rw /
rm -f /dev/null
mknod -m 666 /dev/null c 1 3
chown root:root /dev/null
ls -l /dev/null
echo test > /dev/null
sync
```

正确的 `/dev/null` 应该显示为：

```bash
crw-rw-rw- 1 root root 1, 3 /dev/null
```

然后重启：

```bash
reboot -f
```

如果 `reboot -f` 不生效，可以尝试：

```bash
exec /sbin/init
```

如果仍然不行，现场短按或长按电源键重启。

---

## 10. 如果看不到 GRUB 菜单

有些 Ubuntu 默认隐藏 GRUB 菜单。

可以尝试以下方式：

```text
1. 机器刚上电就连续点按 Esc
2. 如果 Esc 无效，重启后按住 Shift
3. 如果仍然无效，尝试在 BIOS Logo 出现前后反复按 Esc
4. 使用有线 USB 键盘，避免无线键盘在 BIOS 阶段不可用
5. 更换主板后置 USB 口，不要接前置 Hub
```

如果还是看不到 GRUB，建议使用 Live USB / Rescue 模式修复。

---

## 11. Live USB / Rescue 模式备用方案

如果 GRUB 无法进入，可以用 Ubuntu Live USB 启动。

进入 Live 系统后，先找到原系统根分区：

```bash
lsblk -f
```

假设原系统根分区是 `/dev/sda2`，挂载它：

```bash
sudo mount /dev/sda2 /mnt
```

如果系统有单独的 `/boot` 分区，也需要挂载：

```bash
sudo mount /dev/sda1 /mnt/boot
```

进入原系统根目录：

```bash
sudo chroot /mnt
```

修复 `/dev/null`：

```bash
rm -f /dev/null
mknod -m 666 /dev/null c 1 3
chown root:root /dev/null
ls -l /dev/null
echo test > /dev/null
sync
exit
```

卸载并重启：

```bash
sudo umount /mnt/boot 2>/dev/null || true
sudo umount /mnt
sudo reboot
```

---

## 12. 系统启动后的最终验证

系统正常启动后，在本地终端或后续 SSH 中执行：

```bash
ls -l /dev/null
```

必须看到：

```bash
crw-rw-rw- 1 root root 1, 3 /dev/null
```

再执行：

```bash
echo test > /dev/null
```

不报错说明正常。

然后回到原来的 Git 仓库：

```bash
cd ~/workspace/Rockchip/rk3588/linux/SS-rk3588-linux/ubuntu
git add .
```

如果 `git add .` 不再报：

```bash
fatal: could not open '/dev/null' for reading and writing: Permission denied
```

说明问题已经修复。

---

## 13. 快速命令汇总

### recovery mode / init=/bin/bash 中执行

```bash
mount -o remount,rw /
rm -f /dev/null
mknod -m 666 /dev/null c 1 3
chown root:root /dev/null
ls -l /dev/null
echo test > /dev/null
sync
reboot -f
```

正确结果：

```bash
crw-rw-rw- 1 root root 1, 3 /dev/null
```

---

## 14. 结论

本问题的核心是：

```text
/dev/null 被错误地变成普通文件，导致系统程序无法正常读写 /dev/null。
```

正确修复方式是：

```text
删除错误的 /dev/null
重新创建字符设备 c 1 3
权限设置为 666
属主设置为 root:root
```

现场处理优先级：

```text
1. 物理重启进入 GRUB
2. 优先进入 recovery mode
3. recovery 不行则使用 init=/bin/bash
4. GRUB 进不去则使用 Live USB / Rescue 模式
```
