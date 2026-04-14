# 定义模块名
MODULE_NAME = aios_gpio

# 源文件
#$(MODULE_NAME)-objs := gpio_aios.o

# 编译为内核模块
obj-m := $(MODULE_NAME).o

# 指定编译目标架构
export ARCH ?= arm64

# 指定交叉编译工具链前缀
export CROSS_COMPILE ?= /workspace/gcc-linaro-6.3.1-2017.05-x86_64_aarch64-linux-gnu/bin/aarch64-linux-gnu-

# 当前目录
PWD := $(shell pwd)

# 内核构建目录
KERNEL_BUILD ?= /workspace/linux-arm64/build/bm1684/normal


# 默认目标 - 编译模块
all:
	$(MAKE) -C $(KERNEL_BUILD) M=$(PWD) modules
	rm -rf *.o *.mod *.mod.c *.mod.o *.symvers *.order *.cmd *.tmp_versions

# 清理编译文件
clean:
	$(MAKE) -C $(KERNEL_BUILD) M=$(PWD) clean
	
