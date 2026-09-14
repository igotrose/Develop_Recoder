# Develop Recorder

工作开发记录：保存实际问题、环境、排查证据、修复和回归验证。

## 目录

```text
Develop_Recoder/
  Rockchip/             # 厂商 → 芯片/平台 → 驱动问题
  Sophgo/
  Espressif/
  HiChip/
  ChinaMobile/
  Puya/
  Projects/             # 跨模块应用项目与联调问题
    voice-lab-esp32/
    1684x-ep-demo/
  templates/            # 工作记录模板
```

## 厂商与平台

原目录和历史记录保持原位，继续沿用各平台现有结构。

- [Rockchip](Rockchip/)
- [Sophgo](Sophgo/)
- [Espressif](Espressif/)
- [HiChip](HiChip/)
- [ChinaMobile](ChinaMobile/)
- [Puya](Puya/)

## 项目

- [项目索引与归档规则](Projects/README.md)
- [Voice Lab ESP32](Projects/voice-lab-esp32/README.md)
- [RK3588 + BM1684X 视频检测](Projects/1684x-ep-demo/README.md)

## 记录放哪里

| 内容 | 位置 |
| --- | --- |
| I2S、DMA、Codec、设备树、PCIe 枚举等平台问题 | 对应厂商目录 |
| 录音状态、网络重连、接口联调、多路检测性能 | Projects 对应项目 |
| C++、PCM、量化等原理和独立练习 | [Core_Technologies](https://github.com/igotrose/Core_Technologies) |

跨目录的问题只存一份主记录，其他位置链接引用。已有记录不为统一命名而批量搬迁。

## 写一篇工作记录

1. 写清现象、复现步骤与影响。
2. 记录板卡、SDK、源码提交、配置及未提交修改。
3. 保存脱敏日志、排查过程和根因证据。
4. 写明修复、正常/异常回归结果与适用范围。

新问题建议命名为 YYYY-MM-DD-问题简称.md。项目源码、模型和安装包在各自源码/资产位置维护，不因记录而复制整套项目。

## 模板与基础学习

- [问题排查模板](templates/debug_record_template.md)
- [项目记录模板](templates/ai_app_record_template.md)
- [项目复盘模板](templates/project_review_template.md)
- [基础学习入口](Projects/learning-plan.md)
