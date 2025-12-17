# Proximity-1 传送帧结构说明 (Framing)

**对应文件**：`frame_generator.m`, `frame_parser.m`, `build_PLTU.m`

## 1. 概述

本模块负责 **数据链路层 (Data Link Layer)** 的帧封装与解封装。它实现了 **Proximity-1 Version-3 Transfer Frame** 的构建规则，定义了帧头（Header）中各个控制字段的位映射关系。

## 2. Version-3 传送帧结构

根据标准 **CCSDS 211.0-B-6 (Section 3.2)**，本工程实现的帧结构如下：

| 组成部分        | 长度 (Bits) | 说明                    |
|:----------- |:--------- |:--------------------- |
| **Header**  | 40        | 固定长度帧头，包含路由与控制信息      |
| **Payload** | Variable  | 用户数据域 (最大 2043 字节)    |
| **CRC-32**  | 32        | 循环冗余校验 (在 CSS 层计算并附加) |

### 2.1 帧头字段映射 (Header Mapping)

`frame_generator.m` 与 `frame_parser.m` 严格遵循以下位序（MSB First）：

| Bit 索引 | 字段名             | 值/类型          | 作用                                 |
|:------ |:--------------- |:------------- |:---------------------------------- |
| 0-1    | **Version**     | `10` (Binary) | 标识 Version-3 协议                    |
| 2      | **QoS**         | `0`/`1`       | `0`: 序列控制 (可靠), `1`: 加速 (不可靠)      |
| 3      | **PDU Type**    | `0`/`1`       | `0`: 用户数据, `1`: 协议控制信息(PLCW)       |
| 4-5    | **DFC ID**      | `11`          | 数据域构造标识 (本工程默认 User Defined)       |
| 6-15   | **SCID**        | 10 bits       | 航天器 ID (Spacecraft Identifier)     |
| 16     | **PCID**        | 1 bit         | 物理信道 ID                            |
| 17-19  | **Port ID**     | 3 bits        | 逻辑端口号 (0-7)                        |
| 20     | **Source/Dest** | 1 bit         | `0`: 源 ID, `1`: 目的 ID              |
| 21-31  | **Length**      | 11 bits       | 帧长计数 $C = \text{Total Octets} - 1$ |
| 32-39  | **Seq No**      | 8 bits        | 帧序列号 (用于 ARQ 重传排序)                 |

## 3. 关键函数说明

### `frame_generator.m`

* **功能**：组装帧。
* **逻辑**：接收用户 Payload 和配置结构体，计算帧长，按位拼接 Header，最后输出 `logical` 类型的比特流。
* **注意**：自动处理了 `de2bi` 的 double 类型转换问题，确保输出为纯逻辑向量。

### `frame_parser.m`

* **功能**：解帧。
* **逻辑**：接收来自 `receiver` 的比特流，截取前 40 bits 解析为 Header 结构体，并根据 Header 中的 Length 字段精确提取 Payload，剥离填充数据。

### `build_PLTU.m`

* **功能**：CSS 层封装。
* **逻辑**：`ASM (24 bits) + Transfer Frame + CRC (32 bits)`。此函数连接了帧子层与编码子层。
