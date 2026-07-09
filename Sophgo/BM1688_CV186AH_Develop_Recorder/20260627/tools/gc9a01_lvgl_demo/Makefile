ROOT ?= ../..
LVGL_DIR ?= $(ROOT)/third_party/lvgl
OVERLAY_DIR ?= $(ROOT)/ubuntu/bootloader-arm64/distro/overlay/SOPHON/sophgo-fs
CROSS_COMPILE ?= $(ROOT)/host-tools/gcc/arm-gnu-toolchain-11.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-
CC := $(CROSS_COMPILE)gcc

TARGET := gc9a01_lvgl_demo
LVGL_SRCS := $(shell test -d "$(LVGL_DIR)/src" && find "$(LVGL_DIR)/src" -name '*.c')

CFLAGS += -Wall -Wextra -O2 -DLV_CONF_INCLUDE_SIMPLE
CFLAGS += -DLV_CONF_PATH=\"lv_conf.h\"
CFLAGS += -I. -I$(LVGL_DIR) -I$(LVGL_DIR)/src -I$(LVGL_DIR)/include
LDFLAGS += -lm

.PHONY: all clean install check-lvgl

all: check-lvgl $(TARGET)

check-lvgl:
	@test -d "$(LVGL_DIR)/src" || { \
		echo "Missing LVGL source tree: $(LVGL_DIR)"; \
		exit 1; \
	}

$(TARGET): gc9a01_lvgl_demo.c lv_conf.h $(LVGL_SRCS)
	$(CC) $(CFLAGS) -o $@ gc9a01_lvgl_demo.c $(LVGL_SRCS) $(LDFLAGS)

install: $(TARGET)
	install -D -m 0755 $(TARGET) $(OVERLAY_DIR)/usr/sbin/$(TARGET)

clean:
	rm -f $(TARGET)
