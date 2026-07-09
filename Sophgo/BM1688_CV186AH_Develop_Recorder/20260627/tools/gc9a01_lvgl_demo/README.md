# GC9A01 LVGL demo

This is a tiny LVGL 9 framebuffer demo for the GC9A01 DRM fbdev node.

Build:

```sh
make -C tools/gc9a01_lvgl_demo
```

Install the binary into the rootfs overlay:

```sh
make -C tools/gc9a01_lvgl_demo install
```

Run on the board:

```sh
/usr/sbin/gc9a01_lvgl_demo /dev/fb0
```
