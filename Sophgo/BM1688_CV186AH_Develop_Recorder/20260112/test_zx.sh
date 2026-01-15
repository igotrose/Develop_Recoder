#!/bin/bash

# 打印
function print_notice()
{
  printf "\e[1;34;47m %s \e[0m\n" "$1"
}

function print_usage()
{
  printf "========>correct usage :\n"
  printf "./test_zx.sh init \n"
  printf "./test_zx.sh relay on|off \n"
  printf "./test_zx.sh 485 send [data] \n"
  printf "./test_zx.sh 485 recv \n"
  printf "./test_zx.sh 232 test \n"
  printf "./test_zx.sh gpio get \n"
  printf "./test_zx.sh gpio set OUT0|OUT1 0|1 \n"
}

# 初始化函数
function init_485() {
    cvi_pinmux -w UART1_TX/UART1_TX
    cvi_pinmux -w UART1_RX/UART1_RX

    stty -F /dev/ttyS1 115200 cs8 -cstopb -parenb -crtscts

    cvi_pinmux -w PCIE0_L0_WAKEUP_X/GPIO41
    echo 457 > /sys/class/gpio/export
    echo out > /sys/class/gpio/gpio457/direction
}

function init_232(){
    cvi_pinmux -w PWR_UART_TX/UART3_TX
    cvi_pinmux -w PWR_UART_RX/UART3_RX

    stty -F /dev/ttyS3 115200 cs8 -cstopb -parenb -crtscts -echo
}

function relay_init(){
    cvi_pinmux -w PAD_VIVO0_D13/GPIO131
    echo 355 > /sys/class/gpio/export
    echo out > /sys/class/gpio/gpio355/direction
}

function gpio_init(){
    # 配置 pinmux
    cvi_pinmux -w I2S0_SCLK/GPIO0
    cvi_pinmux -w I2S0_WSI/GPIO1
    cvi_pinmux -w I2S0_SDI0/GPIO2
    cvi_pinmux -w I2S0_SDI1/GPIO3
    # 导出 gpio
    echo 480 > /sys/class/gpio/export
    echo 481 > /sys/class/gpio/export
    echo 482 > /sys/class/gpio/export
    echo 483 > /sys/class/gpio/export
    # 设置方向
    echo out > /sys/class/gpio/gpio480/direction
    echo out > /sys/class/gpio/gpio481/direction
    echo in > /sys/class/gpio/gpio482/direction
    echo in > /sys/class/gpio/gpio483/direction
}

function canbus_init(){
    ip link set can0 up type can bitrate 250000
    ifconfig can0 up
}

function init() {
    print_notice "Initializing..."
    init_485
    print_notice "Init 485 complete."
    init_232
    print_notice "Init 232 complete."
    relay_init
    print_notice "Init relay complete."
    gpio_init
    print_notice "Init GPIO complete."
    canbus_init
    print_notice "Init CAN bus complete."
    print_notice "Initialization complete."
}

# 功能函数
function relay_on() {
    echo 1 > /sys/class/gpio/gpio355/value
}
function relay_off() {
    echo 0 > /sys/class/gpio/gpio355/value
}

function send_485() {
    echo 1 > /sys/class/gpio/gpio457/value
    echo -n "$1" > /dev/ttyS1
    sleep 0.01
    echo 0 > /sys/class/gpio/gpio457/value
}
function recv_485() {
    echo 0 > /sys/class/gpio/gpio457/value
    while read -r line; do
    echo "[$(date '+%H:%M:%S') 485-RECV] $line"
    done < /dev/ttyS1
}

function test_232() {
    local serial_port="/dev/ttyS3"
    # 创建命名管道用于处理接收到的数据
#    local fifo_path=$(mktemp -u)
#    mkfifo "$fifo_path"

    # 启动后台进程接收数据并添加时间戳
    while read -r line; do
    echo "[$(date '+%H:%M:%S') 232-RECV] $line"
    done < "$serial_port" &
    local receive_pid=$!
    # 捕获Ctrl+C信号，清理资源
    trap "kill $receive_pid 2>/dev/null;exit 0" INT
    #rm -f '$fifo_path';


    # 循环读取用户输入并发送到串口
    while true; do
        read -r input
        echo "[$(date '+%H:%M:%S') 232-SEND] $input"
        echo "$input" > "$serial_port"
    done
}

#function can_send(){
#    cansend can0 -i 0x55 $1 0x13 0x14 0x13
#}
#function can_recv(){
#    candump can0
#}

function gpio_get(){
    printf "OUT0 : %s\n" "$(cat /sys/class/gpio/gpio480/value)"
    printf "OUT1 : %s\n" "$(cat /sys/class/gpio/gpio481/value)"
    printf "IN0 : %s\n" "$(cat /sys/class/gpio/gpio482/value)"
    printf "IN1 : %s\n" "$(cat /sys/class/gpio/gpio483/value)"
}

function gpio_set(){
    if [ $# -eq  2 ] ; then
    local io_offset="$1"
    shift
    else
     print_usage
     return 1
    fi
    case "${io_offset}" in
    OUT0)
        echo $1 > /sys/class/gpio/gpio480/value
        return 1
        ;;
    OUT1)
        echo $1 > /sys/class/gpio/gpio481/value
        return 1
    ;;
    *)
        print_usage
        return 1
        ;;
    esac
}

function main() {
    # 检查是否至少有一个参数传入，$# 表示参数个数
    if [ $# -gt 0 ] ; then
      operation="$1"
      shift
    else
      print_usage
      exit 1
    fi

    case "${operation}" in
        init)
            init
            ;;
        relay)
            if [ "$1" = "on" ]; then
                relay_on
            elif [ "$1" = "off" ]; then
                relay_off
            else
                print_usage
                exit 1
            fi
            ;;
        485)
            if [ "$1" = "send" ]; then
                if [ -z "$2" ]; then
                    print_usage
                    exit 1
                fi
                send_485 "$2"
            elif [ "$1" = "recv" ]; then
                recv_485
            else
                print_usage
                exit 1
            fi
            ;;
        232)
            if [ "$1" = "test" ]; then
                test_232
            else
                print_usage
                exit 1
            fi
            ;;
        gpio)
            if [ "$1" = "get" ]; then
                gpio_get

            elif [ "$1" = "set" ]; then
                gpio_set $2 $3
            else
                print_usage
                exit 1
            fi
            ;;
        *)
            print_usage
            exit 1
            ;;
    esac

    exit 0
}

# 启动主函数，传递所有参数
main "$@"