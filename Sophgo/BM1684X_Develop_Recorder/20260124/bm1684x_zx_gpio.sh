#!/bin/bash
set -e

# 兼容不同内核/驱动版本暴露出的 label 差异：
# 有的版本显示为 aios-gpio，有的版本显示为 I2C 设备地址 1-006c。
GPIODETECT_OUTPUT=$(gpiodetect)
CHIP_NAME=$(printf '%s\n' "$GPIODETECT_OUTPUT" | awk '
  /aios-gpio/ {print $1; found=1; exit}
  /\[1-006c\]/ {fallback=$1}
  END {
    if (!found && fallback != "") {
      print fallback
    }
  }
')

if [ -z "$CHIP_NAME" ]; then
  echo "ERROR: target gpiochip not found in gpiodetect output."
  echo "Expected labels: aios-gpio or [1-006c]"
  printf '%s\n' "$GPIODETECT_OUTPUT"
  exit 1
fi

# gpiodetect 输出是 gpiochip3 这种，提取数字 3
GPIOCHIP=${CHIP_NAME#gpiochip}

echo "Using GPIOCHIP=$GPIOCHIP ($CHIP_NAME)"

# root 下跑不需要 sudo，但保留也不影响；这里去掉 sudo 更干净
gpioset ${GPIOCHIP} 10=1

gpioset ${GPIOCHIP} 3=0 4=0 5=0
gpioget ${GPIOCHIP} 0 1 2

gpioset ${GPIOCHIP} 3=0 4=0 5=1
gpioget ${GPIOCHIP} 0 1 2

gpioset ${GPIOCHIP} 3=0 4=1 5=0
gpioget ${GPIOCHIP} 0 1 2

gpioset ${GPIOCHIP} 3=0 4=1 5=1
gpioget ${GPIOCHIP} 0 1 2

gpioset ${GPIOCHIP} 3=1 4=0 5=0
gpioget ${GPIOCHIP} 0 1 2

gpioset ${GPIOCHIP} 3=1 4=0 5=1
gpioget ${GPIOCHIP} 0 1 2

gpioset ${GPIOCHIP} 3=1 4=1 5=0
gpioget ${GPIOCHIP} 0 1 2

gpioset ${GPIOCHIP} 3=1 4=1 5=1
gpioget ${GPIOCHIP} 0 1 2
