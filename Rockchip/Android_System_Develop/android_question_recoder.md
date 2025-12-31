# Rockchip - Android 开发问题记录
## 2025-11-19
板子型号SS-RK3588-V2.0，调试驱动，使用android13系统
- device使用`rockchip_defconfig`
- kernel使用`rockchip_defconfig`
- dts使用`rk3588-evb7-lp4.dtsi`
### 调试屏幕
LCD屏幕一般调试流程：电源、背光、引脚、时序
#### 电源配置
`regulator` 框架是 Linux 内核中用于管理电压和电流调节器（如 LDO、DCDC 转换器等）的一个子系统。它提供了一个抽象层，使得驱动程序和内核的其他部分可以以一致的方式与调节器进行交互，而无需了解底层硬件的细节。
- 参考文档
    ```
    # regulator 的设备树参考文档
    kernel/Documentation/devicetree/bindings/regulator/fixed-regulator.yaml
    ```
- 原理图
    ![alt text](20251119/lcd_power_h.png)
    ![alt text](20251119/lcd_power.png)
1. `dts` 设备树配置部分 
    ```dts
    vcc12v_lcd_en: vcc12v-lcd-en {
        compatible = "regulator-fixed";
        # regulator-name 名称，用于用户空间识别
        regulator-name = "vcc12v_lcd";
        # 电压范围
        regulator-min-microvolt = <12000000>;
        regulator-max-microvolt = <12000000>;
        # gpio控制
        gpio = <&gpio1 RK_PA2 GPIO_ACTIVE_HIGH>;
        enable-active-high;
        # 系统启动时就开启此regulator
        regulator-boot-on;
        # 系统一直开启此regulator
        regulator-always-on;
        pinctrl-names = "default";
        pinctrl-0 = <&lcd_pwr_en>;
    };

    vcc5v0_lcd_en: vcc5v0-lcd-en { 
        compatible = "regulator-fixed";
        regulator-name = "vcc5v_lcd";
        regulator-min-microvolt = <5000000>;
        regulator-max-microvolt = <5000000>;
        gpio = <&gpio1 RK_PA3 GPIO_ACTIVE_HIGH>;
        vin-supply = <&vcc12v_lcd_en>;
        enable-active-high;
        regulator-boot-on;
        regulator-always-on;
        pinctrl-names = "default";
        pinctrl-0 = <&lcd_pwr_en>;
    };

    vcc3v3_lcd_en: vcc3v3-lcd-en {
        compatible = "regulator-fixed";
        regulator-name = "vcc3v3_en";
        regulator-min-microvolt = <3300000>; 
        regulator-max-microvolt = <3300000>;
        gpio = <&gpio2 RK_PC1 GPIO_ACTIVE_HIGH>;
        vin-supply = <&vcc5v0_lcd_en>;
        enable-active-high;
        regulator-boot-on;
        regulator-always-on;
        pinctrl-names = "default";
        pinctrl-0 = <&lcd_pwr_en>;
    };

    &pinctrl {
    lcd_pwr_en: lcd-pwr-en {
        rockchip,pins =
            <1 RK_PA2 RK_FUNC_GPIO &pcfg_pull_none>,   // vcc12v_lcd_en
            <1 RK_PA3 RK_FUNC_GPIO &pcfg_pull_none>,   // vcc5v0_lcd_en
            <2 RK_PC1 RK_FUNC_GPIO &pcfg_pull_none>;   // vcc3v3_lcd_en
        };
    };
    ```
2. 驱动代码位置`drivers/regulator/`
3. 功能验证
    - 查看regulator是否注册成功
        ```bash
        ls /sys/class/regulator/
        for r in /sys/class/regulator/regulator.*; do
            echo "$r: $(cat $r/name 2>/dev/null)"
        done
        ```
    - 根据原理图贴片图，万用表测量相应电源
#### 屏幕背光
- 参考文档
    ```
    《Rockchip_Developer_Guide_Linux_PWM_CN.pdf》
    Documentation/devicetree/bindings/pwm/pwm.txt
    ```
1. `dts` 设备树配置部分
    ```dts
    backlight: backlight {
        compatible = "pwm-backlight";
        pwms = <&pwm1 0 25000 0>;
        brightness-levels = <
              0  20  20  21  21  ... 254 255
        >;
        default-brightness-level = <100>;
        default-on;
        power-supply = <&vcc3v3_lcd_en>;
        pinctrl-names = "default";
        pinctrl-0 = <&pwm1m0_pins>;
    };

    &pwm1 {
        status = "okay";
    };
    ```
2. 驱动代码位置`drivers/pwm/pwm-rockchip.c`
3. 功能验证
    - 查看是否存在背光设备
        ```bash
        ls /sys/class/backlight/
        ```
    - 查看设备详细信息
        ```bash 
        cat /sys/class/backlight/backlight/
        actual_brightness     brightness max_brightness
        scale type bl_power device/
        power/ subsystem/ uevent
        ```
    - 查看pwm设备
        ```bash
        cat /sys/kernel/debug/pwm
        ```
    - 查看内核日志
        ```bash
        dmesg | grep pwm
        dmesg | grep backlight
        ```
#### MIPI屏
- 参考文档
    ```
    《Rockchip_RK3588_Developer_Guide_MIPI_DSI2_CN.pdf》
    ```   
- 原理图
    ![alt text](20251120/mipi.png)
1. `dts` 设备树配置部分
    ```dts
    &dsi0 {
        status = "okay";
            panel@0 {
                # 通用MIPI屏幕驱动
                compatible = "simple-panel-dsi";
                reg = <0>;
                backlight = <&backlight>;
                # 屏幕工作模式
                dsi,flags = <(MIPI_DSI_MODE_VIDEO | MIPI_DSI_MODE_VIDEO_BURST | 
                    MIPI_DSI_MODE_LPM | MIPI_DSI_MODE_EOT_PACKET)>;
                dsi,format = <MIPI_DSI_FMT_RGB888>;
                dsi,lanes = <4>;
                enable-delay-ms = <120>;  //after open backlight delay
                prepare-delay-ms = <120>;    //after enable delay
                # 释放复位信号之后等待120ms
                reset-delay-ms=<120>;
                unprepare-delay-ms = <120>;   //screen low power 
                disable-delay-ms = <120>;
                init-delay-ms = <300>;
                # 屏厂提供的初始化序列，根据对应的格式进行转化
                panel-init-sequence = [
                    39 00 04 FF 98 81 03
                    15 00 02 01 00
                    ......
                    39 00 04 FF 98 81 00
                    15 78 02 11 00
                    15 20 02 29 00
                    ];
                # 屏厂提供的屏参
                display-timings {
                    native-mode = <&timing0>;
                    timing0: timing0 {
                        clock-frequency = <66000000>;
                        hactive = <800>;
                        vactive = <1280>;
                        hback-porch = <18>;
                        hfront-porch = <18>;
                        vback-porch = <8>;
                        vfront-porch = <16>;
                        hsync-len = <18>;
                        vsync-len = <4>;
                        hsync-active = <0>;
                        vsync-active = <0>;
                        de-active = <0>;
                        pixelclk-active = <0>;	
                    };
                };
        };
    };

    &route_dsi0 {
        status = "okay";
        connect = <&vp3_out_dsi0>;
    };

    &dsi0_in_vp2 {
        status = "okay";
    };

    &dsi0_in_vp3 {
        status = "disabled";
    };

    &dsi0_panel {
        reset-gpios = <&gpio0 RK_PD3 GPIO_ACTIVE_LOW>;
        pinctrl-names = "default";
        pinctrl-0 = <&lcd_rst_gpio>;
    };

    ```
2. `menuconfig` 配置部分
    ```bash
    CONFIG_ROCKCHIP_DW_MIPI_DSI=y 
    ```
3. 驱动代码位置`drivers/gpu/drm/rockchip/dw-mipi-dsi2-rockchip.c`
4. dts的屏参部分需要通过平厂提供的参数进行配置
#### TP触摸
- 原理图
    ![alt text](20251120/touchscreen.png) 
1. `dts` 设备树配置部分
    ```dts
    &i2c5 {
        status = "okay";
        pinctrl-names = "default";
        pinctrl-0 = <&i2c5m0_xfer>;
        clock-frequency = <400000>;
    
        gt9xx: gt9xx@5d{ 
            compatible = "goodix,gt9271";
            reg = <0x5d>;
            # 中断信号源
            interrupt-parent = <&gpio3>;
            # 低电平触发中断            
            interrupts = <RK_PC0 IRQ_TYPE_LEVEL_LOW>;
            pinctrl-names = "default";
            pinctrl-0 = <&touch_gpio>;
            goodix,rst-gpio = <&gpio3 RK_PC1 GPIO_ACTIVE_HIGH>;
            touch-gpio = <&gpio3 RK_PC0 IRQ_TYPE_LEVEL_LOW>;
            max-x = <800>;
            max-y = <1280>;
            # 坐标翻转
            touchscreen-inverted-x;
            touchscreen-inverted-y;
            status = "okay";
        };
    };
    ```
2. `menuconfig` 配置部分
    ```bash
    CONFIG_INPUT_TOUCHSCREEN=y
    CONFIG_TOUCHSCREEN_GOODIX=y
    ```
3. 驱动代码位置`drivers/input/touchscreen/goodix.c`
4. 功能验证
    - 查看总线上是否有设备
        ```bash\
        i2cdetect -y 5
        ```
    - 查看内核日志
        ```bash
        dmesg | grep goodix
        ```
    - 列出输入设备
        ```bash
        ls /dev/input/
        ```
