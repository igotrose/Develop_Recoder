# 项目开发记录

按具体项目记录跨模块问题、联调、部署与验证。厂商相关驱动问题仍归原厂商目录；基础学习归 Core_Technologies。

## 当前项目

| 项目 | 工作范围 | 问题索引 | 相关厂商 |
| --- | --- | --- | --- |
| [Voice Lab ESP32](voice-lab-esp32/README.md) | 团队项目，主要负责 ESP 设备端 | [问题记录](voice-lab-esp32/issues/README.md) | [Espressif](../Espressif/) |
| [视频检测 Demo](1684x-ep-demo/README.md) | RK3588 + BM1684X 视频处理、推理和展示 | [问题记录](1684x-ep-demo/issues/README.md) | [Rockchip](../Rockchip/)、[Sophgo](../Sophgo/) |

## 新项目怎么建

只创建 README.md 与有内容的记录；接口、部署、复盘有实际材料时再补。现有占位文档明确标待补充，不当作完成结果。

```text
Projects/项目名/
  README.md                 # 背景、职责、环境、记录导航
  issues/
    README.md               # 已发生问题索引
    YYYY-MM-DD-问题简称.md
  api.md                    # 按需
  protocol.md               # 按需
  deploy.md                 # 按需
  review.md                 # 按需
```

## 归档判断

- 芯片/外设驱动问题：写到厂商目录，在项目问题索引放链接。
- 应用状态、数据链路、协议或联调问题：写到项目 issues/。
- 原理与学习实验：写到 [Core_Technologies](https://github.com/igotrose/Core_Technologies)，项目记录只引用相关基础。

不把设想的问题预填成真实故障，不重复复制同一记录。区分代码存在、编译通过、真机验证和推测。

[工作问题模板](../templates/debug_record_template.md) · [基础学习入口](learning-plan.md) · [返回首页](../README.md)
