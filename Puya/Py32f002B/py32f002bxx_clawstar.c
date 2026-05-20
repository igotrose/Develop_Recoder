#include "py32f002bxx_clawstar.h"

static key_state_t key_state = KEY_IDLE;

static uint32_t key_down_time = 0;
static uint32_t debounce_time = 0;

/*
 * PB1 默认高电平
 */
static uint8_t sys_pwr_state = 1;

/*
 * PA6 / PA7 默认低电平
 */
static uint8_t bl_state = 0;

/*
 * EXTI 中断标志
 * 中断里只置位，不做业务逻辑
 */
static volatile uint8_t key_irq_flag = 0;

void HAL_GPIO_EXTI_Callback(uint16_t GPIO_Pin)
{
    if (GPIO_Pin == KEY_PIN)
    {
        key_irq_flag = 1;
    }
}

void ClawStar_Key_Task(void)
{
    GPIO_PinState key_level;
    uint32_t now;

    now = HAL_GetTick();
    key_level = HAL_GPIO_ReadPin(KEY_PORT, KEY_PIN);

    switch (key_state)
    {
        case KEY_IDLE:
            /*
             * 只有按键产生过边沿中断，才开始处理
             */
            if (key_irq_flag)
            {
                key_irq_flag = 0;

                if (key_level == KEY_PRESSED_LEVEL)
                {
                    debounce_time = now;
                    key_state = KEY_DEBOUNCE;
                }
            }
            break;

        case KEY_DEBOUNCE:
            /*
             * 按下后消抖
             */
            if ((uint32_t)(now - debounce_time) >= DEBOUNCE_TIME_MS)
            {
                key_level = HAL_GPIO_ReadPin(KEY_PORT, KEY_PIN);

                if (key_level == KEY_PRESSED_LEVEL)
                {
                    key_down_time = now;
                    key_state = KEY_PRESSED;
                }
                else
                {
                    key_state = KEY_IDLE;
                }
            }
            break;

        case KEY_PRESSED:
            key_level = HAL_GPIO_ReadPin(KEY_PORT, KEY_PIN);

            if (key_level == KEY_PRESSED_LEVEL)
            {
                /*
                 * 长按 3 秒：
                 * 只翻转 PB1
                 */
                if ((uint32_t)(now - key_down_time) >= LONG_PRESS_TIME_MS)
                {
                    sys_pwr_state = !sys_pwr_state;

                    HAL_GPIO_WritePin(SYS_PWR_CTRL_PORT,
                                      SYS_PWR_CTRL_PIN,
                                      sys_pwr_state ? GPIO_PIN_SET : GPIO_PIN_RESET);

                    key_state = KEY_LONG_DONE;
                }
            }
            else
            {
                /*
                 * 松手，且未达到长按时间：
                 * 判断为短按，只翻转 PA6 / PA7
                 */
                bl_state = !bl_state;

                HAL_GPIO_WritePin(BL_PWR_CTRL_PORT,
                                  BL_PWR_CTRL_PINS,
                                  bl_state ? GPIO_PIN_SET : GPIO_PIN_RESET);

                key_state = KEY_IDLE;
            }
            break;

        case KEY_LONG_DONE:
            /*
             * 长按已经触发过，等待松手
             * 防止一直按住导致 PB1 重复翻转
             */
            key_level = HAL_GPIO_ReadPin(KEY_PORT, KEY_PIN);

            if (key_level != KEY_PRESSED_LEVEL)
            {
                key_state = KEY_IDLE;
            }
            break;

        default:
            key_state = KEY_IDLE;
            break;
    }
}

void ClawStar_GPIO_Init(void)
{
    GPIO_InitTypeDef GPIO_InitStruct = {0};

    __HAL_RCC_GPIOA_CLK_ENABLE();
    __HAL_RCC_GPIOB_CLK_ENABLE();
    __HAL_RCC_SYSCFG_CLK_ENABLE();

    /*
     * 先预置默认输出电平，再配置为输出 PB1 默认高 PA6 / PA7 默认低
     */
    HAL_GPIO_WritePin(SYS_PWR_CTRL_PORT, SYS_PWR_CTRL_PIN, GPIO_PIN_SET);
    HAL_GPIO_WritePin(BL_PWR_CTRL_PORT, BL_PWR_CTRL_PINS, GPIO_PIN_RESET);

    /*
     * PB0：按键输入，上拉，双边沿中断
     * 未按下 = 1
     * 按下   = 0
     */
    GPIO_InitStruct.Pin = KEY_PIN;
    GPIO_InitStruct.Mode = GPIO_MODE_IT_RISING_FALLING;
    GPIO_InitStruct.Pull = GPIO_PULLDOWN;
    HAL_GPIO_Init(KEY_PORT, &GPIO_InitStruct);

    /*
     * PB1：系统电源控制输出
     */
    GPIO_InitStruct.Pin = SYS_PWR_CTRL_PIN;
    GPIO_InitStruct.Mode = GPIO_MODE_OUTPUT_PP;
    GPIO_InitStruct.Pull = GPIO_NOPULL;
    GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_LOW;
    HAL_GPIO_Init(SYS_PWR_CTRL_PORT, &GPIO_InitStruct);

    /*
     * PA6 / PA7：背光/外设控制输出
     */
    GPIO_InitStruct.Pin = BL_PWR_CTRL_PINS;
    GPIO_InitStruct.Mode = GPIO_MODE_OUTPUT_PP;
    GPIO_InitStruct.Pull = GPIO_NOPULL;
    GPIO_InitStruct.Speed = GPIO_SPEED_FREQ_LOW;
    HAL_GPIO_Init(BL_PWR_CTRL_PORT, &GPIO_InitStruct);

    HAL_NVIC_EnableIRQ(EXTI0_1_IRQn);
    HAL_NVIC_SetPriority(EXTI0_1_IRQn, 0, 0);
}
