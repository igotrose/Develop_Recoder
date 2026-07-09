#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define DEFAULT_FB "/dev/fb0"

static uint32_t xrgb8888(uint8_t r, uint8_t g, uint8_t b)
{
	return ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
}

static uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b)
{
	return ((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3);
}

static void put_pixel(uint8_t *fb, const struct fb_fix_screeninfo *fix,
		      const struct fb_var_screeninfo *var,
		      uint32_t x, uint32_t y, uint8_t r, uint8_t g, uint8_t b)
{
	uint8_t *p = fb + y * fix->line_length + x * (var->bits_per_pixel / 8);

	switch (var->bits_per_pixel) {
	case 16:
		*(uint16_t *)p = rgb565(r, g, b);
		break;
	case 24:
		p[var->red.offset / 8] = r;
		p[var->green.offset / 8] = g;
		p[var->blue.offset / 8] = b;
		break;
	case 32:
		*(uint32_t *)p = xrgb8888(r, g, b);
		break;
	default:
		break;
	}
}

static void fill(uint8_t *fb, const struct fb_fix_screeninfo *fix,
		 const struct fb_var_screeninfo *var,
		 uint8_t r, uint8_t g, uint8_t b)
{
	uint32_t x, y;

	for (y = 0; y < var->yres; y++) {
		for (x = 0; x < var->xres; x++)
			put_pixel(fb, fix, var, x, y, r, g, b);
	}
}

static int write_frame(int fd, uint8_t *fb, size_t len)
{
	size_t done = 0;

	if (lseek(fd, 0, SEEK_SET) < 0) {
		perror("lseek");
		return -1;
	}

	while (done < len) {
		ssize_t ret = write(fd, fb + done, len - done);

		if (ret < 0) {
			if (errno == EINTR)
				continue;
			perror("write");
			return -1;
		}

		if (!ret) {
			fprintf(stderr, "short write\n");
			return -1;
		}

		done += ret;
	}

	return 0;
}

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : DEFAULT_FB;
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	uint8_t *fb;
	size_t frame_len;
	int fd;

	fd = open(path, O_RDWR);
	if (fd < 0) {
		perror(path);
		return 1;
	}

	if (ioctl(fd, FBIOGET_FSCREENINFO, &fix)) {
		perror("FBIOGET_FSCREENINFO");
		close(fd);
		return 1;
	}

	if (ioctl(fd, FBIOGET_VSCREENINFO, &var)) {
		perror("FBIOGET_VSCREENINFO");
		close(fd);
		return 1;
	}

	if (var.bits_per_pixel != 16 && var.bits_per_pixel != 24 &&
	    var.bits_per_pixel != 32) {
		fprintf(stderr, "unsupported bpp: %u\n", var.bits_per_pixel);
		close(fd);
		return 1;
	}

	printf("%s: %ux%u %u bpp line_length=%u smem_len=%u\n",
	       path, var.xres, var.yres, var.bits_per_pixel,
	       fix.line_length, fix.smem_len);

	frame_len = fix.line_length * var.yres;
	fb = malloc(frame_len);
	if (!fb) {
		perror("malloc");
		close(fd);
		return 1;
	}

	fill(fb, &fix, &var, 255, 0, 0);
	if (write_frame(fd, fb, frame_len))
		goto err;
	sleep(1);

	fill(fb, &fix, &var, 0, 255, 0);
	if (write_frame(fd, fb, frame_len))
		goto err;
	sleep(1);

	fill(fb, &fix, &var, 0, 0, 255);
	if (write_frame(fd, fb, frame_len))
		goto err;
	sleep(1);

	fill(fb, &fix, &var, 255, 255, 255);
	if (write_frame(fd, fb, frame_len))
		goto err;
	sleep(1);

	free(fb);
	close(fd);
	return 0;

err:
	free(fb);
	close(fd);
	return 1;
}
