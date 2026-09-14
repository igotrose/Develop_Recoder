# AI 应用开发记录

这个目录记录工作项目背景、实际遇到的问题、排查与修复验证。基础能力学习统一记录在 Core_Technologies。

## 项目入口与学习进度

- [Voice Lab + 小智 ESP32](2026-09-esp32-audio-platform/README.md)：团队项目，主要负责 ESP 端，开发主要借助 AI。
- [RK3588 + BM1684X 视频 Demo](1684x-ep-demo/README.md)：AI 辅助完成的项目，逐步补齐理解和验证能力。
- [Core_Technologies 学习入口](learning-plan.md)：两条详细路线在基础知识仓库维护。
- [学习验证记录模板](../templates/learning_record_template.md)

区分“代码存在”“编译通过”“真机验证”“能独立解释”。每次记录源码目录、提交、未提交修改、硬件与 SDK 版本。AI 解释先作为待核实内容，以源码与实验为依据。源码在原仓库维护，这里只保存记录与必要片段。不要记录凭据、密钥或未经脱敏的现场录音。

## 推荐目录结构

```text
01_AI_Application/
  README.md
  2026-09-esp32-audio-platform/
    README.md
    api.md
    protocol.md
    debug.md
    deploy.md
    review.md
```

## 当前重点

- ESP32 录音播放接入平台
- 音频上传和播放
- 平台 API
- 当前采集与 ASR 链路；LLM / TTS 是否接入须另行核实
- 板端和服务端联调

## 记录方式

每个项目建议至少保留这些文件：

- `README.md`：项目目标、架构、当前状态
- `api.md`：接口定义和请求响应示例
- `protocol.md`：设备和平台之间的通信协议
- `debug.md`：问题排查记录
- `deploy.md`：部署步骤
- `review.md`：项目复盘
