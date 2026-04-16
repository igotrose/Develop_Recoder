// gpio-aios.c - AIOS UART protocol GPIO expander driver

#include <linux/module.h>
#include <linux/serdev.h>
#include <linux/gpio/driver.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/completion.h>
#include <linux/wait.h>
#include <linux/serial.h>
#include <linux/string.h>
#include <linux/mutex.h>
#include <linux/kernel.h>
#include <linux/delay.h>
#include <linux/errno.h>

#include "aios_gpio.h"

/*
 * 协议里的方向值，不是 Linux gpio framework 的方向值。
 *   direction = 1 -> 输入
 *   direction = 2 -> 输出
 */
#define AIOS_PROTO_DIR_IN              0x01
#define AIOS_PROTO_DIR_OUT             0x02

#define AIOS_INIT_RETRY_MAX            3
#define AIOS_CMD_RETRY_MAX             3
#define AIOS_RETRY_DELAY_MS            10
#define AIOS_QUERY_GAP_US_MIN          2000
#define AIOS_QUERY_GAP_US_MAX          5000

static inline u8 aios_get_tx_cmd(const u8 *data, size_t len)
{
    if (!data || !len)
        return 0;

    /* init 可能是: 55 53 69 00 0D 0A */
    if (len >= 3 && data[0] == 0x55 && data[1] == AIOS_CMD_START)
        return data[2];

    /* 普通帧: 53 CMD LEN ... */
    if (len >= 2 && data[0] == AIOS_CMD_START)
        return data[1];

    return 0;
}

static inline bool aios_tx_has_offset(u8 cmd)
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

static inline u8 aios_get_tx_offset(const u8 *data, size_t len)
{
    u8 cmd = aios_get_tx_cmd(data, len);

    if (!aios_tx_has_offset(cmd))
        return 0;

    if (len >= 4 && data[0] == AIOS_CMD_START)
        return data[3];

    return 0;
}

static bool aios_match_response(struct aios_gpio_data *priv,
                                u8 cmd, u8 data_len, u8 offset)
{
    if (!priv)
        return false;

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
        if (!priv->expect_offset || data_len < 1)
            return false;
        return offset == priv->expected_offset;

    default:
        return false;
    }
}

static void aios_update_cached_state(struct aios_gpio_data *priv,
                                     u8 cmd, u8 data_len)
{
    u8 offset, value, direction;

    if (!priv || data_len < 2)
        return;

    offset = priv->rx_buffer[3];

    switch (cmd) {
    case AIOS_CMD_DIRECTION_QUERY:
        direction = priv->rx_buffer[4];
        if (offset < min_t(u32, priv->ngpios,
                           ARRAY_SIZE(priv->gpio_directions))) {
            priv->gpio_directions[offset] = direction;
            dev_dbg(&priv->serdev->dev,
                    "aios_gpio: offset=%u direction=%u\n",
                    offset, direction);
        }
        break;

    case AIOS_CMD_READ:
        value = priv->rx_buffer[4];
        if (offset < min_t(u32, priv->ngpios,
                           ARRAY_SIZE(priv->gpio_values))) {
            priv->gpio_values[offset] = value;
            dev_dbg(&priv->serdev->dev,
                    "aios_gpio: offset=%u value=%u\n",
                    offset, value);
        }
        break;

    case AIOS_CMD_OUTPUT:
        value = priv->rx_buffer[4];
        if (offset < min_t(u32, priv->ngpios,
                           ARRAY_SIZE(priv->gpio_values))) {
            priv->gpio_values[offset] = value;
            dev_dbg(&priv->serdev->dev,
                    "aios_gpio: GPIO%u set to %u\n",
                    offset, value);
        }
        break;

    default:
        break;
    }
}

/*
 * 接收数据处理：
 * - 同步到帧头 0x53
 * - 按 len+5 组帧
 * - 尾巴必须是 0x0D 0x0A
 * - 合法帧才更新缓存和 complete()
 */
static int aios_gpio_recv(struct serdev_device *serdev,
                          const u8 *data, size_t count)
{
    struct aios_gpio_data *priv = serdev_device_get_drvdata(serdev);
    int i, k;
    int processed = 0;

    if (!priv || !count)
        return 0;

    dev_dbg(&serdev->dev, "aios_gpio: received %zu bytes\n", count);
    for (i = 0; i < count; i++)
        dev_dbg(&serdev->dev, "aios_gpio: raw[%d] = 0x%02x\n", i, data[i]);

    for (i = 0; i < count; i++) {
        u8 b = data[i];

        if (priv->buffer_pos == 0 && b != AIOS_CMD_START) {
            dev_dbg(&serdev->dev,
                    "aios_gpio: drop non-start byte 0x%02x\n", b);
            processed++;
            continue;
        }

        if (priv->buffer_pos >= AIOS_RX_BUF_SIZE) {
            dev_warn(&serdev->dev,
                     "aios_gpio: rx buffer overflow, reset\n");
            priv->buffer_pos = 0;
        }

        priv->packet_buffer[priv->buffer_pos++] = b;
        processed++;

        while (priv->buffer_pos >= 3) {
            u8 cmd;
            u8 data_len;
            size_t frame_len;
            u8 offset = 0;

            if (priv->packet_buffer[0] != AIOS_CMD_START) {
                memmove(priv->packet_buffer,
                        priv->packet_buffer + 1,
                        priv->buffer_pos - 1);
                priv->buffer_pos--;
                continue;
            }

            cmd = priv->packet_buffer[1];
            data_len = priv->packet_buffer[2];
            frame_len = (size_t)data_len + 5;

            if (frame_len > AIOS_RX_BUF_SIZE) {
                dev_warn(&serdev->dev,
                         "aios_gpio: invalid data_len=%u, reset buffer\n",
                         data_len);
                priv->buffer_pos = 0;
                break;
            }

            if (priv->buffer_pos < frame_len)
                break;

            if (priv->packet_buffer[frame_len - 2] != 0x0D ||
                priv->packet_buffer[frame_len - 1] != 0x0A) {
                dev_warn(&serdev->dev,
                         "aios_gpio: invalid frame tail, resync\n");
                memmove(priv->packet_buffer,
                        priv->packet_buffer + 1,
                        priv->buffer_pos - 1);
                priv->buffer_pos--;
                continue;
            }

            memcpy(priv->rx_buffer, priv->packet_buffer, frame_len);
            priv->rx_len = frame_len;
            priv->response_valid = false;

            dev_dbg(&serdev->dev,
                    "aios_gpio: complete frame: cmd=%c, len=%u data:\n",
                    (char)cmd, data_len);
            for (k = 0; k < frame_len; k++)
                dev_dbg(&serdev->dev,
                        "aios_gpio: 0x%02x\n", priv->rx_buffer[k]);

            if (data_len >= 1)
                offset = priv->rx_buffer[3];

            switch (cmd) {
            case AIOS_CMD_INIT:
                dev_dbg(&serdev->dev, "aios_gpio: init response received\n");
                break;

            case AIOS_CMD_CONFIG:
                dev_dbg(&serdev->dev, "aios_gpio: config response received\n");
                break;

            case AIOS_CMD_ERROR:
                dev_warn(&serdev->dev,
                         "aios_gpio: E response received (status/error frame)\n");
                break;

            default:
                break;
            }

            aios_update_cached_state(priv, cmd, data_len);

            if (aios_match_response(priv, cmd, data_len, offset)) {
                priv->response_valid = true;
                complete(&priv->completion);
            } else {
                dev_dbg(&serdev->dev,
                        "aios_gpio: frame ignored, cmd=0x%02x expected=0x%02x off=%u expected_off=%u\n",
                        cmd, priv->expected_cmd,
                        offset, priv->expected_offset);
            }

            if (priv->buffer_pos > frame_len) {
                memmove(priv->packet_buffer,
                        priv->packet_buffer + frame_len,
                        priv->buffer_pos - frame_len);
                priv->buffer_pos -= frame_len;
            } else {
                priv->buffer_pos = 0;
            }
        }
    }

    return processed;
}

/*
 * 发送一帧并等待响应
 * 返回：
 *   0         成功
 *   -EAGAIN   收到 E 帧，建议调用方重试当前命令
 *   -ETIMEDOUT 超时
 *   其他       底层发送错误
 */
static int aios_gpio_write(struct aios_gpio_data *priv,
                           const u8 *data, size_t len)
{
    int ret;
    u8 cmd;
    u8 offset = 0;
    bool expect_offset;

    if (!priv || !priv->serdev) {
        pr_err("aios_gpio: priv or serdev is NULL\n");
        return -ENODEV;
    }

    cmd = aios_get_tx_cmd(data, len);
    expect_offset = aios_tx_has_offset(cmd);
    if (expect_offset)
        offset = aios_get_tx_offset(data, len);

    mutex_lock(&priv->xfer_lock);

    priv->buffer_pos = 0;
    priv->rx_len = 0;
    priv->response_valid = false;
    priv->expected_cmd = cmd;
    priv->expected_offset = offset;
    priv->expect_offset = expect_offset;

    reinit_completion(&priv->completion);

    dev_dbg(&priv->serdev->dev,
            "aios_gpio: write cmd=0x%02x len=%zu expected_off=%u timeout=%u\n",
            cmd, len, offset, priv->timeout_ms);

    ret = serdev_device_write(priv->serdev, data, len, priv->timeout_ms);
    if (ret < 0) {
        dev_err(&priv->serdev->dev, "aios_gpio: write failed: %d\n", ret);
        mutex_unlock(&priv->xfer_lock);
        return ret;
    }

    serdev_device_wait_until_sent(priv->serdev, priv->timeout_ms);

    if (!wait_for_completion_timeout(&priv->completion,
                                     msecs_to_jiffies(priv->timeout_ms))) {
        dev_err(&priv->serdev->dev,
                "aios_gpio: timeout waiting response for cmd=0x%02x off=%u\n",
                cmd, offset);
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

    mutex_unlock(&priv->xfer_lock);
    return 0;
}

static int aios_gpio_write_retry(struct aios_gpio_data *priv,
                                 const u8 *data, size_t len,
                                 int retry_max, unsigned int delay_ms)
{
    int ret, i;

    for (i = 0; i < retry_max; i++) {
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

    if (offset >= priv->ngpios)
        return -EINVAL;

    dev_info(&priv->serdev->dev, "get_direction: offset %u\n", offset);

    /*
     * 优先走缓存，避免 probe 完成后框架又立刻打一轮串口查询
     */
    dir = priv->gpio_directions[offset];
    if (dir == AIOS_PROTO_DIR_IN)
        return GPIO_LINE_DIRECTION_IN;
    if (dir == AIOS_PROTO_DIR_OUT)
        return GPIO_LINE_DIRECTION_OUT;

    ret = aios_gpio_write_retry(priv, cmd, sizeof(cmd),
                                AIOS_CMD_RETRY_MAX,
                                AIOS_RETRY_DELAY_MS);
    if (ret < 0)
        return ret;

    dir = priv->gpio_directions[offset];
    if (dir == AIOS_PROTO_DIR_IN)
        return GPIO_LINE_DIRECTION_IN;
    if (dir == AIOS_PROTO_DIR_OUT)
        return GPIO_LINE_DIRECTION_OUT;

    dev_warn(&priv->serdev->dev,
             "aios_gpio: unexpected direction value %u for GPIO%u\n",
             dir, offset);
    return -EIO;
}

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
    int ret, i;

    if (auto_baudrate) {
        serdev_device_write(priv->serdev, &sync, 1, priv->timeout_ms);
        serdev_device_wait_until_sent(priv->serdev, priv->timeout_ms);
        msleep(10);
    }

    ret = aios_gpio_write_retry(priv, init_cmd, sizeof(init_cmd),
                                AIOS_INIT_RETRY_MAX,
                                AIOS_RETRY_DELAY_MS);
    if (ret < 0) {
        pr_err("aios_gpio,Initialization: command failed: %d\n", ret);
        return ret;
    }

    msleep(AIOS_POST_INIT_DELAY_MS);

    for (i = 0; i < priv->ngpios; i++) {
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

static const struct serdev_device_ops aios_serdev_ops = {
    .receive_buf = aios_gpio_recv,
    .write_wakeup = serdev_device_write_wakeup,
};

static int aios_gpio_probe(struct serdev_device *serdev)
{
    struct device *dev = &serdev->dev;
    struct aios_gpio_data *priv;
    struct device_node *np = dev->of_node;
    u32 baudrate = 115200;
    bool auto_baudrate;
    int ret;

    dev_info(dev, "Starting AIOS GPIO probe\n");

    if (!serdev)
        return -EINVAL;

    priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
    if (!priv)
        return -ENOMEM;

    priv->serdev = serdev;
    serdev_device_set_drvdata(serdev, priv);

    /* 先挂 ops，再 open */
    serdev->ops = &aios_serdev_ops;

    ret = serdev_device_open(serdev);
    if (ret < 0) {
        dev_err(dev, "Failed to open serdev device: %d\n", ret);
        return ret;
    }
    dev_info(dev, "Serdev device opened successfully\n");

    of_property_read_u32(np, "current-speed", &baudrate);
    of_property_read_u32(np, "ngpios", &priv->ngpios);
    of_property_read_u32(np, "cmd-timeout", &priv->timeout_ms);
    auto_baudrate = of_property_read_bool(np, "auto-baudrate");

    if (!priv->timeout_ms)
        priv->timeout_ms = AIOS_DEFAULT_TIMEOUT_MS;

    if (!priv->ngpios || priv->ngpios > ARRAY_SIZE(priv->gpio_values)) {
        dev_err(dev, "Invalid ngpios=%u\n", priv->ngpios);
        ret = -EINVAL;
        goto err_close;
    }

    serdev_device_set_baudrate(serdev, baudrate);
    serdev_device_set_flow_control(serdev, false);
    serdev_device_set_parity(serdev, SERDEV_PARITY_NONE);

    dev_info(dev,
             "Serial device configured: %u baud, no flow control, no parity\n",
             baudrate);

    mutex_init(&priv->xfer_lock);
    init_completion(&priv->completion);
    init_waitqueue_head(&priv->waitq);

    priv->buffer_pos = 0;
    priv->rx_len = 0;
    priv->expected_cmd = 0;
    priv->expected_offset = 0;
    priv->expect_offset = false;
    priv->response_valid = false;

    memset(priv->packet_buffer, 0, sizeof(priv->packet_buffer));
    memset(priv->rx_buffer, 0, sizeof(priv->rx_buffer));
    memset(priv->gpio_values, 0, sizeof(priv->gpio_values));
    memset(priv->gpio_directions, 0, sizeof(priv->gpio_directions));

    msleep(AIOS_INIT_DELAY_MS);

    priv->gpio_chip.label = "aios-gpio";
    priv->gpio_chip.parent = dev;
    priv->gpio_chip.owner = THIS_MODULE;
    priv->gpio_chip.base = -1;
    priv->gpio_chip.ngpio = priv->ngpios;
    priv->gpio_chip.get_direction = aios_gpio_query_direction;
    priv->gpio_chip.direction_input = aios_gpio_gpio_direction_input;
    priv->gpio_chip.direction_output = aios_gpio_gpio_direction_output;
    priv->gpio_chip.get = aios_gpio_gpio_get_value;
    priv->gpio_chip.set = aios_gpio_gpio_set_value;
    priv->gpio_chip.set_config = aios_gpio_gpio_set_config;
    priv->gpio_chip.can_sleep = true;

    ret = aios_init(priv, auto_baudrate);
    if (ret < 0) {
        dev_err(dev, "Failed to initialize AIOS GPIO device: %d\n", ret);
        goto err_close;
    }

    ret = devm_gpiochip_add_data(dev, &priv->gpio_chip, priv);
    if (ret < 0) {
        dev_err(dev, "Failed to register GPIO chip: %d\n", ret);
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
    u8 shutdown_cmd[] = { 0x53, 0x49, 0x00, 0x0D, 0x0A };

    if (priv && priv->ngpios > 0) {
        serdev_device_write_buf(serdev, shutdown_cmd, sizeof(shutdown_cmd));
        serdev_device_wait_until_sent(serdev, 0);
    }

    serdev_device_close(serdev);
    if (priv)
        priv->serdev = NULL;
}

static const struct of_device_id aios_gpio_of_match[] = {
    { .compatible = "aios,gpio" },
    { }
};
MODULE_DEVICE_TABLE(of, aios_gpio_of_match);

static struct serdev_device_driver aios_gpio_driver = {
    .driver = {
        .name = "aios-gpio",
        .of_match_table = aios_gpio_of_match,
    },
    .probe = aios_gpio_probe,
    .remove = aios_gpio_remove,
};

module_serdev_device_driver(aios_gpio_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("AIOS UART protocol GPIO expander");
MODULE_AUTHOR("Igotu.Qiu <qiupeiqin@cs-t.cn>");