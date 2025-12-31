# RK3588 Linux 
## 编译
- SDK编译命令查看
    ```bash
    make help 
    # 或者
    ./build.sh -h
    ```
- SDK板级配置
    ```bash
    make  rockchip_defconfig
    # 或者
    ./build.sh lunch
    ```
- 全自动编译
    ```bash 
    ./build.sh all # 只编译模块代码，不打包

    ./build.sh 
    ```
    默认编译Buildroot，如果需要指定不同的rootfs，需要指定`RK_ROOTFS_SYSTEM`环境变量，如：
    ```bash
    export RK_ROOTFS_SYSTEM=debian
    ```
- 模块编译
    - U-Boot编译
        ```bash
        ./build.sh uboot
        ```
    - Kernel编译
        ```bash
        ./build.sh kernel
        ```
    - Recovery编译
        ```bash
        ./build.sh recovery
        ```
    - Rootfs编译
        ```bash
        ./build.sh rootfs
        ```
        
## 烧写工具
- window下使用`"<SDK>\RKTools\windows\RKDevTool_v3.19_for_window\RKDevTool.exe"`进行升级
    - 正常情况下
    识别到adb设备之后可以在`RKDevTool.exe`切换到`loader`模式进行升级，也可以串口进入终端切换模式进行升级
    - 异常状况下
    按住板载`boot`键，按下电源开关进入`maskroom`模式进行全片升级 
    ![alt text](maskroom.png)
- SD升级启动使用`"<SDK>\RKTools\windows\SDDiskTool_v1.76\SD_Firmware_Tool.exe"`制作SD卡镜像
- 写号工具使用`RKTools\windows\RKDevInfoWriteTool_Setup_V1.0.3.rar`   