# Voice Lab 语音项目：ESP 端开发记录

## 项目与参与范围

这是 Voice Lab 平台与基于小智改造的 ESP32 固件组成的团队项目。我是成员，主要负责 ESP 部分，开发主要借助 AI。平台实现不计为我的独立开发成果；设备端掌握程度以代码追踪和真机验证为准。

- 平台：[XingTunAI/voice-lab](https://github.com/XingTunAI/voice-lab)
- 固件：[igotrose/xiaozhi-esp32](https://github.com/igotrose/xiaozhi-esp32)
- 上游：[78/xiaozhi-esp32](https://github.com/78/xiaozhi-esp32)
- 本机平台：`C:\QIU\XingTunAI\voice-lab`
- 本机固件：`C:\QIU\XingTunAI\voice-lab-adapter\xiaozhi-esp32`

本地固件有多个远端，平台仓库内也包含微雪固件源码。每次记录实际构建目录、分支和提交，不默认本地等于远端最新版本。

## 项目目标

学习与维护 ESP 设备的采集、上传、录音控制、播放及平台联调。平台承担音频处理、ASR 与结果留档；具体完成状态以真机证据为准。

## 当前主链路

```text
ESP32 录音
  -> 上传音频到平台
  -> 平台处理
  -> 返回音频/结果
  -> ESP32 播放
```

## 拓展链路（不是已完成状态）

```text
ESP32
  -> Audio Upload
  -> ASR
  -> LLM
  -> TTS
  -> Audio Response
  -> Playback
```

## 需要关注的问题

- 音频采样率、位深、通道数
- 音频编码格式
- 上传协议
- 超时和重试
- 服务端接口定义
- 平台返回音频的格式
- 播放延迟
- 设备断网和重连
- 日志和错误码

## 文档

- [分阶段基础学习计划](../learning-plan.md)
- [基础笔记模板（Core_Technologies）](https://github.com/igotrose/Core_Technologies/blob/main/templates/foundation-note.md)

- [接口定义](api.md)
- [设备通信协议](protocol.md)
- [问题排查](debug.md)
- [部署记录](deploy.md)
- [项目复盘](review.md)

## 源码阅读入口

以下路径相对于固件仓库。按问题追踪，不必一次读完文件。

| 关注点 | 文件 | 要回答的问题 |
| --- | --- | --- |
| 板级音频 | `main/boards/waveshare/esp32-s3-audio-board/config.h`、`esp32-s3-audio_board.cc` | 引脚、Codec、按键怎样初始化？ |
| 音频服务 | `main/audio/audio_service.cc`、`audio_codec.cc` | PCM 从哪里来，谁消费？ |
| 应用调度 | `main/application.cc` | 按键和网络事件怎样触发录音？ |
| 平台适配 | `main/voice_lab_client.cc`、`.h` | 控制消息与音频数据如何发送？ |
| 可靠性 | `main/voice_lab_pcm_buffer.h`、`voice_lab_recording_guard.h`、`voice_lab_recording_lease.h` | 缓存、授权和录音何时结束？ |

平台侧先只追踪 `src/voice_lab/api.py`、`service.py`、`device_recording.py`，结合 `docs/API.md` 核实消息合同。

## 验证基线

工作记录入口：[问题索引](issues/README.md)。归档遵循[项目规则](../README.md)，平台相关问题留在厂商目录。

2026-09-14 本地阅读发现 `voice_lab_client.h` 有配对、录音、PCM、播放、ACK 和租约等接口与状态。本次没有构建或真机验收，这些不是已验证结论。前面的 LLM / TTS 链路仅作拓展示意，不能从小智上游功能推断本适配已经接通。

- [ ] 确认当前设备固件来源与 SDK 版本。
- [ ] 关联一次录音的设备日志、平台记录和音频。
- [ ] 验证尾音、断网重连、连续按键与播放。
- [ ] 能独立解释一帧 PCM 的路径。

实际工作问题创建 `issues/日期-现象.md`。基础学习与练习放在 Core_Technologies，见学习入口。现有接口、协议等页面作为待补充记录，不表示验收完成。
