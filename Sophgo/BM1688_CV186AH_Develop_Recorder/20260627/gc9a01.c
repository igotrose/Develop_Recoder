// SPDX-License-Identifier: GPL-2.0+
/*
 * DRM driver for GalaxyCore GC9A01 display controllers in SPI mode.
 */

#include <linux/backlight.h>
#include <linux/byteorder/generic.h>
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

#define GC9A01_MADCTL_BGR	BIT(3)
#define GC9A01_MADCTL_MV	BIT(5)
#define GC9A01_MADCTL_MX	BIT(6)
#define GC9A01_MADCTL_MY	BIT(7)

struct gc9a01_init_cmd {
	u8 cmd;
	u8 len;
	u8 data[16];
};

struct gc9a01_cfg {
	const struct drm_display_mode mode;
	unsigned int width_mm;
	unsigned int height_mm;
};

struct gc9a01_priv {
	struct mipi_dbi_dev dbidev;
	const struct gc9a01_cfg *cfg;
};

static unsigned int test_pattern;
module_param(test_pattern, uint, 0644);
MODULE_PARM_DESC(test_pattern, "Show built-in test pattern: 0=off, 1=red, 2=green, 3=blue, 4=white");

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
	{ 0x89, 1, { 0x21 } },
	{ 0x8a, 1, { 0x00 } },
	{ 0x8b, 1, { 0x80 } },
	{ 0x8c, 1, { 0x01 } },
	{ 0x8d, 1, { 0x01 } },
	{ 0x8e, 1, { 0xff } },
	{ 0x8f, 1, { 0xff } },
	{ 0xb6, 2, { 0x00, 0x20 } },
	{ 0x36, 1, { 0x08 } },
	{ 0x3a, 1, { 0x55 } },
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

static int gc9a01_send_init_sequence(struct mipi_dbi *dbi)
{
	unsigned int i;
	int ret;

	for (i = 0; i < ARRAY_SIZE(gc9a01_boe_128_init); i++) {
		const struct gc9a01_init_cmd *entry = &gc9a01_boe_128_init[i];

		ret = mipi_dbi_command_stackbuf(dbi, entry->cmd, entry->data,
						entry->len);
		if (ret)
			return ret;
	}

	return 0;
}

static void gc9a01_hw_reset(struct mipi_dbi *dbi)
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

static void gc9a01_set_window(struct mipi_dbi *dbi, u16 xs, u16 xe,
			      u16 ys, u16 ye)
{
	mipi_dbi_command(dbi, MIPI_DCS_SET_COLUMN_ADDRESS,
			 xs >> 8, xs & 0xff, xe >> 8, xe & 0xff);
	mipi_dbi_command(dbi, MIPI_DCS_SET_PAGE_ADDRESS,
			 ys >> 8, ys & 0xff, ye >> 8, ye & 0xff);
}

static int gc9a01_show_test_pattern(struct mipi_dbi_dev *dbidev)
{
	struct mipi_dbi *dbi = &dbidev->dbi;
	u16 color = 0xffff;
	unsigned int i;

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

	if (dbi->swap_bytes)
		color = cpu_to_be16(color);

	for (i = 0; i < 240 * 240; i++)
		dbidev->tx_buf[i] = color;

	gc9a01_set_window(dbi, 0, 239, 0, 239);

	return mipi_dbi_command_buf(dbi, MIPI_DCS_WRITE_MEMORY_START,
				    (u8 *)dbidev->tx_buf, 240 * 240 * 2);
}

static void gc9a01_pipe_enable(struct drm_simple_display_pipe *pipe,
			       struct drm_crtc_state *crtc_state,
			       struct drm_plane_state *plane_state)
{
	struct mipi_dbi_dev *dbidev = drm_to_mipi_dbi_dev(pipe->crtc.dev);
	struct mipi_dbi *dbi = &dbidev->dbi;
	u8 addr_mode;
	int idx;
	int ret;

	if (!drm_dev_enter(pipe->crtc.dev, &idx))
		return;

	gc9a01_hw_reset(dbi);

	ret = gc9a01_send_init_sequence(dbi);
	if (ret) {
		DRM_DEV_ERROR(pipe->crtc.dev->dev,
			      "Failed to send init sequence (%d)\n", ret);
		goto out_exit;
	}

	switch (dbidev->rotation) {
	default:
		addr_mode = GC9A01_MADCTL_MX | GC9A01_MADCTL_BGR;
		break;
	case 90:
		addr_mode = GC9A01_MADCTL_MV | GC9A01_MADCTL_BGR;
		break;
	case 180:
		addr_mode = GC9A01_MADCTL_MY | GC9A01_MADCTL_BGR;
		break;
	case 270:
		addr_mode = GC9A01_MADCTL_MX | GC9A01_MADCTL_MY |
			    GC9A01_MADCTL_MV | GC9A01_MADCTL_BGR;
		break;
	}

	mipi_dbi_command(dbi, MIPI_DCS_SET_ADDRESS_MODE, addr_mode);
	msleep(120);
	mipi_dbi_command(dbi, MIPI_DCS_EXIT_SLEEP_MODE);
	msleep(120);
	mipi_dbi_command(dbi, MIPI_DCS_SET_DISPLAY_ON);
	if (test_pattern) {
		ret = gc9a01_show_test_pattern(dbidev);
		if (ret)
			DRM_DEV_ERROR(pipe->crtc.dev->dev,
				      "Failed to show test pattern (%d)\n", ret);
		backlight_enable(dbidev->backlight);
		goto out_exit;
	}
	mipi_dbi_enable_flush(dbidev, crtc_state, plane_state);

out_exit:
	drm_dev_exit(idx);
}

static void gc9a01_pipe_update(struct drm_simple_display_pipe *pipe,
			       struct drm_plane_state *old_state)
{
	dev_info_ratelimited(pipe->crtc.dev->dev, "pipe update\n");
	mipi_dbi_pipe_update(pipe, old_state);
}

static const struct drm_simple_display_pipe_funcs gc9a01_pipe_funcs = {
	.enable		= gc9a01_pipe_enable,
	.disable	= mipi_dbi_pipe_disable,
	.update		= gc9a01_pipe_update,
	.prepare_fb	= drm_gem_fb_simple_display_pipe_prepare_fb,
};

static const struct gc9a01_cfg gc9a01_boe_128_cfg = {
	.mode		= { DRM_SIMPLE_MODE(240, 240, 32, 32) },
	.width_mm	= 32,
	.height_mm	= 32,
};

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

	dbidev->backlight = devm_of_find_backlight(dev);
	if (IS_ERR(dbidev->backlight))
		return PTR_ERR(dbidev->backlight);

	device_property_read_u32(dev, "rotation", &rotation);

	ret = dma_coerce_mask_and_coherent(dev, DMA_BIT_MASK(64));
	if (ret) {
		ret = dma_coerce_mask_and_coherent(dev, DMA_BIT_MASK(32));
		if (ret)
			return dev_err_probe(dev, ret,
					     "Failed to set DMA mask\n");
	}

	ret = mipi_dbi_spi_init(spi, dbi, dc);
	if (ret)
		return ret;

	/*
	 * The reference bit-banged code writes RGB565 as two 8-bit transfers,
	 * MSB first. Force the MIPI DBI helper down that path instead of using
	 * 16-bit SPI words whose byte order depends on the SPI controller.
	 */
	dbi->swap_bytes = true;
	dbi->read_commands = NULL;

	ret = mipi_dbi_dev_init(dbidev, &gc9a01_pipe_funcs, &cfg->mode,
				rotation);
	if (ret)
		return ret;

	drm_mode_config_reset(drm);

	ret = drm_dev_register(drm, 0);
	if (ret)
		return ret;

	spi_set_drvdata(spi, drm);
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
MODULE_AUTHOR("SOPHGO");
MODULE_LICENSE("GPL");
