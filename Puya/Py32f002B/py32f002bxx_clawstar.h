#ifndef __PY32F002BXX_CLAWSTAR_H
#define __PY32F002BXX_CLAWSTAR_H

#ifdef __cplusplus
extern "C" {
#endif

#include "py32f0xx_hal.h"

/*
 * PB0：按键输入
 * 上拉输入：
 * 未按下 = 1
 * 按下   = 0
 */
#define KEY_PORT              GPIOB
#define KEY_PIN               GPIO_PIN_0
#define KEY_PRESSED_LEVEL     GPIO_PIN_SET

/*
 * PB1：系统电源控制
 * 长按 3 秒翻转
 */
#define SYS_PWR_CTRL_PORT     GPIOB
#define SYS_PWR_CTRL_PIN      GPIO_PIN_1

/*
 * PA6 / PA7：背光/外设控制
 * 短按翻转
 */
#define BL_PWR_CTRL_PORT      GPIOA
#define BL1_PWR_CTRL_PIN      GPIO_PIN_7
#define BL2_PWR_CTRL_PIN      GPIO_PIN_6
#define BL_PWR_CTRL_PINS      (BL1_PWR_CTRL_PIN | BL2_PWR_CTRL_PIN)

/*
 * 按键参数
 */
#define LONG_PRESS_TIME_MS    1500U
#define DEBOUNCE_TIME_MS      5U

typedef enum {
    KEY_IDLE = 0,
    KEY_DEBOUNCE,
    KEY_PRESSED,
    KEY_LONG_DONE
} key_state_t;

void ClawStar_GPIO_Init(void);
void ClawStar_Key_Task(void);

#ifdef __cplusplus
}
#endif

#endif
