# RK3588 + BM1684X EP 视频检测 Demo

## 项目定位

使用 AI 辅助完成的端侧视频检测 Demo，包含 PCIe 加速设备、视频处理、模型推理、HDMI 展示和性能观测。通过逐项学习将可运行功能转化为能解释、验证和维护的能力。

- 源码：[XingTunAI/1684X-EP-demo](https://github.com/XingTunAI/1684X-EP-demo)
- 本机：`C:\QIU\Develop_Recoder\1684X-EP-demo`
- 本目录只保存开发记录，不复制源码。

## 阅读链路

```text
Python 启动脚本 → C++ 工作进程
视频 → 解码 → 预处理 → bmodel 推理 → 检测后处理 → 预览 / HDMI
                         运行统计与日志
```

这是一张阅读地图。各阶段在哪个设备执行、哪些数据经过 PCIe、显示与推理是否处理相同数量的帧，需要结合源码核实。

| 内容 | 源码仓库内入口 | 阅读目标 |
| --- | --- | --- |
| 环境 | `README.md`、`docs/setup.md` | 主机、加速卡、驱动、SDK、模型与数据 |
| 单卡启动 | `demos/hdmi_wall/run.py` | 参数、命令、日志、进程退出 |
| 数据链路 | `demos/hdmi_wall/main.cpp` | 一帧图像与资源释放 |
| 检测器 | `demos/hdmi_wall/detector/yolov8_det.cpp` | 模型输入输出及坐标还原 |
| 多卡 | `demos/hdmi_wall/multi_run.py` | 单卡理解后学习设备分配 |

## 验证基线

此前本机单卡、多卡、YOLOv8 启动脚本 dry-run 已运行，只证明能生成执行计划，不代表硬件链路正常。pytest 当时因未安装而未运行成功。

仓库记录的 32 路 × 24 FPS 目标和 4 小时稳定性不能写作已完成。新结论需注明版本和真机证据。

- [ ] 记录硬件、SDK、模型、视频和源码版本。
- [ ] 完成单卡单路运行并保留命令与结果。
- [ ] 分清解码、推理、显示 FPS 和统计时间。
- [ ] 完成一个单变量性能实验。

基础学习按 [Core_Technologies 学习入口](../learning-plan.md)推进。这里在实际遇到工作问题时创建 `issues/日期-现象.md`，使用[问题模板](../../templates/debug_record_template.md)，记录版本、证据、修复与回归。
