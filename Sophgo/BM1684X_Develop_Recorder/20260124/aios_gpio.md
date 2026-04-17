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
        uint8_t start;          // 数据帧头 0x53
        uint8_t cmd;            // 命令字
        uint8_t len;            // 数据长度
        uint8_t data[];         // 可变长数组
    }
```
#### 相关命令字和指令操作
- 一些变量
    ```bash
        # offset
        GPIO 偏移量
        # direction
        0x01: 输入
        0x02: 输出
        # value 
        0x01: 高电平 
        0x00：低电平 
    ```

1. 初始化（INIT）
    ```bash
        # 发送 
        55 53 69 00 0D 0A
        # 接收
        53 69 02 00 01 0D 0A
    ```
2. GPIO 方向查询（D）
    ```bash
        # 发送
        53 44 01 <offset> 0D 0A
        # 返回
        53 44 02 <offset> <direction> 0D 0A
    ```
3. GPIO 读取（R）
    ```bash
        # 发送
        53 52 01 <offset> 0D 0A
        # 返回
        53 52 02 <offset> <value> 0D 0A
    ```
4. GPIO 输出（O/W）
    ```bash
        # 发送
        53 4F 02 <offset> <value> 0D 0A
        # 放回
        53 4F 02 <offset> <value> 0D 0A
    ```
5. GPIO 配置（C）
    ```bash
        # 发送
        53 43 02 <offset> <dir> 0D 0A
        53 43 03 <offset> xx xx 0D 0A
        # 返回
        53 43 ...（同格式）
    ```
6. 异常/状态帧（E）
    ```bash
        # 返回
        53 45 00 0D 0A
    ```
## 代码解析 
### 设备树层
```dts
    gpioc3 {
        gpio-controller;
        gpio-line-names = "DI0\0DI1\0DI2\0DO0\0DO1\0DO2\0\0\0\0LTE_EN\0WIFI_EN";
        cmd-timeout = <0x64>;
        current-speed = <0xf4240>;
        compatible = "aios,gpio";
        status = "okay";
        #gpio-cells = <0x02>;
        ngpios = <0x0b>;
        auto-baudrate;
    };
```
### 数据结构层
```c
struct aios_gpio_data {
    /* 设备对象 */
    // 表示底层真实硬件通道是串口设备
    struct serdev_device *serdev;
    // 表示要向 Linux GPIO 子系统注册的控制器对象
    struct gpio_chip gpio_chip;

    /* 同步对象 */
    struct mutex xfer_lock;             // 一次只允许一个GPIO请求占用串口事务
    struct completion completion;       // 串口数据接收完成

    /* 配置参数 */
    u32 timeout_ms;
    u32 ngpios;

    /* 接收数据缓存 */
    u8 rx_buffer[AIOS_RX_BUF_SIZE];             // 完整数据帧
    int rx_len;

    u8 packet_buffer[AIOS_RX_BUF_SIZE];         // 拼包缓存区
    size_t buffer_pos;

    /* 事务状态 */
    u8 expected_cmd;
    u8 expected_offset;
    bool expect_offset;
    bool response_valid;
    /* GPIO 状态缓存 */
    u8 gpio_values[AIOS_GPIO_MAX_LINES];
    u8 gpio_directions[AIOS_GPIO_MAX_LINES];
}
```
### `serdev` 层
负责打开串口、设置波特率，接收字节流、发送命令帧
```c
static const struct serdev_device_ops aiso_serdev_ops = {
    .receive_buf = aios_serdev_recv,
    .wirte_wakeup = serdev_device_write_wakeup,
};

static int aios_gpio_probe(struct serdev_device *serdev)
{
    struct device *dev = &serdev->dev;
    struct aios_gpio_data *priv;
    struct device_node *np = dev->of_node;
    u32 baudrate = 115200;
    bool auto_baudrate = true;
    int ret;
    
    dev_info(dev, "Starting AIOS GPIO probe\n");

    if (!serdev)
        return -EINVAL;

    priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
    if (!priv)
        return -ENOMEM;
    
    /* 在设备对象里留了一个“私有指针插槽”，专门给驱动自己存上下文。 */
    priv->serdev = serdev;
    serdev_device_set_drvdata(serdev, priv);

    /* 串口设备操作 */
    serdev->ops = &aiso_serdev_ops;

    ret = serdev_device_open(serdev);
    if (ret < 0) 
    {
        dev_err(dev, "Failed to open serdev device: %d\n", ret);
        return ret;
    }
    dev_info(dev, "Serdev device opened successfully\n");

    /* 获取设备树配置，ngpios是必填选项 */
    of_property_read_u32(np, "baudrate", &baudrate);
    of_property_read_u32(np, "ngpios", &priv->ngpios);
    of_property_read_u32(np, "cmd-timeout", &priv->timeout_ms);
    of_property_read_bool(np, "auto-baudrate", &auto_baudrate);

    if (!priv->timeout_ms)
        priv->timeout_ms = AIOS_DEFAULT_TIMEOUT_MS;
    
    if (!priv->ngpios || priv->ngpios > ARRAY_SIZE(priv->gpio_values)) 
    {
        dev_err(dev, "Invalid ngpios=%u\n", priv->ngpios);
        ret = -EINVAL;
        goto err_close;
    }

    /* 配置串口链路信息 */
    serdev_device_set_baudrate(serdev, baudrate);
    serdev_device_set_flow_control(serdev, false);
    serdev_device_set_parity(serdev, SERDEV_PARITY_NONE);

    dev_info(dev, "Serial device configured: %u baud, no flow control, no parity\n", baudrate);
    /* 状态控制变量 */
    mutex_init(&priv->xfer_lock);
    init_completion(&priv->completion);
    init_waitqueue_head(&priv->wait);
    /* 私有数据初始化 */
    priv->buffer_pos = 0;
    priv->rx_len = 0;
    priv->expected_cmd = 0;
    priv->expected_offset = 0;
    priv->response_valid = false;
    priv->export_offset = false;
    memset(priv->gpio_values, 0, sizeof(priv->gpio_values));
    memset(priv->gpio_directions, 0, sizeof(priv->gpio_directions));
    memset(priv->packet_buffer, 0, sizeof(priv->packet_buffer));
    memset(priv->rx_buffer, 0, sizeof(priv->rx_buffer));
    /* GPIO 控制器注册 */
    msleep(AIOS_INIT_DELAY_MS);
    priv->gpio_chip.label = "aios-gpio";
    priv->gpio_chip.parent = dev;
    priv->gpio_chip.owner = THIS_MODULE;
    priv->gpio_chip.base = -1;
    priv->gpio_chip.ngpios = priv->ngpios;
    priv->gpio_chip.can_sleep = true;
    priv->gpio_chip.get_direction = aios_gpio_query_direction;
    priv->gpio_chip.direction_input = aios_gpio_direction_input;
    priv->gpio_chip.direction_output = aios_gpio_direction_output;
    priv->gpio_chip.get = aios_gpiaios_gpio_gpio_get_valueo_get;
    priv->gpio_chip.set = aios_gpio_gpio_set_value;
    priv->gpio_chip.set_config = aios_gpio_set_config;

    ret = aios_init(priv, auto_baudrate);
    if (ret < 0) 
    {
        deverr(dev, "Failed to initialize AIOS GPIO: %d\n", ret);
        goto err_close;
    }

    ret = devm_gpiochip_add_data(dev, &priv->gpio_chip, priv);
    if (ret < 0) 
    {
        dev_err(dev, "Failed to add GPIO chip: %d\n", ret);
        goto err_close;
    }

    dev_info(dev, "AIOS GPIO expander probed, %u GPIOs\n", priv->ngpios);
    return 0;

err_close:
    serdev_device_close(serdev);
    return ret;
}

static void aios_gpio_remove(struct serdev_device *serdev)
{
    struct aios_gpio_data *priv = serdev_device_get_drvdata(serdev);
    u8 shutdown_cmd = { 0x53, 0x49, 0x00, 0x0D, 0x0A };
    if (priv && priv->ngpios > 0)
    {
        serdev_device_write_buf(serdev, shutdown_cmd, sizeof(shutdown_cmd), 0);
        serdev_device_wait_until_sent(serdev, 0);
    }
    
    serdev_device_close(serdev);
    if (priv)
        priv->serdev = NULL;
}

/* 设备 ID 表 */
static const struct of_device_id aios_gpio_of_match[] = {
    { .compatible = "aiso,gpio" },
    { }
};

/* 串行设备驱动 */
static struct serdev_device_driver aios_gpio_driver = {
    .probe = aios_gpio_probe,
    .driver = {
        .name = "aiso-gpio",
        .of_match_table = aios_gpio_of_match,
    },
    .remove = aios_gpio_remove,    
};

module_serdev_driver(aios_gpio_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("AIOS UART protocol GPIO expander");
MODULE_AUTHOR("Igotu.Qiu <qiupeiqin@cs-t.cn>");
```
### 协议层
### GPIO framwork 适配层