#!/bin/bash 

if ! mountpoint -q /sys/kernel/debug; then 
    sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null 
fi

# screen tittle
echo "======================================================================================================================="
echo "RK3588 FULL MONITOR" 
echo "======================================================================================================================="
printf "%-8s %-6s %-16s %-6s %-7s %-7s %-7s %-10s %-6s %-6s %-6s %-18s\n" \
       "TIME" "CPU%" "LOAD(1/5/15)" "MEM%" "GPU_L%" "NPU_L%" "DDR_L%" "CPU_F(MHz)" "GPU_F" "NPU_F" "DDR_F" "TEMP(A76/GPU/PD)"
echo "-----------------------------------------------------------------------------------------------------------------------"

# write the csv header
echo "Timestamp,CPU%,LOAD_1min,LOAD_5min,LOAD_15min,MEM%,GPU_Load%,NPU_Load%,DDR_Load%,CPU_Freq_Big/CPU_Freq_Little,GPU_Freq_MHz,NPU_Freq_MHz,DDR_Freq_MHz,A76_Temp_C,GPU_Temp_C,PD_Temp_C" > "$LOG_FILE"

line_count=0

# tools function 

# path 

# main loop
while true; do 
    clear 

done 