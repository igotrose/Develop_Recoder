// SPDX-License-Identifier: GPL-2.0+
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "lvgl.h"

#define DEFAULT_FB "/dev/fb0"
#define DRAW_LINES 40

struct fb_ctx {
	int fd;
	uint8_t *mem;
	size_t len;
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
};

static struct fb_ctx fb = { .fd = -1 };
static volatile sig_atomic_t stop;

static uint32_t tick_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint32_t)(ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL);
}

static uint32_t rgb565_to_xrgb8888(uint16_t c)
{
	uint8_t r = ((c >> 11) & 0x1f) << 3;
	uint8_t g = ((c >> 5) & 0x3f) << 2;
	uint8_t b = (c & 0x1f) << 3;

	return ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
}

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static int fb_open(const char *path)
{
	fb.fd = open(path, O_RDWR);
	if (fb.fd < 0) {
		perror(path);
		return -1;
	}

	if (ioctl(fb.fd, FBIOGET_FSCREENINFO, &fb.fix)) {
		perror("FBIOGET_FSCREENINFO");
		return -1;
	}

	if (ioctl(fb.fd, FBIOGET_VSCREENINFO, &fb.var)) {
		perror("FBIOGET_VSCREENINFO");
		return -1;
	}

	if (fb.var.bits_per_pixel != 16 && fb.var.bits_per_pixel != 32) {
		fprintf(stderr, "unsupported fb depth: %u bpp\n",
			fb.var.bits_per_pixel);
		return -1;
	}

	fb.len = fb.fix.line_length * fb.var.yres;
	fb.mem = mmap(NULL, fb.len, PROT_READ | PROT_WRITE, MAP_SHARED, fb.fd, 0);
	if (fb.mem == MAP_FAILED) {
		perror("mmap");
		fb.mem = NULL;
		return -1;
	}

	printf("%s: %ux%u %u bpp line_length=%u smem_len=%u\n",
	       path, fb.var.xres, fb.var.yres, fb.var.bits_per_pixel,
	       fb.fix.line_length, fb.fix.smem_len);

	return 0;
}

static void fb_close(void)
{
	if (fb.mem)
		munmap(fb.mem, fb.len);
	if (fb.fd >= 0)
		close(fb.fd);
}

static void fb_flush(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
	int32_t x1 = area->x1 < 0 ? 0 : area->x1;
	int32_t y1 = area->y1 < 0 ? 0 : area->y1;
	int32_t x2 = area->x2 >= (int32_t)fb.var.xres ? (int32_t)fb.var.xres - 1 : area->x2;
	int32_t y2 = area->y2 >= (int32_t)fb.var.yres ? (int32_t)fb.var.yres - 1 : area->y2;
	const uint16_t *src = (const uint16_t *)px_map;
	int32_t x;
	int32_t y;

	for (y = area->y1; y <= area->y2; y++) {
		for (x = area->x1; x <= area->x2; x++) {
			if (x >= x1 && x <= x2 && y >= y1 && y <= y2) {
				uint8_t *dst = fb.mem + y * fb.fix.line_length +
					       x * (fb.var.bits_per_pixel / 8);
				uint16_t c = *src;

				if (fb.var.bits_per_pixel == 16)
					*(uint16_t *)dst = c;
				else
					*(uint32_t *)dst = rgb565_to_xrgb8888(c);
			}
			src++;
		}
	}

	lv_display_flush_ready(disp);
}

static void create_demo_ui(void)
{
	lv_obj_t *scr = lv_screen_active();
	lv_obj_t *arc;
	lv_obj_t *title;
	lv_obj_t *sub;
	lv_obj_t *bar;
	static lv_style_t bg;

	lv_style_init(&bg);
	lv_style_set_bg_color(&bg, lv_color_hex(0x071522));
	lv_style_set_bg_opa(&bg, LV_OPA_COVER);
	lv_obj_add_style(scr, &bg, 0);

	arc = lv_arc_create(scr);
	lv_obj_set_size(arc, 204, 204);
	lv_obj_center(arc);
	lv_arc_set_range(arc, 0, 100);
	lv_arc_set_value(arc, 73);
	lv_obj_remove_flag(arc, LV_OBJ_FLAG_CLICKABLE);
	lv_obj_set_style_arc_width(arc, 12, LV_PART_MAIN);
	lv_obj_set_style_arc_width(arc, 12, LV_PART_INDICATOR);
	lv_obj_set_style_arc_color(arc, lv_color_hex(0x183242), LV_PART_MAIN);
	lv_obj_set_style_arc_color(arc, lv_color_hex(0x21d99b), LV_PART_INDICATOR);

	title = lv_label_create(scr);
	lv_label_set_text(title, "GC9A01");
	lv_obj_set_style_text_color(title, lv_color_white(), 0);
	lv_obj_set_style_text_font(title, &lv_font_montserrat_16, 0);
	lv_obj_align(title, LV_ALIGN_CENTER, 0, -26);

	sub = lv_label_create(scr);
	lv_label_set_text(sub, "LVGL 9 fbdev");
	lv_obj_set_style_text_color(sub, lv_color_hex(0xa9c9d8), 0);
	lv_obj_align(sub, LV_ALIGN_CENTER, 0, 0);

	bar = lv_bar_create(scr);
	lv_obj_set_size(bar, 118, 10);
	lv_obj_align(bar, LV_ALIGN_CENTER, 0, 34);
	lv_bar_set_range(bar, 0, 100);
	lv_bar_set_value(bar, 58, LV_ANIM_OFF);
	lv_obj_set_style_bg_color(bar, lv_color_hex(0x20384a), LV_PART_MAIN);
	lv_obj_set_style_bg_color(bar, lv_color_hex(0x39a7ff), LV_PART_INDICATOR);
}

int main(int argc, char **argv)
{
	const char *fb_path = argc > 1 ? argv[1] : DEFAULT_FB;
	size_t draw_pixels;
	size_t draw_buf_size;
	lv_display_t *disp;
	uint8_t *buf1;
	uint8_t *buf2;

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	if (fb_open(fb_path))
		goto err;

	lv_init();
	lv_tick_set_cb(tick_ms);

	draw_pixels = fb.var.xres * DRAW_LINES;
	draw_buf_size = draw_pixels * sizeof(uint16_t);
	buf1 = calloc(1, draw_buf_size);
	buf2 = calloc(1, draw_buf_size);
	if (!buf1 || !buf2) {
		perror("calloc");
		free(buf1);
		free(buf2);
		goto err;
	}

	disp = lv_display_create(fb.var.xres, fb.var.yres);
	lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
	lv_display_set_flush_cb(disp, fb_flush);
	lv_display_set_buffers(disp, buf1, buf2, draw_buf_size,
			       LV_DISPLAY_RENDER_MODE_PARTIAL);

	create_demo_ui();

	while (!stop) {
		lv_timer_handler();
		usleep(5000);
	}

	free(buf1);
	free(buf2);
	fb_close();
	return 0;

err:
	fb_close();
	return 1;
}
