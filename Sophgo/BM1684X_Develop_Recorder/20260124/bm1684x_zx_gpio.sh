#!/bin/bash
set -e

# 自动找到 aios-gpio 对应的 gpiochip 编号（不再依赖 bm_version）
CHIP_NAME=$(gpiodetect | awk '/aios-gpio/ {print $1; exit}')
if [ -z "$CHIP_NAME" ]; then
  echo "ERROR: aios-gpio not found in gpiodetect output:"
  gpiodetect
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