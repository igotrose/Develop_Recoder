#ifndef _AIOS_GPIO_H
#define _AIOS_GPIO_H

#include <linux/gpio/consumer.h>
#include <linux/serdev.h>
#include <linux/mutex.h>

#define AIOS_CMD_START         0x53  // 'S'
#define AIOS_CMD_DIRECTION_QUERY    0x44  // 'D'
#define AIOS_CMD_CONFIG             0x43  // 'C'
#define AIOS_CMD_OUTPUT              0x4F  // 'W'
#define AIOS_CMD_READ               0x52  // 'R'
#define AIOS_CMD_INIT               0x69  // 'i'
//#define AIOS_CMD_END                (0x0D, 0x0A)  // CR LF

#define GPIO_LINE_DIRECTION_IN 1
#define GPIO_LINE_DIRECTION_OUT 0

struct aios_gpio_data {
    struct serdev_device *serdev;
    struct gpio_chip gpio_chip;
    struct completion completion;
    wait_queue_head_t waitq;
    struct mutex lock;
    u32 timeout_ms;
    u32 ngpios;


    u8 gpio_values[16];
    u8 gpio_directions[16];

    u8 rx_buffer[64];        // 接收缓冲区
    int rx_len;              // 接收数据长度
    u8 frame_buffer[64];
    size_t frame_len;

    // ... 其他字段
};

#endif // _AIOS_GPIO_H
