# RK3566 Android 
## 编译
### 全自动编译
1. 选择配置
    ```bash 
    source build/envsetup.sh
    lunch rk3588s_userdebug
    ```
2. 全部编译
    ```bash
    ./build.sh -AUCKuV [Version]
    ```
3. 局部编译
    - android 编译
        ```bash
        ./build.sh -A 
        ```
    - kernel 编译
        ```bash
        ./build.sh -K
        ```
    - uboot 编译
        ```bash
        ./build.sh -U
        # 或者
        cd u-boot
        ./make.sh rk3588
        ```
    - 打包
        ```bash
        ./build.sh -u
        ```
