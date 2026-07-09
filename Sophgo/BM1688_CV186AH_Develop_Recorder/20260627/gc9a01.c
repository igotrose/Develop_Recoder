// SPDX-License-Identifier: GPL-2.0+
/*
 * DRM driver for GalaxyCore GC9A01 display controllers in SPI mode.
 */

#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/gpio/consumer.h>
#include <linux/module.h>
#include <linux/property.h>
#include <linux/spi/spi.h>

#include <drm/drm_atomic_helper.h>
#include <drm/drm_drv.h>
#include <drm/drm_fb_helper.h>
#include <drm/drm_gem_cma_helper.h>
#include <drm/drm_gem_framebuffer_helper.h>
#include <drm/drm_managed.h>
#include <drm/drm_mipi_dbi.h>
#include <drm/drm_modeset_helper.h>

#include <video/mipi_display.h>

#define GC9A01_MADCTL_BGR	BIT(3)			/* 控制颜色顺序 RGB 或 BGR */
#define GC9A01_MADCTL_MV	BIT(5)			/* 交换行列，也就是 x 和 y 呼唤 */
#define GC9A01_MADCTL_MX	BIT(6)			/* 控制列方向，左到右还是右到左 */
#define GC9A01_MADCTL_MY	BIT(7)			/* 控制行方向，上到下还是下到上 */
#define GC9A01_FLUSH_LINES	16

/* 屏幕私有命令结构，用于描述初始化命令 */
struct gc9a01_init_cmd
{
	u8 cmd;
	u8 len;
	u8 data[16];
};

struct gc9a01_cfg {
	const struct drm_display_mode mode;
	unsigned int width_mm;
	unsigned int height_mm;
};

/* 驱动私有数据，用于存储驱动特定的信息 */
struct gc9a01_priv
{
	struct mipi_dbi_dev dbidev;				/* Linux DRM 里已经有一套 MIPI DBI 辅助框架，SPI小屏服用这结构体 */
	const struct gc9a01_cfg *cfg;
	struct gpio_desc *backlight_gpio;
};

/**
 * 调试参数
 * test_pattern  显示内建纯色测试图，1 红，2 绿，3 蓝，4 白
 * dc_invert     反转 D/C GPIO 极性，用于调板
 * spi_mode      强制 SPI mode 0/1/2/3
 * slow_byte     每次 SPI 只发 1 字节，用于抓波形排查
 * rotate        强制旋转 0/90/180/270
 */

static unsigned int test_pattern;
module_param(test_pattern, uint, 0644);
MODULE_PARM_DESC(test_pattern, "Show built-in test pattern: 0=off, 1=red, 2=green, 3=blue, 4=white");

static bool dc_invert;
module_param(dc_invert, bool, 0644);
MODULE_PARM_DESC(dc_invert, "Invert the D/C GPIO polarity for board bring-up");

static int spi_mode = -1;
module_param(spi_mode, int, 0644);
MODULE_PARM_DESC(spi_mode, "Override SPI mode for board bring-up: -1=keep DT, 0..3=mode");

static bool slow_byte;
module_param(slow_byte, bool, 0644);
MODULE_PARM_DESC(slow_byte, "Write test pattern one byte per SPI message for signal bring-up");

static int rotate = -1;
module_param(rotate, int, 0644);
MODULE_PARM_DESC(rotate, "Override display rotation: -1=use DT, 0/90/180/270");

/* 屏幕初始化序列 */
static const struct gc9a01_init_cmd gc9a01_boe_128_init[] = {
	{ 0xef, 0, {} },
	{ 0xeb, 1, { 0x14 } },
	{ 0xfe, 0, {} },
	{ 0xef, 0, {} },
	{ 0xeb, 1, { 0x14 } },
	{ 0x84, 1, { 0x40 } },
	{ 0x85, 1, { 0xff } },
	{ 0x86, 1, { 0xff } },
	{ 0x87, 1, { 0xff } },
	{ 0x88, 1, { 0x0a } },
	/*
	 * Keep the vendor supplied single-data SPI setting. Do not use the
	 * 0x23 value seen in some dual-data examples on this one-SDA board.
	 */
	{ 0x89, 1, { 0x21 } },				/* 单线SPI */
	{ 0x8a, 1, { 0x00 } },
	{ 0x8b, 1, { 0x80 } },
	{ 0x8c, 1, { 0x01 } },
	{ 0x8d, 1, { 0x01 } },
	{ 0x8e, 1, { 0xff } },
	{ 0x8f, 1, { 0xff } },
	{ 0xb6, 2, { 0x00, 0x20 } },
	{ 0x36, 1, { 0x08 } },				/* MADCTL，设置扫描方向、RGB/BGR 顺序 */
	{ 0x3a, 1, { 0x05 } },				/* COLMOD，设置像素格式，这里 0x05 = RGB565 */
	{ 0x90, 4, { 0x08, 0x08, 0x08, 0x08 } },
	{ 0xbd, 1, { 0x06 } },
	{ 0xbc, 1, { 0x00 } },
	{ 0xff, 3, { 0x60, 0x01, 0x04 } },
	{ 0xc3, 1, { 0x13 } },
	{ 0xc4, 1, { 0x13 } },
	{ 0xc9, 1, { 0x22 } },
	{ 0xbe, 1, { 0x11 } },
	{ 0xe1, 2, { 0x10, 0x0e } },
	{ 0xdf, 3, { 0x21, 0x0c, 0x02 } },
	{ 0xf0, 6, { 0x45, 0x09, 0x08, 0x08, 0x26, 0x2a } },
	{ 0xf1, 6, { 0x43, 0x70, 0x72, 0x36, 0x37, 0x6f } },
	{ 0xf2, 6, { 0x45, 0x09, 0x08, 0x08, 0x26, 0x2a } },
	{ 0xf3, 6, { 0x43, 0x70, 0x72, 0x36, 0x37, 0x6f } },
	{ 0xed, 2, { 0x1b, 0x0b } },
	{ 0xae, 1, { 0x77 } },
	{ 0xcd, 1, { 0x63 } },
	{ 0x70, 9, { 0x07, 0x07, 0x04, 0x0e, 0x0f, 0x09, 0x07, 0x08, 0x03 } },
	{ 0xe8, 1, { 0x34 } },
	{ 0x62, 12, { 0x18, 0x0d, 0x71, 0xed, 0x70, 0x70, 0x18, 0x0f,
		       0x71, 0xef, 0x70, 0x70 } },
	{ 0x63, 12, { 0x18, 0x11, 0x71, 0xf1, 0x70, 0x70, 0x18, 0x13,
		       0x71, 0xf3, 0x70, 0x70 } },
	{ 0x64, 7, { 0x28, 0x29, 0xf1, 0x01, 0xf1, 0x00, 0x07 } },
	{ 0x66, 10, { 0x3c, 0x00, 0xcd, 0x67, 0x45, 0x45, 0x10, 0x00, 0x00, 0x00 } },
	{ 0x67, 10, { 0x00, 0x3c, 0x00, 0x00, 0x00, 0x01, 0x54, 0x10, 0x32, 0x98 } },
	{ 0x74, 7, { 0x10, 0x85, 0x80, 0x00, 0x00, 0x4e, 0x00 } },
	{ 0x98, 2, { 0x3e, 0x07 } },
	{ 0x35, 0, {} },
	{ 0x21, 0, {} },
};

/* 发送初始化序列 */
static int gc9a01_send_init_sequence(struct mipi_dbi* dbi)
{
	unsigned int i;
	int ret;

	for (i = 0; i < ARRAY_SIZE(gc9a01_boe_128_init); i++) {
		const struct gc9a01_init_cmd* entry = &gc9a01_boe_128_init[i];
		/**
		 * MIPI DBI helper 会自动处理命令/数据阶段：
 		 * 发送 entry->cmd 时 D/C 为低，发送 entry->data 参数时 D/C 为高。
		 */
		ret = mipi_dbi_command_stackbuf(dbi, entry->cmd, entry->data,
			entry->len);

		if (ret)
			return ret;
	}

	return 0;
}

/* 硬件复位 */
static void gc9a01_hw_reset(struct mipi_dbi* dbi)
{
	if (!dbi->reset)
		return;

	gpiod_set_value_cansleep(dbi->reset, 1);
	msleep(50);
	gpiod_set_value_cansleep(dbi->reset, 0);
	msleep(50);
	gpiod_set_value_cansleep(dbi->reset, 1);
	msleep(120);
}

/*
 * 根据屏幕旋转角度生成 MADCTL(36h, Memory Access Control) 的参数。
 *
 * MADCTL 用来控制显存地址到屏幕扫描方向的映射关系：
 *   MY  : 行地址方向
 *   MX  : 列地址方向
 *   MV  : 行列交换，也就是 x/y 互换
 *   BGR : 使用 BGR 颜色顺序
 *
 * 通过组合 MX/MY/MV 可以实现 0/90/180/270 度旋转。
 * 本屏初始化使用 BGR 颜色顺序，因此每个方向都保留 BGR bit。
 */
static u8 gc9a01_madctl(unsigned int rotation)
{
	switch (rotation) {
	default:
	case 0:
		return GC9A01_MADCTL_BGR;
	case 90:
		return GC9A01_MADCTL_MV | GC9A01_MADCTL_MX |
		       GC9A01_MADCTL_BGR;
	case 180:
		return GC9A01_MADCTL_MX | GC9A01_MADCTL_MY |
		       GC9A01_MADCTL_BGR;
	case 270:
		return GC9A01_MADCTL_MV | GC9A01_MADCTL_MY |
		       GC9A01_MADCTL_BGR;
	}
}

/* 验证旋转角度是否有效 */
static bool gc9a01_valid_rotation(unsigned int rotation)
{
	return rotation == 0 || rotation == 90 ||
	       rotation == 180 || rotation == 270;
}

/* 设置刷屏窗口 */
static void gc9a01_set_window(struct mipi_dbi* dbi, u16 xs, u16 xe,
			      u16 ys, u16 ye)
{
	/* 设置列和页地址 */
	mipi_dbi_command(dbi, MIPI_DCS_SET_COLUMN_ADDRESS,
			 xs >> 8, xs & 0xff, xe >> 8, xe & 0xff);
	mipi_dbi_command(dbi, MIPI_DCS_SET_PAGE_ADDRESS,
			 ys >> 8, ys & 0xff, ye >> 8, ye & 0xff);
}

/* 发送 0x2C 命令，通知 LCD 开始向当前窗口写入显存 */
static int gc9a01_write_memory_start(struct mipi_dbi* dbi)
{
	u8 cmd = MIPI_DCS_WRITE_MEMORY_START;

	if (!dbi->dc)
		return mipi_dbi_command(dbi, cmd);
	
	/*
	 * D/C = 0 表示当前 SPI 字节是命令。
	 * 这里发送 MIPI_DCS_WRITE_MEMORY_START(0x2C)。
	 */
	gpiod_set_value_cansleep(dbi->dc, 0);
	return spi_write(dbi->spi, &cmd, 1);
}

/* 发送 RGB565 像素数据到 LCD 当前写显存窗口 */
static int gc9a01_write_memory_data(struct mipi_dbi* dbi, const u8* buf,
				    size_t len)
{
	size_t i;
	int ret;

	if (!dbi->dc)
		return -EINVAL;

	gpiod_set_value_cansleep(dbi->dc, 1);

	if (slow_byte) {
		for (i = 0; i < len; i++) {
			ret = spi_write(dbi->spi, &buf[i], 1);
			if (ret)
				return ret;
		}

		return 0;
	}

	return spi_write(dbi->spi, buf, len);
}

/* 四色测试 */
static int gc9a01_show_test_pattern(struct mipi_dbi_dev* dbidev)
{
	struct mipi_dbi *dbi = &dbidev->dbi;
	u8 *buf = (u8 *)dbidev->tx_buf;
	u16 color = 0xffff;
	unsigned int i, chunk;
	int ret;

	switch (test_pattern) {
	case 1:
		color = 0xf800;
		break;
	case 2:
		color = 0x07e0;
		break;
	case 3:
		color = 0x001f;
		break;
	case 4:
		color = 0xffff;
		break;
	default:
		return 0;
	}

	DRM_DEV_INFO(dbidev->drm.dev, "show test pattern %u, rgb565=0x%04x, swap_bytes=%d, slow_byte=%d\n",
		     test_pattern, color, dbi->swap_bytes, slow_byte);

	/* 十六位，高八位第八位 */
	for (i = 0; i < 240; i++)
	{
		buf[i * 2] = color >> 8;
		buf[i * 2 + 1] = color & 0xff;
	}

	gc9a01_set_window(dbi, 0, 239, 0, 239);

	ret = gc9a01_write_memory_start(dbi);
	if (ret)
		return ret;

	for (chunk = 0; chunk < 240; chunk++) {
		ret = gc9a01_write_memory_data(dbi, buf, 240 * 2);
		if (ret)
			return ret;
	}

	return 0;
}

/* 刷新整个屏幕，把 framebuffer 的数据搬运到 GRAM 上 */
static int gc9a01_flush_full(struct mipi_dbi_dev* dbidev,
			     struct drm_framebuffer *fb)
{
	struct mipi_dbi *dbi = &dbidev->dbi;
	struct drm_rect rect = {
		.x1 = 0,
		.y1 = 0,
		.x2 = fb->width,
		.y2 = fb->height,
	};
	unsigned int line_len = fb->width * 2;
	unsigned int lines;
	unsigned int y;
	u8 *buf = (u8 *)dbidev->tx_buf;
	int ret;
	/* 把 DRM framebuffer 拷贝到 dbidev->tx_buf，并处理字节序 */
	ret = mipi_dbi_buf_copy(buf, fb, &rect, dbi->swap_bytes);
	if (ret)
		return ret;
	/* 设置全屏窗口，发送 0x2C */
	gc9a01_set_window(dbi, 0, fb->width - 1, 0, fb->height - 1);

	ret = gc9a01_write_memory_start(dbi);
	if (ret)
		return ret;
	/* 分块发送数据 */
	for (y = 0; y < fb->height; y += lines) {
		lines = min_t(unsigned int, GC9A01_FLUSH_LINES,
			      fb->height - y);
		ret = gc9a01_write_memory_data(dbi, buf + y * line_len,
					       line_len * lines);
		if (ret)
			return ret;
	}

	return 0;
}

/* 初始化 LCD */
static int gc9a01_panel_init(struct mipi_dbi_dev* dbidev)
{
	struct mipi_dbi *dbi = &dbidev->dbi;
	int ret;

	gc9a01_hw_reset(dbi);

	ret = gc9a01_send_init_sequence(dbi);
	if (ret)
		return ret;

	ret = mipi_dbi_command(dbi, MIPI_DCS_SET_ADDRESS_MODE,
			       gc9a01_madctl(dbidev->rotation));
	if (ret)
		return ret;

	msleep(120);
	ret = mipi_dbi_command(dbi, MIPI_DCS_EXIT_SLEEP_MODE);
	if (ret)
		return ret;

	msleep(120);
	return mipi_dbi_command(dbi, MIPI_DCS_SET_DISPLAY_ON);
}

static void gc9a01_pipe_enable(struct drm_simple_display_pipe *pipe,
			       struct drm_crtc_state *crtc_state,
			       struct drm_plane_state *plane_state)
{
	/* 从 DRM 设备对象反推出 MIPI DBI 设备对象 */
	struct mipi_dbi_dev *dbidev = drm_to_mipi_dbi_dev(pipe->crtc.dev);
	struct gc9a01_priv *priv = container_of(dbidev, struct gc9a01_priv,
						dbidev);
	int idx;
	int ret;
	/* DRM 子系统里的一个保护函数，用于保护设备访问 */
	if (!drm_dev_enter(pipe->crtc.dev, &idx))
		return;

	DRM_DEV_INFO(pipe->crtc.dev->dev, "send init sequence, test_pattern=%u\n",
		     test_pattern);
			 
	/* 启用显示 */
	ret = gc9a01_panel_init(dbidev);
	if (ret) {
		DRM_DEV_ERROR(pipe->crtc.dev->dev,
			      "Failed to initialize panel (%d)\n", ret);
		goto out_exit;
	}

	if (test_pattern) {
		ret = gc9a01_show_test_pattern(dbidev);
		if (ret)
			DRM_DEV_ERROR(pipe->crtc.dev->dev,
				      "Failed to show test pattern (%d)\n", ret);
		gpiod_set_value_cansleep(priv->backlight_gpio, 1);
		goto out_exit;
	}

	mipi_dbi_enable_flush(dbidev, crtc_state, plane_state);
	gpiod_set_value_cansleep(priv->backlight_gpio, 1);

out_exit:
	drm_dev_exit(idx);
}

static void gc9a01_pipe_disable(struct drm_simple_display_pipe *pipe)
{
	struct mipi_dbi_dev *dbidev = drm_to_mipi_dbi_dev(pipe->crtc.dev);
	struct gc9a01_priv *priv = container_of(dbidev, struct gc9a01_priv,
						dbidev);

	mipi_dbi_pipe_disable(pipe);
	gpiod_set_value_cansleep(priv->backlight_gpio, 0);
}

static void gc9a01_pipe_update(struct drm_simple_display_pipe *pipe,
			       struct drm_plane_state *old_state)
{
	struct drm_plane_state* state = pipe->plane.state;
	struct mipi_dbi_dev* dbidev = drm_to_mipi_dbi_dev(pipe->crtc.dev);
	int idx;
	int ret;

	if (test_pattern)
		return;

	if (!pipe->crtc.state->active || !state->fb)
		return;

	if (!drm_dev_enter(pipe->crtc.dev, &idx))
		return;

	dev_info_ratelimited(pipe->crtc.dev->dev, "pipe full update\n");

	ret = gc9a01_flush_full(dbidev, state->fb);
	if (ret)
		DRM_DEV_ERROR(pipe->crtc.dev->dev,
			      "Failed to update display (%d)\n", ret);

	drm_dev_exit(idx);
}

/**
 * 在 DRM/KMS 里，一条显示 pipe 可以理解成
 * framebuffer -> plane -> crtc -> encoder -> connector -> display
 * 也就是一条“把内存里的画面送到显示设备”的显示流水线
 * 
 * 开启屏幕时，调用 gc9a01_pipe_enable
 * 关闭屏幕时，调用 gc9a01_pipe_disable
 * 刷新画面时，调用 gc9a01_pipe_update
 * 显示前准备 framebuffer 时，调用 DRM GEM helper
 */
static const struct drm_simple_display_pipe_funcs gc9a01_pipe_funcs = {
	.enable		= gc9a01_pipe_enable,
	.disable	= gc9a01_pipe_disable,
	.update		= gc9a01_pipe_update,
	.prepare_fb	= drm_gem_fb_simple_display_pipe_prepare_fb,
};

static const struct gc9a01_cfg gc9a01_boe_128_cfg = {
	.mode		= { DRM_SIMPLE_MODE(240, 240, 32, 32) },
	.width_mm	= 32,
	.height_mm	= 32,
};

/**
 *  DEFINE_DRM_GEM_CMA_FOPS 是 DRM 里的一个宏，
 * 用来定义一套适合 GEM CMA framebuffer 驱动使用的 file_operation
 * */
DEFINE_DRM_GEM_CMA_FOPS(gc9a01_fops);

static struct drm_driver gc9a01_driver = {
	.driver_features	= DRIVER_GEM | DRIVER_MODESET | DRIVER_ATOMIC,
	.fops			= &gc9a01_fops,
	DRM_GEM_CMA_DRIVER_OPS_VMAP,
	.debugfs_init		= mipi_dbi_debugfs_init,
	.name			= "gc9a01",
	.desc			= "GC9A01 SPI LCD",
	.date			= "20260625",
	.major			= 1,
	.minor			= 0,
};

static const struct of_device_id gc9a01_of_match[] = {
	{ .compatible = "hynetek,gc9a01-boe-1.28", .data = &gc9a01_boe_128_cfg },
	{ .compatible = "galaxycore,gc9a01", .data = &gc9a01_boe_128_cfg },
	{ },
};
MODULE_DEVICE_TABLE(of, gc9a01_of_match);

static const struct spi_device_id gc9a01_id[] = {
	{ "gc9a01", (uintptr_t)&gc9a01_boe_128_cfg },
	{ },
};
MODULE_DEVICE_TABLE(spi, gc9a01_id);

static int gc9a01_probe(struct spi_device *spi)
{
	struct device *dev = &spi->dev;
	const struct gc9a01_cfg *cfg;
	struct gc9a01_priv *priv;
	struct mipi_dbi_dev *dbidev;
	struct drm_device *drm;
	struct mipi_dbi *dbi;
	struct gpio_desc *dc;
	u32 rotation = 0;
	int ret;

	cfg = device_get_match_data(dev);
	if (!cfg)
		cfg = (void *)spi_get_device_id(spi)->driver_data;

	priv = devm_drm_dev_alloc(dev, &gc9a01_driver,
				  struct gc9a01_priv, dbidev.drm);
	if (IS_ERR(priv))
		return PTR_ERR(priv);

	priv->cfg = cfg;
	dbidev = &priv->dbidev;
	dbi = &dbidev->dbi;
	drm = &dbidev->drm;

	dbi->reset = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(dbi->reset))
		return dev_err_probe(dev, PTR_ERR(dbi->reset),
				     "Failed to get reset GPIO\n");

	dc = devm_gpiod_get_optional(dev, "dc", GPIOD_OUT_LOW);
	if (IS_ERR(dc))
		return dev_err_probe(dev, PTR_ERR(dc),
				     "Failed to get dc GPIO\n");
	if (dc && dc_invert)
		gpiod_toggle_active_low(dc);

	priv->backlight_gpio = devm_gpiod_get_optional(dev, "backlight",
						       GPIOD_OUT_LOW);
	if (IS_ERR(priv->backlight_gpio))
		return dev_err_probe(dev, PTR_ERR(priv->backlight_gpio),
				     "Failed to get backlight GPIO\n");

	device_property_read_u32(dev, "rotation", &rotation);
	if (rotate >= 0 && gc9a01_valid_rotation(rotate))
		rotation = rotate;
	else if (rotate >= 0)
		dev_warn(dev, "ignore invalid rotate=%d, use rotation=%u\n",
			 rotate, rotation);

	ret = dma_coerce_mask_and_coherent(dev, DMA_BIT_MASK(64));
	if (ret) {
		ret = dma_coerce_mask_and_coherent(dev, DMA_BIT_MASK(32));
		if (ret)
			return dev_err_probe(dev, ret,
					     "Failed to set DMA mask\n");
	}

	if (spi_mode >= 0 && spi_mode <= 3)
		spi->mode = (spi->mode & ~(SPI_CPOL | SPI_CPHA)) |
			    (spi_mode & (SPI_CPOL | SPI_CPHA));
	spi->bits_per_word = 8;
	ret = spi_setup(spi);
	if (ret)
		return dev_err_probe(dev, ret, "Failed to setup SPI\n");

	ret = mipi_dbi_spi_init(spi, dbi, dc);
	if (ret)
		return ret;

	/*
	 * The reference bit-banged code writes RGB565 as two 8-bit transfers,
	 * MSB first. Force the MIPI DBI helper down that path instead of using
	 * 16-bit SPI words whose byte order depends on the SPI controller.
	 *
	 * Keep this disabled while debugging a white test pattern: 0xffff is
	 * byte-order independent, so mosaic on white points at command/data
	 * framing, DC polarity, or panel init rather than RGB565 endianness.
	 */
	dbi->swap_bytes = true;
	dbi->read_commands = NULL;

	dev_info(dev, "gc9a01 spi mode=0x%x bpw=%u max_speed=%u dc=%s dc_invert=%d backlight_gpio=%s rotation=%u\n",
		 spi->mode, spi->bits_per_word, spi->max_speed_hz,
		 dc ? "yes" : "no", dc_invert,
		 priv->backlight_gpio ? "yes" : "no", rotation);

	/* 向 DRM/KMS 注册显示设备 */
	ret = mipi_dbi_dev_init(dbidev, &gc9a01_pipe_funcs, &cfg->mode,
				rotation);
	if (ret)
		return ret;

	drm_mode_config_reset(drm);

	ret = drm_dev_register(drm, 0);
	if (ret)
		return ret;

	spi_set_drvdata(spi, drm);
	if (test_pattern) {
		dev_info(dev, "initialize panel directly for test_pattern=%u\n",
			 test_pattern);
		ret = gc9a01_panel_init(dbidev);
		if (ret)
			return dev_err_probe(dev, ret,
					     "Failed to initialize panel\n");

		ret = gc9a01_show_test_pattern(dbidev);
		if (ret)
			return dev_err_probe(dev, ret,
					     "Failed to show test pattern\n");

		gpiod_set_value_cansleep(priv->backlight_gpio, 1);
		return 0;
	}

	drm_fbdev_generic_setup(drm, 0);

	return 0;
}

static int gc9a01_remove(struct spi_device *spi)
{
	struct drm_device *drm = spi_get_drvdata(spi);

	drm_dev_unplug(drm);
	drm_atomic_helper_shutdown(drm);

	return 0;
}

static void gc9a01_shutdown(struct spi_device *spi)
{
	drm_atomic_helper_shutdown(spi_get_drvdata(spi));
}

static int __maybe_unused gc9a01_pm_suspend(struct device *dev)
{
	return drm_mode_config_helper_suspend(dev_get_drvdata(dev));
}

static int __maybe_unused gc9a01_pm_resume(struct device *dev)
{
	drm_mode_config_helper_resume(dev_get_drvdata(dev));

	return 0;
}

static const struct dev_pm_ops gc9a01_pm_ops = {
	SET_SYSTEM_SLEEP_PM_OPS(gc9a01_pm_suspend, gc9a01_pm_resume)
};

static struct spi_driver gc9a01_spi_driver = {
	.driver = {
		.name		= "gc9a01",
		.of_match_table	= gc9a01_of_match,
		.pm		= &gc9a01_pm_ops,
	},
	.id_table	= gc9a01_id,
	.probe		= gc9a01_probe,
	.remove		= gc9a01_remove,
	.shutdown	= gc9a01_shutdown,
};
module_spi_driver(gc9a01_spi_driver);

MODULE_DESCRIPTION("GC9A01 SPI LCD DRM driver");
MODULE_AUTHOR("QIU");
MODULE_LICENSE("GPL");
