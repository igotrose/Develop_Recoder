#!/bin/bash 

# gpio definition
DI0=78
DI1=85
DO0=146
DO1=150

export_gpio()
{
    local gpio_num=$1
    if [ ! -d "/sys/class/gpio/gpio$gpio_num" ]; then 
        echo $gpio_num > /sys/class/gpio/export 
        sleep 0.1
    fi
}

# export gpio
for g in $DI0 $DI1 $DO0 $DO1; do
    export_gpio $g
done

# set gpio direction
echo out > /sys/class/gpio/gpio$DO0/direction
echo out > /sys/class/gpio/gpio$DO1/direction
echo in > /sys/class/gpio/gpio$DI0/direction
echo in > /sys/class/gpio/gpio$DI1/direction

combinations=(
    "1 1"
    "0 1"
    "0 0"
    "1 0"
)

for combo in "${combinations[@]}"; do 
    read do0_val do1_val <<< "$combo"

    echo $do0_val > /sys/class/gpio/gpio$DO0/value
    echo $do1_val > /sys/class/gpio/gpio$DO1/value

    sleep 0.1

    di0_val=$(cat /sys/class/gpio/gpio$DI0/value)
    di1_val=$(cat /sys/class/gpio/gpio$DI1/value)

    printf "DO=%s%s → DI=%s%s\n" "$do0_val" "$do1_val" "$di0_val" "$di1_val"
done

