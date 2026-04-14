// gpio-aios.c - AIOS UART protocol GPIO expander driver

#include <linux/module.h>
#include <linux/serdev.h>
#include <linux/gpio/driver.h>
#include <linux/of.h>
#include <linux/completion.h>
#include <linux/wait.h>
#include <linux/serial.h> 



#include "aios_gpio.h"

// 接收数据处理函数

// 优化后的接收数据处理函数
static int aios_gpio_recv(struct serdev_device *serdev, 
                         const u8 *data, size_t count)
{
    struct aios_gpio_data *priv = serdev_device_get_drvdata(serdev);
    static u8 packet_buffer[64];
    static size_t buffer_pos = 0;
    int i, processed = 0;
    int frame_start,j,k;
    u8 offset, value, direction;
    
    if (!priv || !count) 
        return 0;
        
    printk(KERN_DEBUG "aios_gpio: received %zu bytes\n", count);
    
    // 将新数据添加到缓冲区
    for (i = 0; i < count && buffer_pos < sizeof(packet_buffer) - 1; i++) {
        packet_buffer[buffer_pos++] = data[i];
        
        // 检查是否收到完整帧 (以 0x0D 0x0A 结尾)
        if (buffer_pos >= 2 && 
            packet_buffer[buffer_pos-2] == 0x0D && 
            packet_buffer[buffer_pos-1] == 0x0A) {
            
            // 找到完整帧，查找帧起始 (0x53)
            frame_start = -1;

            for (j = 0; j < buffer_pos; j++) {
                if (packet_buffer[j] == AIOS_CMD_START) {
                    frame_start = j;
                    break;
                }
            }
            
            if (frame_start >= 0) {
                // 计算帧长度
                int frame_len = buffer_pos - frame_start;
                
                // 确保是有效的帧 (至少有5个字节: 53 CMD LEN DATA... 0D 0A)
                if (frame_len >= 5) {
                    u8 cmd = packet_buffer[frame_start + 1];
                    u8 data_len = packet_buffer[frame_start + 2];
                    
                    // 验证帧长度是否匹配
                    if (frame_len == data_len + 5) { // 53 + CMD + LEN + data_len + 0D0A
                        
                        // 复制完整帧到私有缓冲区
                        memcpy(priv->rx_buffer, &packet_buffer[frame_start], frame_len);
                        priv->rx_len = frame_len;
                        
                        printk(KERN_DEBUG "aios_gpio: complete frame: cmd=%c, len=%d data:\n", 
                               (char)cmd, data_len);
                        
                        for(k=0;k<frame_len;k++)
                        printk(KERN_DEBUG "aios_gpio: 0x%02x\n",priv->rx_buffer[k]);

                        // 根据命令类型处理响应
                        switch (cmd) {
                            case 0x44: // 'D' - 方向查询响应
                                if (data_len == 2) {
                                    offset = priv->rx_buffer[3];
                                    direction = priv->rx_buffer[4];
                                    if (offset < priv->ngpios) {
                                        priv->gpio_directions[offset] = direction;
                                        printk(KERN_DEBUG "aios_gpio: offset = %d direction = %d\n", 
                                               offset, direction);
                                    }
                                }
                                break;
                                
                            case 0x43: // 'C' - 配置响应
                                // 配置命令的响应通常是确认，不需要特殊处理
                                printk(KERN_DEBUG "aios_gpio: config response received\n");
                                break;
                                
                            case 0x52: // 'R' - 读取值响应
                                if (data_len == 2) {
                                    offset = priv->rx_buffer[3];
                                    value = priv->rx_buffer[4];
                                    if (offset < priv->ngpios) {
                                        priv->gpio_values[offset] = value;
                                        printk(KERN_DEBUG "aios_gpio: offset%d value = %d\n", 
                                               offset, value);
                                    }
                                }
                                break;
                                
                            case 0x4F: // 'O' - 输出响应
                                if (data_len == 2) {
                                    offset = priv->rx_buffer[3];
                                    value = priv->rx_buffer[4];
                                    if (offset < priv->ngpios) {
                                        priv->gpio_values[offset] = value;
                                        printk(KERN_DEBUG "aios_gpio: GPIO%d set to %d\n", 
                                               offset, value);
                                    }
                                }
                                break;
                                
                            case 0x69: // 'i' - 初始化响应
                                printk(KERN_DEBUG "aios_gpio: init response received\n");
                                break;
                                
                            default:
                                printk(KERN_DEBUG "aios_gpio: unknown command response: 0x%02x\n", cmd);
                                break;
                        }
                        
                        // 完成等待 - 每收到一帧就完成一次等待
                        complete(&priv->completion);
                        
                        // 清空缓冲区，准备接收下一帧
                        buffer_pos = 0;
                        processed = i + 1; // 返回已处理的字节数
                        break;
                    }
                }
            }
            
            // 如果没有找到有效帧起始，清空缓冲区（可能是垃圾数据）
            if (frame_start < 0) {
                printk(KERN_DEBUG "aios_gpio: invalid frame, clearing buffer\n");
                buffer_pos = 0;
            }
        }
    }
    
    // 如果缓冲区已满但未找到完整帧，清空缓冲区
    if (buffer_pos >= sizeof(packet_buffer) - 1) {
        printk(KERN_WARNING "aios_gpio: buffer full, clearing\n");
        buffer_pos = 0;
    }
    
    return processed > 0 ? processed : count; // 返回处理的字节数
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
static int aios_gpio_write(struct aios_gpio_data *priv, const u8 *data, size_t len)
{
    int ret;

    if (!priv || !priv->serdev) {
        printk(KERN_ERR "aios_gpio: priv or serdev is NULL\n");
        return -ENODEV;
    }
    
    // 重置完成量
    reinit_completion(&priv->completion);

    // 发送数据
    ret = serdev_device_write(priv->serdev, data, len, priv->timeout_ms);
    if (ret < 0){
        printk(KERN_ERR "aios_gpio: write failed: %d\n", ret);
        return ret;
    }
        
    // 等待发送完成
    serdev_device_wait_until_sent(priv->serdev, priv->timeout_ms);
        
    // 等待响应超时
    if (!wait_for_completion_timeout(&priv->completion, 
                                    msecs_to_jiffies(priv->timeout_ms))) {
        return -ETIMEDOUT;
    }

    return 0;
}

// 查询GPIO方向   AIOS_CMD_DIRECTION_QUERY
static int aios_gpio_query_direction(struct gpio_chip *chip, unsigned offset)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    u8 cmd[] = {
        AIOS_CMD_START,         // 0x53
        AIOS_CMD_DIRECTION_QUERY ,  // 'D' - 查询方向
        0x01,                       // 数据长度
        offset,                     // GPIO偏移
        0x0D, 0x0A                // 结束标志
    };
    
    dev_info(&priv->serdev->dev, "get_direction: offset %d\n", offset);

    return aios_gpio_write(priv, cmd, sizeof(cmd));
}

// GPIO设置配置   AIOS_CMD_CONFIG
static int aios_gpio_gpio_set_config(struct gpio_chip *chip,
                                    unsigned offset, unsigned long config)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    u8 cmd[] = {
        AIOS_CMD_START,       // 起始标志
        AIOS_CMD_CONFIG,      // 配置命令
        0x03,                 // 数据长度
        offset,               // GPIO偏移
        0x02,                 // 配置参数     
        0x03,                 // 配置参数 
        0x0D, 0x0A          // 结束标志
    };
    
    dev_info(&priv->serdev->dev,"set_config : offset %d\n param %d \n" , offset,pinconf_to_config_param(config));

    // 处理支持的配置参数
    switch(pinconf_to_config_param(config)) {
        case PIN_CONFIG_PERSIST_STATE:
             return 0;
        case PIN_CONFIG_OUTPUT:  // 添加对输出配置的支持
        case PIN_CONFIG_INPUT_ENABLE:  // 添加对输入配置的支持
        case PIN_CONFIG_DRIVE_PUSH_PULL:
            return aios_gpio_write(priv, cmd, sizeof(cmd));
        default:
            dev_err(&priv->serdev->dev,"Unsupported config param: %u\n", 
                    pinconf_to_config_param(config));
            return -ENOTSUPP;
    }
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

    aios_gpio_gpio_set_value(chip, offset, value);
    return 0;
}

// 设置GPIO为输入  AIOS_CMD_CONFIG
static int aios_gpio_gpio_direction_input(struct gpio_chip *chip,
                                         unsigned offset)
{
    struct aios_gpio_data *priv = gpiochip_get_data(chip);
    u8 cmd[] = {
        AIOS_CMD_START,
        AIOS_CMD_CONFIG,    // 配置命令
        0x02,               // 数据长度
        offset,
        0x01,                // 方向: 输入
        0x0D, 0x0A
    }; 
    dev_info(&priv->serdev->dev,"set_input : offset %d\n", offset);
    return aios_gpio_write(priv, cmd, sizeof(cmd));
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
    ret = aios_gpio_write(priv, init_cmd, sizeof(init_cmd));
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
    
    // 打开串行设备
    ret = serdev_device_open(serdev);
    if (ret < 0) {
        dev_err(dev, "Failed to open serdev device:%d\n",ret);
        return ret;
    }
    dev_info(dev, "Serdev device opened successfully\n");
    
    // 从设备树读取配置
    of_property_read_u32(np, "current-speed", &baudrate);
    of_property_read_u32(np, "ngpios", &priv->ngpios);
    of_property_read_u32(np, "cmd-timeout", &priv->timeout_ms);
    

    // 配置串行设备
    serdev_device_set_baudrate(serdev, baudrate);
    serdev_device_set_flow_control(serdev, false);
    serdev_device_set_parity(serdev, SERDEV_PARITY_NONE);
    dev_info(dev, "Serial device configured: %d baud, no flow control, no parity\n", baudrate);
    
    // 初始化完成量和等待队列
    init_completion(&priv->completion);
    init_waitqueue_head(&priv->waitq);
    
    // 设置接收回调
   // serdev_device_set_receive_buf(serdev, aios_gpio_recv);
    serdev->ops = &aios_serdev_ops;
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
MODULE_AUTHOR("Leslie ling <lingzhixin@cs-t.cn>");