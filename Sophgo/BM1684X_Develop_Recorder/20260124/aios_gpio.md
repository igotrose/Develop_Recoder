# AIOS_GPIO 驱动解析
## 与下位机的通信协议解析
### 完整的数据帧格式
通过 Ghidra 进行模块固件反编译，分析汇编代码和伪C代码
```
[start] [cmd] [len] [data] [0x0d] [0x0a]
```
对应的数据结构应该是
```c
struct aios_gpio_cmd {
    uint8_t start;
    uint8_t cmd;
    uint8_t len;
    uint8_t data[];         // 可变长数组
}
```
## 代码解析