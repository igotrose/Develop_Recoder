# RK3288编译
## Android SDK
### 全局编译

### 局部编译
- u-boot
    ```bash
    cd u-boot
    # u-boot 配置
    make rk3288_secure_defconfig
    # 执行编译    
    ./mkv7.sh
    # 清除旧编译
    make distclean 
    make mrproper  
    ```
- kernel
    ```bash
    cd kernel
    make ARCH=arm rockchip_defconfig
    make ARCH=arm rk3288-evb-android-rk808-edp.img -j8
    ```
- android
    ```bash 
    source build/envsetup.sh
    lunch rk3288-userdebug
    make -j$(nproc)
    ```

### 打包生成镜像
```bash
./mkimage.sh 
./build.sh -u 
```