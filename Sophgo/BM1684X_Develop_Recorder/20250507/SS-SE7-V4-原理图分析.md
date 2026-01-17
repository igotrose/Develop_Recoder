# 原理图分析与系统架构说明
本文档用于对 BM1684X 核心板与底板的硬件原理图进行结构化分析，
重点说明电源管理、多协议复合接口以及基于 PCIe 的 I/O 扩展体系。

---
## 原理图分析概述
BM1684X 核心板通过单一 PCIe 高速接口与底板连接，同时引出多种低速与专用接口，用于完成系统扩展、控制与管理功能。

---
## 电源管理与上电控制
### 12V 输入使能

该引脚需要被上拉后，底板 12V 电源才能正常输入。
![12V 输入使能](12v_input_en.png)

---
### MCU 电源控制关系
12V 使能信号由底板 MCU 控制，用于实现整板统一上电与电源时序管理。
![MCU 电源控制](mcu_pwr_on.png)

---
## 核心板 ↔ 底板多协议复合接口
BM1684X 核心板通过多协议复合接口向底板提供，高速扩展能力与低速控制能力。
![多协议复合接口总览](soc.png)

---
### I2C 外设通信
主控出来的 I2C2 通过[TXS0102](txs0102.pdf)电平转换器转换为 I2C0 接口
![I2C 接口](soc_i2c_communication.png)
![电平转换器](i2c_level_switch.png)
#### I2C 接口外设
- RTC 实时时钟
![RTC](i2c_rtc.png)
- 加密IC，这两颗加密IC根据电阻进行选择
![N32](i2c_atsha204a_n32.png) 

---
### UART 外设通信
![UART 接口](soc_uart_communication.png)
- 调试串口
![调试串口](uart_debug.png)
- 控制类通信
![485-232](uart_485_232.png)

---
### GPIO 控制类接口
![GPIO 控制接口](soc_gpio_contral.png)
- 模块使能
- 复位控制
- 中断与状态检测

---
### PHY GMAC 以太网接口
![RGMII / MDIO](soc_rgmii_mdio.png)
![RJ45](rj45_phy.png)
- SoC 原生网络接口
- 不通过 PCIe 扩展
- 网口的灯的控制需要修改对应寄存器

---
### SDIO 接口
![SDIO 接口](soc_sdio_tf.png)
![TF 卡](sdcard.png)
- 中速外设接口
- 常用于 TF 卡或简单模块

---
### PCIe 高速扩展接口
PCIe 的 RC（Root Complex）模式一般用于 SoC 端，EP（Endpoint）模式一般用于外设端。
![PCIe 高速通信](soc_pcie_high_speed_communication.png)

---
## PCIe 扩展核心 —— [ASM3142](asm3142.pdf)
### 芯片定位
ASM3142 是系统的 PCIe → I/O 扩展核心芯片，负责将 SoC 的 PCIe 能力转换为 USB、SATA 等外设接口。
![ASM3142 总览](asm3142_usb30hub_sata_bridge.png)

---
### ASM3142 启动流程
```text
SoC（PCIe RC）
     ↓ PCIe
ASM3142（PCIe EP / I/O Bridge）
     ↑
 SPI Flash（固件）
```
启动流程说明：
1. 上电并释放复位
2. 内部 Boot ROM 启动
3. 通过 SPI Flash 加载固件
4. 初始化内部模块
5. 建立 PCIe 链路

---
### ASM3142 → USB 扩展路径
![ASM3142 到 USB3 Hub](asm3142_usb30hub.png)
#### USB3 Hub —— [RTS85411](RTS5411S-GR.PDF)
ASM3142 分出一组 USB3.0 给到四口集线器进行扩展
![RTS85411_B](RTS84511_B.png)
![RTS85411_A](RTS84511_A.png)
```text
RTS85411（USB3 Hub）
├─ USB3.0 A 口 1
├─ USB3.0 A 口 2
├─ 4G / 5G 模块
└─ 下游 USB2 Hub FE2.1
```
##### 4G / 5G 模块 
![4G/5G 接口](rts85511_45g.png)
##### USB2 Hub —— [FE2.1](FE2.1.pdf)
![USB2.0 Hub](fe2_1.png)
FE2.1 作为系统 USB2 枢纽，为无线通信、工业控制、USB 显示及外部 USB 接口提供连接能力。
```text
 FE2.1 (USB2 Hub)
    ├─ WiFi / Bluetooth
    ├─ DP108T（工业 IO）
    ├─ CH342 → MCU（工业控制）
    ├─ FL2000 → IT66121 → HDMI
    └─ USB2 外部接口 
```
- WiFi / Bluetooth 
- DP108T（工业 IO）
![DP108T 接耳机](fe2_1_dp108t_mic.png)
- CH342 → MCU（工业控制）
![CH343 转MCU](fe2_1_ch343_py32.png)
- FL2000 → IT66121 → HDMI
![USB 显示芯片](fe2_1_f2000.png) 
![HDMI TX](fe2_1_f2000_it66121_hdmi.png)
- USB2 外部接口
![USB2.0 外部接口](fe2_1_extern_usb_interface.png)

---
### ASM3142 → SATA 存储扩展
![ASM3142 SATA 扩展](asm3142_sata.png)
![硬盘接口](sata_interface.png)
ASM3142 向下连接 ASM1153， 
实现 SATA HDD / SSD 存储扩展。

---
## 系统整体架构总结
```text
SoC
└─ PCIe Root Complex
   ├─ ASM3142 (PCIe → I/O 扩展核心)
   │   ├─ USB3 Host
   │   │   └─ RTS85411 (USB3 Hub)
   │   |   └─ FE2.1 (USB2 Hub)
   |   │           ├─ WiFi / Bluetooth
   │   │           ├─ DP108T（工业 IO）
   │   │           ├─ CH342 → MCU（工业控制）
   │   │           ├─ FL2000 → IT66121 → HDMI
   │   │           └─ USB2 外部接口
   │   │
   │   └─ SATA / Storage Path
   │       └─ ASM1153
   │           └─ SATA HDD / SSD
   ├─ I2C2
   ├─ UARTx
   └─ GPIO-contral
```
---
