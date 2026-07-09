ROOT ?= ../..
CROSS_COMPILE ?= $(ROOT)/host-tools/gcc/arm-gnu-toolchain-11.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-
CC := $(CROSS_COMPILE)gcc

CFLAGS += -Wall -Wextra -O2

TARGET := gc9a01_fb_test

.PHONY: all clean

all: $(TARGET)

$(TARGET): gc9a01_fb_test.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)
