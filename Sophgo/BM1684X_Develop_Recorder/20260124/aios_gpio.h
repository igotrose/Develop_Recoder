#ifndef _AIOS_GPIO_H
#define _AIOS_GPIO_H

#include <linux/types.h>
#include <linux/gpio/consumer.h>
#include <linux/gpio/driver.h>
#include <linux/serdev.h>
#include <linux/completion.h>
#include <linux/mutex.h>
#include <linux/wait.h>
#include <linux/stddef.h>

/*
 * 帧格式
 *
 * struct aios_gpio_cmd {
 *     uint8_t start;    // 固定 0x53 = 'S'
 *     uint8_t cmd;      // 命令字
 *     uint8_t len;      // data 区长度
 *     uint8_t data[];   // 可变长数据
 *     // 发送前驱动自动在 data[len]、data[len+1] 处补 0x0D 0x0A
 * };
 *
 * 线上完整帧:
 * [start][cmd][len][data...][0x0D][0x0A]
 */

#define AIOS_CMD_START                  0x53  /* 'S' */
/* 下位机额外状态/错误帧：53 45 00 0D 0A */
#define AIOS_CMD_ERROR                  0x45  /* 'E' */

#define AIOS_CMD_DIRECTION_QUERY        0x44  /* 'D' */
#define AIOS_CMD_CONFIG                 0x43  /* 'C' */
#define AIOS_CMD_OUTPUT                 0x4F  /* 'O' */
#define AIOS_CMD_READ                   0x52  /* 'R' */
#define AIOS_CMD_INIT                   0x69  /* 'i' */

#define GPIO_LINE_DIRECTION_IN          1
#define GPIO_LINE_DIRECTION_OUT         2

#define AIOS_RX_BUF_SIZE                64
#define AIOS_GPIO_MAX_LINES             16
#define AIOS_DEFAULT_TIMEOUT_MS         500
#define AIOS_INIT_DELAY_MS              200
#define AIOS_POST_INIT_DELAY_MS         20

struct aios_gpio_data {
    struct serdev_device *serdev;
    struct gpio_chip gpio_chip;

    struct mutex xfer_lock;
    struct completion completion;
    wait_queue_head_t waitq;

    u32 timeout_ms;
    u32 ngpios;

    /* 最近一次完整响应帧 */
    u8 rx_buffer[AIOS_RX_BUF_SIZE];
    int rx_len;

    /* 流式接收拼帧缓冲 */
    u8 packet_buffer[AIOS_RX_BUF_SIZE];
    size_t buffer_pos;

    /* 当前事务期待的响应 */
    u8 expected_cmd;
    u8 expected_offset;
    bool expect_offset;
    bool response_valid;

    /* 缓存的 GPIO 状态 */
    u8 gpio_values[AIOS_GPIO_MAX_LINES];
    u8 gpio_directions[AIOS_GPIO_MAX_LINES];
};

#endif /* _AIOS_GPIO_H */