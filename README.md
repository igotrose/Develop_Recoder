# Develop Recorder

这个仓库用于记录开发过程中的问题排查、项目交付、调试方法和可复用经验。

当前主线有两条：

1. 嵌入式底层/BSP/驱动开发经验沉淀
2. AI 应用开发项目记录

## 目录

### AI 应用开发

- [AI 应用开发记录入口](01_AI_Application/README.md)
- [项目基础学习计划](01_AI_Application/learning-plan.md)

### 嵌入式开发记录

- [Rockchip](Rockchip/)
- [Sophgo](Sophgo/)
- [Espressif](Espressif/)
- [HiChip](HiChip/)
- [ChinaMobile](ChinaMobile/)
- [Puya](Puya/)

### 模板

- [问题排查记录模板](templates/debug_record_template.md)
- [项目复盘模板](templates/project_review_template.md)
- [AI 应用开发记录模板](templates/ai_app_record_template.md)

## 记录原则

每一篇记录尽量回答 6 个问题：

1. 这次要解决什么问题？
2. 环境和约束是什么？
3. 我尝试过哪些方案？
4. 最终有效的方案是什么？
5. 如何验证结果？
6. 下次遇到类似问题，最快怎么处理？

## 记录建议

- 驱动/BSP 问题：保留硬件信息、DTS、内核配置、日志、示波器/原理图证据、最终补丁。
- AI 应用问题：保留接口协议、数据流、模型调用方式、部署方式、异常处理、端到端验证。
- 每个项目结束后写一篇复盘，把“做成了什么”和“学会了什么”分开记录。
