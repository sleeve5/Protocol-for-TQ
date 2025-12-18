# Proximity-1 定时业务说明 (Timing Services)

**对应文件**：`test_timing_service.m`, `MAC_Controller.m`, `scs_transmitter_timing.m`, `receiver_timing.m`, `Proximity1Receiver_timing.m`

## 1. 概述

定时业务 (Timing Services) 是 Proximity-1 协议支持高精度测距和时间相关的基础。本系统实现了 **ASM 时间标签 (Time Tagging)** 功能，符合 **CCSDS 211.0-B-6 Section 5** 标准。

## 2. 原理与实现

### 2.1 定义

* **Egress Time (发射时间)**: 传送帧 ASM 字段最后一个比特离开发送端物理层接口的时刻。
* **Ingress Time (接收时间)**: 传送帧 ASM 字段最后一个比特到达接收端物理层接口的时刻。

### 2.2 实现逻辑

1. **物理层抽象**：由于仿真基于比特流，我们使用 **逻辑位索引 (Bit Index)** 结合 **数据符号率 (Symbol Rate)** 来计算时间。
   $$ T = T_{start} + \frac{\text{BitIndex}}{\text{DataRate}} $$
2. **MAC 层捕获**：
   * 发送端：在 `scs_transmitter` 组帧时记录 ASM 结束位置，上报给 MAC 的 `SENT_TIME_BUFFER`。
   * 接收端：在 `receiver` 成功校验 CRC 后，根据 ASM 索引计算到达时间，上报给 MAC 的 `RECEIVE_TIME_BUFFER`。
3. **耦合关系**：时间标签与帧序列号 (`SeqNo`) 绑定，确保时间数据的可追溯性。

## 3. 验证结果

在仿真中引入 **1.5秒** 的物理延迟，测试结果如下：

| SeqNo | Egress (s) | Ingress (s) | Diff (s) | 结论     |
|:----- |:---------- |:----------- |:-------- |:------ |
| 0     | 0.000760   | 1.500760    | 1.500000 | ✅ 精确匹配 |
| 1     | 0.005560   | 1.505560    | 1.500000 | ✅ 精确匹配 |

**结论**：系统成功实现了基于协议层的 OWLT (单向光行时) 测量功能。
