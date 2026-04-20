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
这一层负责协议实现，数据收发，匹配状态、缓存数据
```c
// 获取命令字
static inline u8 aios_get_tx_cmd(const u8 *data, size_t len)
{
    if (!data || !len)
        return 0;
    if (len >= 3 && data[0] == 0x55 && data[1] == AIOS_CMD_START)
        return data[2];
    if (len >= 2 && data[0] == AIOS_CMD_START)
        return data[1];
    return 0; 
}
// 获取命令偏移位
static inline u8 aios_get_tx_offset(u8 cmd)
{
    switch (cmd) {
        case AIOS_CMD_DIRECTION_QUERY:
        case AIOS_CMD_READ:
        case AIOS_CMD_OUTPUT:
            return true;
        default:
            return false;        
    }
}
// 匹配响应
static bool aios_match_response(struct aios_gpio_data *priv, u8 cmd, u8 data_len, u8 offset)
{
    if (!priv)
        return false;
    // 额外有 操作符 E 的数据包
    if (cmd == AIOS_CMD_ERROR)
        return true;
    if (cmd != priv->expected_cmd)
        return false;
    
    switch (cmd) {
        case AIOS_CMD_INIT:
        case AIOS_CMD_CONFIG:   
            return true;
        case AIOS_CMD_DIRECTION_QUERY:
        case AIOS_CMD_READ:
        case AIOS_CMD_OUTPUT:
            if (!priv->export_offset || data_len < 1)
                return false;
            return offset == priv->expected_offset;
        default:
            return false;
    }
}
// 更新缓存状态
static void aios_update_cached_state(struct aios_gpio_data *priv, u8 cmd, u8 data_len)
{
    u8 offset, value, direction;

    if(!priv || data_len < 2)
        return;
    offset = priv->rx_buffer[3];

    switch (cmd) {
        case AIOS_CMD_DIRECTION_QUERY:
            direction = priv->rx_buffer[4];
            if (offset < min_t(u32, priv->ngpios, ARRAY_SIZE(priv->gpio_directions)))
            {
                priv->gpio_directions[offset] = direction;
                dev_dbg(&priv->serdev->dev, "aios_gpio: offset=%u direction=%u\n", offset,direction);
            }
            break;
        case AIOS_CMD_READ:
            value = priv->rx_buffer[4];
            if (offset < min_t(u32, priv->ngpios, ARRAY_SIZE(priv->gpio_values)))
            {
                priv->gpio_values[offset] = value;
                dev_dbg(&priv->serdev->dev, "aios_gpio: offset=%u value=%u\n", offset,value);
            }
        case AIOS_CMD_OUTPUT:
            value = priv->rx_buffer[4];
            if (offset < min_t(u32, priv->ngpios, ARRAY_SIZE(priv->gpio_values)))
            {
                priv->gpio_values[offset] = value;
                dev_dbg(&priv->serdev->dev, "aios_gpio: offset=%u value=%u\n", offset,value);
            }
            break;
        default:
            break;
    }
}
// 接收数据包
static int aios_gpio_recv(struct serdev_device *serdev, const u8 *data, size_t count)
{
    // 拿取设备数据
    struct aios_gpio_data *priv = serdev_device_get_drvdata(serdev);
    int i, k;
    int processed = 0;

    if (!priv || !count)
        return 0;
    // 打印一遍数据
    dev_dbg(&serdev->dev, "aios_gpio: received %zu bytes\n", count);
    for (i = 0; i < count; i++) 
        dev_dbg(&serdev->dev, "aios_gpio: raw[%d] = 0x%02x\n", i, data[i]);
    // 处理数据
    for (i = 0; i < count; i++) 
    {
        u8 b = data[i];

        if (priv->buffer_pos == 0 && b != AIOS_CMD_START)
        {           
            dev_dbg(&serdev->dev, "aios_gpio: drop non-start byte 0x%02x\n", b);
            processed++;
            continue;
        }

        if (priv->buffer_pos >= AIOS_RX_BUF_SIZE)
        {
            dev_warn(&serdev->dev, "aios_gpio: buffer overflow, reset\n");
            priv->buffer_pos = 0;
        } 

        priv->packet_buffer[priv->buffer_pos++] = b;
        processed++;

        while (priv->buffer_pos >= 3) 
        {
            u8 cmd; 
            u8 data_len;
            size_t frame_len;
            u8 offset = 0;
            // 帧头重同步，接收端永远以 0x53 为帧头
            if (priv->packet_buffer[0] != AIOS_CMD_START)
            {
                memmove(&priv->packet_buffer, &priv->packet_buffer + 1, priv->buffer_pos - 1);
                priv->buffer_pos--;
                continue;
            }
            
            cmd = priv->packet_buffer[1];
            data_len = priv->packet_buffer[2];
            frame_len = 5 + data_len;
            // 帧长检测
            if (frame_len > AIOS_RX_BUF_SIZE) 
            {
                dev_warn(&serdev->dev, "aios_gpio: invalid data_len=%u, reset buffer\n", data_len);
                priv->buffer_pos = 0;
                break;
            }

            if (priv->buffer_pos < frame_len)
                break;
            // 帧尾检测
            if (priv->packet_buffer[frame_len - 2] != 0x0D || priv->packet_buffer[frame_len - 1] != 0x0A)
            {
                dev_warn(&serdev->dev, "aios_gpio: invalid frame tail, resync\n");
                memmove(&priv->packet_buffer, &priv->packet_buffer + 1, priv->buffer_pos - 1);
                priv->buffer_pos--;
                continue;
            }
            // 完整的帧
            memcpy(priv->rx_buffer, priv->packet_buffer, frame_len);
            priv->rx_len = frame_len;
            priv->response_valid = false;
            // 打印完整帧
            dev_dbg(&serdev->dev, "aios_gpio: complete frame: cmd=%c, len=%u data:\n", (char)cmd, data_len);
            for (k = 0; k< frame_len; k++)
                dev_dbg(&serdev->dev, "aios_gpio: complete frame: cmd=%c, len=%u data:\n", (char)cmd, data_len);
            // 解析命令
            if (data_len >= 1)
                offset = priv->rx_buffer[3];

            switch (cmd) 
            {
                case AIOS_CMD_INIT:
                    dev_dbg(&serdev->dev, "aios_gpio: init response received\n");
                    break;        
                case AIOS_CMD_CONFIG:
                    dev_dbg(&serdev->dev, "aios_gpio: config response received\n");
                    break;
                case AIOS_CMD_ERROR:
                    dev_warn(&serdev->dev, "aios_gpio: E response received (status/error frame)\n");
                    break;
                default:
                    break;
            }
            // 更新缓存状态
            aios_update_cached_state(priv, cmd, data_len);
            if (aios_match_response(priv, cmd, data_len, offset)) 
            {
                priv->response_valid = true;
                complete(&priv->completion);
            } 
            else 
            {
                dev_dbg(&serdev->dev, "aios_gpio: frame ignored, cmd=0x%02x expected=0x%02x  off=%u expected_off=%u\n", cmd, priv->expected_cmd, offset,  priv->expected_offset);
            }

            if (priv->buffer_pos > frame_len) 
            {
                memmove(priv->packet_buffer,
                        priv->packet_buffer + frame_len,
                        priv->buffer_pos - frame_len);
                priv->buffer_pos -= frame_len;
            } 
            else 
            {
                priv->buffer_pos = 0;
            }
        }
    }
    // 返回处理字节数
    return processed;
}
static int aios_gpio_write(struct aios_gpio_data *priv, const u8 *data, size_t count)
{
    int ret;
    u8 cmd;
    u8 offset = 0;
    bool expect_offset;

    if (!priv || !priv->serdev)
    {
        pr_err("aios_gpio: priv or serdev is NULL\n");
        return -ENODEV;
    }
    cmd = aios_get_tx_cmd(data, len);
    expect_offset = aios_tx_has_offset(cmd);
    if (expect_offset) 
        offset = aios_get_tx_offset(data, len);

    // 上锁，防止其他流数据干扰
    mutex_lock(&priv->lock);

    priv->buffer_pos = 0;
    priv->rx_len = 0;
    priv->response_valid = false;
    priv->expected_cmd = cmd;
    priv->expected_offset = offset;
    priv->expect_offset = expect_offset;
    reinit_completion(&priv->completion);

    dev_dbg(&priv->serdev->dev, "aios_gpio: write cmd=0x%02x len=%zu expected_off=%u timeout=%u\n", cmd, len, offset, priv->timeout_ms);
    ret = serdev_device_write(priv->serdev, data, len, priv->timeout_ms);
    if (ret < 0) 
    {
        dev_err(&priv->serdev->dev, "aios_gpio: write failed: %d\n", ret);
        mutex_unlock(&priv->xfer_lock);
        return ret;
    }
    // 等待下位机回应
    serdev_device_wait_until_sent(priv->serdev, priv->timeout_ms);
    if (!wait_for_completion_timeout(&priv->completion, msecs_to_jiffies(priv->timeout_ms)))
    {
        dev_err(&priv->serdev->dev, "aios_gpio: timeout waiting response for cmd=0x%02x  off=%u\n", cmd, offset);
        mutex_unlock(&priv->xfer_lock);
        return -ETIMEDOUT;
    }

    /*
     * 如果收到的是 E 帧，则视为“当前事务失败但可重试”
     */
    if (priv->rx_len >= 2 && priv->rx_buffer[1] == AIOS_CMD_ERROR) {
        mutex_unlock(&priv->xfer_lock);
        return -EAGAIN;
    }
    // 开锁
    mutex_unlock(&priv->xfer_lock);
    return 0;
}
// 设备写入重试
static int aios_gpio_write_retry(struct aios_gpio_data *priv, const u8 *data, size_t len, int retry_mas, unsigned int delay_ms)
{
    int ret, i;

    for (i = 0; i < retry_max; i++) 
    {
        ret = aios_gpio_write(priv, data, len);
        if (!ret)
            return 0;

        if (ret != -EAGAIN && ret != -ETIMEDOUT)
            return ret;

        dev_warn(&priv->serdev->dev,
                 "aios_gpio: retry %d/%d for cmd=0x%02x ret=%d\n",
                 i + 1, retry_max, aios_get_tx_cmd(data, len), ret);
        msleep(delay_ms);
    }

    return ret;
}
```
### GPIO framwork 适配层
这一层把 Linux GPIO 子系统要求的标准接口，翻译成 AIOS GPIO 能够执行的操作
```c
static int aios_gpio_query_direction(struct gpio_chip *chip, unsigned int offset)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    u8 dir;
    u8 cmd[] = {
        AIOS_CMD_START,
        AIOS_CMD_DIRECTION_QUERY,
        0x01,
        offset,
        0x0D, 0x0A
    };
    int ret;
    // 偏移值要小于GPIO数量
    if (offset >= priv->ngpios)
        return -EINVAL;
    dev_info(&priv->serdev->dev, "get_direction: offset %u\n", offset);
    // 先走缓存
    dir = priv->gpio_directions[offset];
    if (dir == AIOS_PROTO_DIR_IN)
        return GPIO_LINE_DIRECTION_IN;
    if (dir == AIOS_PROTO_DIR_OUT)
        return GPIO_LINE_DIRECTION_OUT;
    // 如果缓存没有，则走查询
    ret = aios_gpio_write_retry(priv, cmd, sizeof(cmd), AIOS_CMD_RETRY_MAX,  AIOS_RETRY_DELAY_MS);
    if (ret < 0)
        return ret;

    dir = priv->gpio_directions[offset];
    if (dir == AIOS_PROTO_DIR_IN)
        return GPIO_LINE_DIRECTION_IN;
    if (dir == AIOS_PROTO_DIR_OUT)
        return GPIO_LINE_DIRECTION_OUT;

    dev_warn(&priv->serdev->dev, "aios_gpio: unexpected direction value %u for GPIO%u\n", dir, offset);
    return -EIO;
}
// 配置？
static int aios_gpio_gpio_set_config(struct gpio_chip *chip,
                                     unsigned int offset,
                                     unsigned long config)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    u8 cmd[] = {
        AIOS_CMD_START,
        AIOS_CMD_CONFIG,
        0x03,
        offset,
        0x02,
        0x03,
        0x0D, 0x0A
    };

    dev_info(&priv->serdev->dev,
             "set_config: offset %u param %u\n",
             offset, pinconf_to_config_param(config));

    switch (pinconf_to_config_param(config)) {
    case PIN_CONFIG_PERSIST_STATE:
        return 0;

    case PIN_CONFIG_OUTPUT:
    case PIN_CONFIG_INPUT_ENABLE:
    case PIN_CONFIG_DRIVE_PUSH_PULL:
        return aios_gpio_write_retry(priv, cmd, sizeof(cmd),
                                     AIOS_CMD_RETRY_MAX,
                                     AIOS_RETRY_DELAY_MS);

    default:
        dev_err(&priv->serdev->dev,
                "Unsupported config param: %u\n",
                pinconf_to_config_param(config));
        return -ENOTSUPP;
    }
}
// 设置 GPIO 输出值
static void aios_gpio_gpio_set_value(struct gpio_chip *chip,
                                     unsigned int offset, int value)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    u8 cmd[] = {
        AIOS_CMD_START,
        AIOS_CMD_OUTPUT,
        0x02,
        offset,
        value ? 0x01 : 0x00,
        0x0D, 0x0A
    };
    int ret;

    dev_info(&priv->serdev->dev,
             "set_value: offset %u value %d\n", offset, value);

    ret = aios_gpio_write_retry(priv, cmd, sizeof(cmd),
                                AIOS_CMD_RETRY_MAX,
                                AIOS_RETRY_DELAY_MS);
    if (ret < 0) {
        dev_err(chip->parent, "Failed to set GPIO value: %d\n", ret);
        return;
    }

    if (offset < min_t(u32, priv->ngpios, ARRAY_SIZE(priv->gpio_values)))
        priv->gpio_values[offset] = value ? 0x01 : 0x00;
}
// 获取 GPIO 输入值
static int aios_gpio_gpio_get_value(struct gpio_chip *chip,
                                    unsigned int offset)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    u8 cmd[] = {
        AIOS_CMD_START,
        AIOS_CMD_READ,
        0x01,
        offset,
        0x0D, 0x0A
    };
    int ret;

    if (offset >= priv->ngpios)
        return -EINVAL;

    dev_info(&priv->serdev->dev, "get_value: offset %u\n", offset);

    ret = aios_gpio_write_retry(priv, cmd, sizeof(cmd),
                                AIOS_CMD_RETRY_MAX,
                                AIOS_RETRY_DELAY_MS);
    if (ret < 0)
        return ret;

    return priv->gpio_values[offset] ? 1 : 0;
}
// 设置 GPIO 输出方向
static int aios_gpio_gpio_direction_output(struct gpio_chip *chip,
                                           unsigned int offset, int value)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    int ret;
    u8 cmd[] = {
        AIOS_CMD_START,
        AIOS_CMD_CONFIG,
        0x02,
        offset,
        AIOS_PROTO_DIR_OUT,
        0x0D, 0x0A
    };

    dev_info(&priv->serdev->dev, "set_output: offset %u\n", offset);

    ret = aios_gpio_write_retry(priv, cmd, sizeof(cmd),
                                AIOS_CMD_RETRY_MAX,
                                AIOS_RETRY_DELAY_MS);
    if (ret < 0)
        return ret;

    aios_gpio_gpio_set_value(chip, offset, value);
    return 0;
}
// 获取 GPIO 输入方向
static int aios_gpio_gpio_direction_input(struct gpio_chip *chip,
                                          unsigned int offset)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    u8 cmd[] = {
        AIOS_CMD_START,
        AIOS_CMD_CONFIG,
        0x02,
        offset,
        AIOS_PROTO_DIR_IN,
        0x0D, 0x0A
    };

    dev_info(&priv->serdev->dev, "set_input: offset %u\n", offset);

    return aios_gpio_write_retry(priv, cmd, sizeof(cmd),
                                 AIOS_CMD_RETRY_MAX,
                                 AIOS_RETRY_DELAY_MS);
}
```
### 设备初始化层
这里就负责注册 GPIO 控制器之前的下位准备
```c
static int aios_init(struct aios_gpio_data *priv, bool auto_baudrate)
{
    u8 init_cmd[] = {
        0x55,
        AIOS_CMD_START,
        AIOS_CMD_INIT,
        0x00,
        0x0D, 0x0A
    };
    u8 sync = 0x55;
    u8 init_dir_cmd[] = {
        AIOS_CMD_START,
        AIOS_CMD_DIRECTION_QUERY,
        0x01,
        0x00,
        0x0D, 0x0A
    };

    if (auto_baudrate) 
    {
        serdev_device_write(priv->serdev, &sync, 1, priv->timeout_ms);
        serdev_device_wait_until_sent(priv->serdev, priv->timeout_ms);
        msleep(10);
    }
    // 发送初始化指令
    ret = aios_gpio_write_retry(priv, init_cmd, sizeof(init_cmd),
                                AIOS_INIT_RETRY_MAX,
                                AIOS_RETRY_DELAY_MS);
    if (ret < 0) {
        pr_err("aios_gpio,Initialization: command failed: %d\n", ret);
        return ret;
    }
    // 逐个查询 IO 方向
    for (i = 0; i < priv->ngpios; i++) 
    {
        init_dir_cmd[3] = i;

        ret = aios_gpio_write_retry(priv, init_dir_cmd, sizeof(init_dir_cmd),
                                    AIOS_INIT_RETRY_MAX,
                                    AIOS_RETRY_DELAY_MS);
        if (ret < 0) {
            pr_err("aios_gpio,Initialization: Failed to query direction for GPIO %d: %d\n",
                   i, ret);
            return ret;
        }

        usleep_range(AIOS_QUERY_GAP_US_MIN, AIOS_QUERY_GAP_US_MAX);
    }

    return 0;
}
```