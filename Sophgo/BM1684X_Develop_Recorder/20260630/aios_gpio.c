// gpio-aios.c - AIOS UART protocol GPIO expander driver

#include <linux/module.h>
#include <linux/serdev.h>
#include <linux/gpio/driver.h>
#include <linux/of.h>
#include <linux/completion.h>
#include <linux/wait.h>
#include <linux/serial.h> 
#include <linux/delay.h>



#include "aios_gpio.h"

#define AIOS_DEFAULT_TIMEOUT_MS 500
#define AIOS_INIT_TIMEOUT_MS    1000
#define AIOS_INIT_RETRIES       5
#define AIOS_FALLBACK_BAUDRATE  9600

#define AIOS_FW_DIR_UNKNOWN     0
#define AIOS_FW_DIR_INPUT       1
#define AIOS_FW_DIR_OUTPUT      2

static void aios_gpio_handle_frame(struct aios_gpio_data *priv,
                                   const u8 *frame, size_t frame_len)
{
    u8 cmd = frame[1];
    u8 data_len = frame[2];
    u8 offset, value, direction;

    memcpy(priv->rx_buffer, frame, frame_len);
    priv->rx_len = frame_len;

    dev_info(&priv->serdev->dev, "complete frame: cmd=%c len=%u\n",
             cmd, data_len);
    print_hex_dump(KERN_INFO, "aios_gpio frame: ", DUMP_PREFIX_OFFSET,
                   16, 1, frame, frame_len, true);

    switch (cmd) {
    case 0x44: // 'D' - 方向查询响应
        if (data_len == 2) {
            offset = priv->rx_buffer[3];
            direction = priv->rx_buffer[4];
            if (offset < priv->ngpios)
                priv->gpio_directions[offset] = direction;
        }
        break;
    case 0x43: // 'C' - 配置响应
        break;
    case 0x52: // 'R' - 读取值响应
        if (data_len == 2) {
            offset = priv->rx_buffer[3];
            value = priv->rx_buffer[4];
            if (offset < priv->ngpios)
                priv->gpio_values[offset] = value;
        }
        break;
    case 0x4F: // 'O' - 输出响应
        if (data_len == 2) {
            offset = priv->rx_buffer[3];
            value = priv->rx_buffer[4];
            if (offset < priv->ngpios)
                priv->gpio_values[offset] = value;
        }
        break;
    case 0x69: // 'i' - 初始化响应
        break;
    default:
        dev_warn(&priv->serdev->dev, "unknown command response: 0x%02x\n",
                 cmd);
        break;
    }

    complete(&priv->completion);
}

static int aios_gpio_fw_direction_to_gpio(u8 direction)
{
    switch (direction) {
    case AIOS_FW_DIR_INPUT:
        return GPIO_LINE_DIRECTION_IN;
    case AIOS_FW_DIR_OUTPUT:
        return GPIO_LINE_DIRECTION_OUT;
    default:
        return -EIO;
    }
}

// 接收数据处理函数

// 优化后的接收数据处理函数
static int aios_gpio_recv(struct serdev_device *serdev, 
                         const u8 *data, size_t count)
{
    struct aios_gpio_data *priv = serdev_device_get_drvdata(serdev);
    size_t copy, frame_len;
    int i, frame_start;

    if (!priv || !count) 
        return 0;
        
    dev_info(&serdev->dev, "received %zu bytes\n", count);
    print_hex_dump(KERN_INFO, "aios_gpio rx: ", DUMP_PREFIX_OFFSET,
                   16, 1, data, count, true);

    copy = min(count, sizeof(priv->frame_buffer) - priv->frame_len);
    memcpy(priv->frame_buffer + priv->frame_len, data, copy);
    priv->frame_len += copy;
    if (copy < count) {
        dev_warn(&serdev->dev, "rx buffer overflow, dropping buffered data\n");
        priv->frame_len = 0;
        return count;
    }

    while (priv->frame_len >= 5) {
        frame_start = -1;
        for (i = 0; i < priv->frame_len; i++) {
            if (priv->frame_buffer[i] == AIOS_CMD_START) {
                frame_start = i;
                break;
            }
        }

        if (frame_start < 0) {
            print_hex_dump(KERN_WARNING, "aios_gpio rx drop: ",
                           DUMP_PREFIX_OFFSET, 16, 1,
                           priv->frame_buffer, priv->frame_len, true);
            priv->frame_len = 0;
            break;
        }

        if (frame_start > 0) {
            memmove(priv->frame_buffer, priv->frame_buffer + frame_start,
                    priv->frame_len - frame_start);
            priv->frame_len -= frame_start;
        }

        if (priv->frame_len < 5)
            break;

        frame_len = priv->frame_buffer[2] + 5;
        if (frame_len > sizeof(priv->frame_buffer)) {
            dev_warn(&serdev->dev, "invalid frame length: %zu\n", frame_len);
            priv->frame_len = 0;
            break;
        }

        if (priv->frame_len < frame_len)
            break;

        if (priv->frame_buffer[frame_len - 2] != 0x0D ||
            priv->frame_buffer[frame_len - 1] != 0x0A) {
            print_hex_dump(KERN_WARNING, "aios_gpio malformed frame: ",
                           DUMP_PREFIX_OFFSET, 16, 1,
                           priv->frame_buffer, priv->frame_len, true);
            memmove(priv->frame_buffer, priv->frame_buffer + 1,
                    priv->frame_len - 1);
            priv->frame_len--;
            continue;
        }

        aios_gpio_handle_frame(priv, priv->frame_buffer, frame_len);

        memmove(priv->frame_buffer, priv->frame_buffer + frame_len,
                priv->frame_len - frame_len);
        priv->frame_len -= frame_len;
    }

    return count;
}


/*
static int aios_gpio_recv(struct serdev_device *serdev, 
                         const u8 *data, size_t count)
{
    struct aios_gpio_data *priv = serdev_device_get_drvdata(serdev);
    int i;
    u8 payload_len ;
    if (!count) 
        return 0;
        
    // 查找命令起始标志 'S' (0x53)
    for (i = 0; i < count; i++) {
        if (data[i] == AIOS_CMD_START) {
            return i;  // 返回命令起始位置
        }
    }
    
    // 处理完整命令包
    if (count >= 5 && data[0] == AIOS_CMD_START) {
        payload_len = data[2];
        
        if (count >= payload_len + 3) {
            // 拷贝接收数据到缓冲区
            memcpy(priv->rx_buffer, data, payload_len + 3);
            
            // 更新GPIO状态
            // 这里会根据命令类型更新gpio_values和gpio_directions
            
            // 完成等待
            complete(&priv->completion);
            return payload_len + 3;
        }
    }
    
    return 0;
}
*/

// 发送数据到AIOS设备
static int aios_gpio_write_timeout(struct aios_gpio_data *priv, const u8 *data,
                                  size_t len, u32 timeout_ms)
{
    int ret;
    long timeout;

    if (!priv || !priv->serdev) {
        printk(KERN_ERR "aios_gpio: priv or serdev is NULL\n");
        return -ENODEV;
    }

    if (!timeout_ms)
        timeout_ms = AIOS_DEFAULT_TIMEOUT_MS;
    timeout = msecs_to_jiffies(timeout_ms);
    if (!timeout)
        timeout = 1;

    mutex_lock(&priv->lock);
    
    // 重置完成量
    reinit_completion(&priv->completion);
    priv->frame_len = 0;

    // 发送数据
    ret = serdev_device_write(priv->serdev, data, len, timeout);
    if (ret < 0){
        printk(KERN_ERR "aios_gpio: write failed: %d\n", ret);
        goto out_unlock;
    }
    if (ret != len) {
        printk(KERN_ERR "aios_gpio: short write: %d/%zu\n", ret, len);
        ret = -EIO;
        goto out_unlock;
    }
        
    // 等待发送完成
    serdev_device_wait_until_sent(priv->serdev, timeout);
        
    // 等待响应超时
    if (!wait_for_completion_timeout(&priv->completion, 
                                    timeout)) {
        ret = -ETIMEDOUT;
        goto out_unlock;
    }

    ret = 0;

out_unlock:
    mutex_unlock(&priv->lock);
    return ret;
}

static int aios_gpio_write(struct aios_gpio_data *priv, const u8 *data, size_t len)
{
    return aios_gpio_write_timeout(priv, data, len, priv->timeout_ms);
}

// 查询GPIO方向   AIOS_CMD_DIRECTION_QUERY
static int aios_gpio_query_direction(struct gpio_chip *chip, unsigned offset)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    int ret;
    u8 cmd[] = {
        AIOS_CMD_START,         // 0x53
        AIOS_CMD_DIRECTION_QUERY ,  // 'D' - 查询方向
        0x01,                       // 数据长度
        offset,                     // GPIO偏移
        0x0D, 0x0A                // 结束标志
    };
    
    dev_info(&priv->serdev->dev, "get_direction: offset %d\n", offset);

    if (offset >= priv->ngpios)
        return -EINVAL;

    ret = aios_gpio_write(priv, cmd, sizeof(cmd));
    if (ret < 0)
        return ret;

    return aios_gpio_fw_direction_to_gpio(priv->gpio_directions[offset]);
}

// GPIO设置配置   AIOS_CMD_CONFIG
static int aios_gpio_gpio_set_config(struct gpio_chip *chip,
                                    unsigned offset, unsigned long config)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    int ret;
    u8 cmd[] = {
        AIOS_CMD_START,       // 起始标志
        AIOS_CMD_CONFIG,      // 配置命令
        0x02,                 // 数据长度
        offset,               // GPIO偏移
        AIOS_FW_DIR_OUTPUT,   // 配置参数
        0x0D, 0x0A          // 结束标志
    };
    
    dev_info(&priv->serdev->dev,"set_config : offset %d\n param %d \n" , offset,pinconf_to_config_param(config));

    if (offset >= priv->ngpios)
        return -EINVAL;

    // 处理支持的配置参数
    switch(pinconf_to_config_param(config)) {
        case PIN_CONFIG_PERSIST_STATE:
             return 0;
        case PIN_CONFIG_OUTPUT:
            cmd[4] = AIOS_FW_DIR_OUTPUT;
            break;
        case PIN_CONFIG_INPUT_ENABLE:
            cmd[4] = AIOS_FW_DIR_INPUT;
            break;
        case PIN_CONFIG_DRIVE_PUSH_PULL:
            return 0;
        default:
            dev_err(&priv->serdev->dev,"Unsupported config param: %u\n", 
                    pinconf_to_config_param(config));
            return -ENOTSUPP;
    }

    ret = aios_gpio_write(priv, cmd, sizeof(cmd));
    if (ret < 0)
        return ret;

    priv->gpio_directions[offset] = cmd[4];
    return 0;
}




// 设置GPIO值  AIOS_CMD_OUTPUT
static void aios_gpio_gpio_set_value(struct gpio_chip *chip,
                                   unsigned offset, int value)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    u8 cmd[] = {
        AIOS_CMD_START,
        AIOS_CMD_OUTPUT,    // 设置值命令
        0x02,               // 数据长度
        offset,             // GPIO偏移
        value,              // 设置的值
        0x0D, 0x0A
    };
    int ret;
    dev_info(&priv->serdev->dev,"set_value : offset %d  value %d \n", offset,value);

    ret = aios_gpio_write(priv, cmd, sizeof(cmd));
    if (ret < 0) {
        dev_err(chip->parent, "Failed to set GPIO value\n");
        return ;
    }
    // 如果成功 更新缓存值
    if (offset < priv->ngpios) {
        priv->gpio_values[offset] = value ? 0x01 : 0x00;
    }
}

// 获取GPIO值
static int aios_gpio_gpio_get_value(struct gpio_chip *chip,
                                   unsigned offset)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    u8 cmd[] = {
        AIOS_CMD_START,
        AIOS_CMD_READ,  // 获取值命令    
        0x01,           // 数据长度
        offset,          // GPIO偏移
        0x0D, 0x0A
    };  
    int ret ;

    // 检查偏移是否有效
    if (offset >= priv->ngpios)
        return -EINVAL;

    dev_info(&priv->serdev->dev,"get_value : offset %d \n", offset);

    ret = aios_gpio_write(priv, cmd, sizeof(cmd));
    if (ret < 0)
        return ret;

    // 返回GPIO值
    return priv->gpio_values[offset] ? 1 : 0;
}

// 设置GPIO为输出  AIOS_CMD_CONFIG
static int aios_gpio_gpio_direction_output(struct gpio_chip *chip,
                                          unsigned offset, int value)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    int ret;
    u8 cmd[] = {
        AIOS_CMD_START,
        AIOS_CMD_CONFIG,    // 配置命令
        0x02,               // 数据长度
        offset,
        0x02,               // 方向: 输出
        0x0D, 0x0A
    };
    
    dev_info(&priv->serdev->dev,"set_output : offset %d\n", offset);
    ret = aios_gpio_write(priv, cmd, sizeof(cmd));
    if (ret < 0)
        return ret;

    if (offset < priv->ngpios)
        priv->gpio_directions[offset] = AIOS_FW_DIR_OUTPUT;

    aios_gpio_gpio_set_value(chip, offset, value);
    return 0;
}

// 设置GPIO为输入  AIOS_CMD_CONFIG
static int aios_gpio_gpio_direction_input(struct gpio_chip *chip,
                                         unsigned offset)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    int ret;
    u8 cmd[] = {
        AIOS_CMD_START,
        AIOS_CMD_CONFIG,    // 配置命令
        0x02,               // 数据长度
        offset,
        0x01,                // 方向: 输入
        0x0D, 0x0A
    }; 
    dev_info(&priv->serdev->dev,"set_input : offset %d\n", offset);
    ret = aios_gpio_write(priv, cmd, sizeof(cmd));
    if (ret < 0)
        return ret;

    if (offset < priv->ngpios)
        priv->gpio_directions[offset] = AIOS_FW_DIR_INPUT;

    return 0;
}


static int aios_init(struct aios_gpio_data *priv)
{
    u8 init_cmd[] = {
        0x55,
        AIOS_CMD_START,  // 0x53
        AIOS_CMD_INIT,   // 'i' - 初始化
        0x00,
        0x0D, 0x0A       // CR  // LF            
    };
    u8 init_dir_cmd[] = {
        AIOS_CMD_START,              // 0x53
        AIOS_CMD_DIRECTION_QUERY,    // 'D' - 查询方向
        0x01,                        // 数据长度
        0x00,                        // GPIO偏移
        0x0D, 0x0A                   // 结束标志
    };
    int ret,i;
    u32 init_timeout = priv->timeout_ms;

    if (init_timeout < AIOS_INIT_TIMEOUT_MS)
        init_timeout = AIOS_INIT_TIMEOUT_MS;

    for (i = 0; i < AIOS_INIT_RETRIES; i++) {
        ret = aios_gpio_write_timeout(priv, init_cmd, sizeof(init_cmd),
                                      init_timeout);
        if (!ret)
            break;

        printk(KERN_WARNING "aios_gpio,Initialization: command retry %d/%d failed: %d\n",
               i + 1, AIOS_INIT_RETRIES, ret);
        msleep(200);
    }
    if (ret < 0) {
        printk(KERN_ERR "aios_gpio,Initialization:  command failed: %d\n", ret);
        return ret;
    }

    for(i=0;i<priv->ngpios;i++)
    {
        init_dir_cmd[3] = i;
        ret = aios_gpio_write(priv, init_dir_cmd, sizeof(init_dir_cmd));
        if (ret < 0) {
            printk(KERN_ERR "aios_gpio,Initialization: Failed to query direction for GPIO %d: %d\n", i, ret);
            return ret;
        }
    }
    return 0;
}

// 串行设备操作
static const struct serdev_device_ops aios_serdev_ops = {
    .receive_buf = aios_gpio_recv,
    .write_wakeup = serdev_device_write_wakeup,
};
// 探测函数 - 主要初始化
static int aios_gpio_probe(struct serdev_device *serdev)
{
    struct device *dev = &serdev->dev;
    struct aios_gpio_data *priv;
    struct device_node *np = dev->of_node;
    u32 baudrate = 115200;
    int ret;
    
    dev_info(dev, "Starting AIOS GPIO probe\n");

    // 检查serdev设备是否有效
    if (!serdev) {
        dev_err(dev, "Serdev device is NULL\n");
        return -EINVAL;
    }

    // 分配私有数据结构
    priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
    if (!priv)
        return -ENOMEM;
    
    priv->serdev = serdev;
    serdev_device_set_drvdata(serdev, priv);
    
    // 从设备树读取配置
    of_property_read_u32(np, "current-speed", &baudrate);
    of_property_read_u32(np, "ngpios", &priv->ngpios);
    of_property_read_u32(np, "cmd-timeout", &priv->timeout_ms);

    if (!priv->timeout_ms)
        priv->timeout_ms = AIOS_DEFAULT_TIMEOUT_MS;
    if (!priv->ngpios || priv->ngpios > ARRAY_SIZE(priv->gpio_values)) {
        dev_err(dev, "Invalid ngpios: %d\n", priv->ngpios);
        return -EINVAL;
    }
    dev_info(dev, "AIOS GPIO config: baudrate=%u timeout=%u ngpios=%u\n",
             baudrate, priv->timeout_ms, priv->ngpios);

    // 初始化完成量和等待队列
    init_completion(&priv->completion);
    init_waitqueue_head(&priv->waitq);
    mutex_init(&priv->lock);
    serdev_device_set_client_ops(serdev, &aios_serdev_ops);

    // 打开串行设备
    ret = serdev_device_open(serdev);
    if (ret < 0) {
        dev_err(dev, "Failed to open serdev device:%d\n",ret);
        return ret;
    }
    dev_info(dev, "Serdev device opened successfully\n");
    

    // 配置串行设备
    serdev_device_set_baudrate(serdev, baudrate);
    serdev_device_set_flow_control(serdev, false);
    serdev_device_set_parity(serdev, SERDEV_PARITY_NONE);
    dev_info(dev, "Serial device configured: %d baud, no flow control, no parity\n", baudrate);
    
    // 设置接收回调
   // serdev_device_set_receive_buf(serdev, aios_gpio_recv);
    /*   if (!serdev->ops) {
        dev_err(dev, "Serdev device has no operations\n");
        ret = -ENODEV;
        goto err_close;
    }
    if (!serdev->ops->write_buf && !serdev->ops->write) {
        dev_err(dev, "Serdev device missing write operations\n");
        ret = -ENODEV;
        goto err_close;
    }
    */
    // 配置GPIO芯片
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
  

    ret = aios_init(priv);
    if (ret < 0 && baudrate != AIOS_FALLBACK_BAUDRATE) {
        dev_warn(dev, "AIOS init failed at %u baud: %d, retrying at %u baud\n",
                 baudrate, ret, AIOS_FALLBACK_BAUDRATE);
        serdev_device_set_baudrate(serdev, AIOS_FALLBACK_BAUDRATE);
        msleep(200);
        ret = aios_init(priv);
    }
    if (ret < 0) {
        dev_err(dev, "Failed to initialize AIOS GPIO device: %d\n", ret);
        goto err_close;
    }   

/*
    // 发送初始化命令
    ret = aios_gpio_write(priv, init_cmd, sizeof(init_cmd));
    if (ret < 0) {
        dev_err(dev, "Initialization command failed: %d\n", ret);
        goto err_close;
    }
*/ 

    // 注册GPIO芯片
    ret = devm_gpiochip_add_data(dev, &priv->gpio_chip, priv);
    if (ret < 0) {
        dev_err(dev, "Failed to register GPIO chip: %d\n", ret);
        goto err_close;
    }
    
    dev_info(dev, "AIOS GPIO expander probed, %d GPIOs\n", priv->ngpios);
    return 0;
    
err_close:
    serdev_device_close(serdev);
    return ret;
}

// 移除函数
static void aios_gpio_remove(struct serdev_device *serdev)
{
    struct aios_gpio_data *priv = serdev_device_get_drvdata(serdev);
    u8 shutdown_cmd[] = {0x53, 0x49, 0x0D, 0x0A}; // 关闭命令
    
    if (priv->ngpios > 0) {
        // 发送关闭命令
        serdev_device_write_buf(serdev, shutdown_cmd, sizeof(shutdown_cmd));
        serdev_device_wait_until_sent(serdev, 0);
    }
    
    serdev_device_close(serdev);
    priv->serdev = NULL;
}



// 设备ID表
static const struct of_device_id aios_gpio_of_match[] = {
    { .compatible = "aios,gpio" },
    {}
};
MODULE_DEVICE_TABLE(of, aios_gpio_of_match);

// 串行设备驱动
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
MODULE_AUTHOR("Leslie ling <qiupeiqin@cs-t.cn>");
