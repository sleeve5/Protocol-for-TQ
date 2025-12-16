## 1. Receiver (接收主控函数)

这是一份关于 **Proximity-1 协议接收端（Receiver Function）** 数据处理流程的详细技术报告。

基于代码 `receiver.m`（及其依赖的 `ldpc_decoder`、`frame_synchronizer`），数据经历了与发送端严格逆向的三个核心阶段：**物理层同步（Synchronization）** $\to$ **信道译码（Decoding）** $\to$ **帧提取（Frame Extraction）**。

下面分层剖析接收端如何从噪声中还原数据。

---

### 第一阶段：物理层同步与提取 (Physical Layer Synchronization)

这一层处理的是物理层解调后的**软信息流（LLR）**。它的目标是在茫茫噪声中找到 LDPC 码块的边界。

#### 1. 输入

- **Soft LLR Stream**：来自物理层解调器的对数似然比序列。
- 特性：连续、无边界、可能包含前导捕获序列或噪声。

#### 2. 操作

1. **CSM 搜索 (Frame Sync)**：使用滑动相关器搜索 **64 bits CSM** (`0x0347...`)。
2. **锁定与截取**：一旦锁定 CSM 位置，按照固定块长截取数据。
3. **块分割**：丢弃 CSM，提取出 **2048 bits** 的 LDPC 待译码数据。

#### 3. 输出结构：LDPC 编码块

```text
[ ... Noise ... ] | CSM (64) | Coded Bits (2048) | CSM (64) | ...
                  ^ 锁定点    ^ 截取点
```

---

### 第二阶段：LDPC 信道译码层 (Channel Decoding)

这一层负责消除信道噪声带来的误码，将物理层符号还原为逻辑比特流。这是 `ldpc_decoder` 的核心工作。

#### 1. 输入

- **Coded Bits**：2048 bits 的软信息（含噪声）。

#### 2. 操作 (逆向处理)

1. **去随机化 (De-randomization)**：
   - 利用相同的伪随机序列对输入 LLR 进行符号翻转（Soft XOR）。
2. **逆打孔 (Depuncturing)**：
   - 发送端丢弃了最后 512 bits。
   - 接收端重建 2560 bits 向量，将对应打孔位置的 LLR 设为 **0** (表示 Erasure/不确定)。
3. **LDPC 译码**：
   - 使用置信传播算法 (BP) 进行迭代译码。
   - 输出：**1024 bits** 的纯净信息块。

#### 3. 输出结构：比特流片段 (Bitstream Chunk)

译码成功后，输出的是 **1024 bits** 的无误码逻辑比特流。多个块拼接后形成连续的数据链路层比特流。

---

### 第三阶段：链路层帧提取 (Link Layer Extraction)

这一层负责从连续的比特流中“抠”出变长的传送帧。

#### 1. 输入

- **Decoded Bitstream**：由多个 LDPC 信息块拼接而成的长比特流。

#### 2. 操作

1. **ASM 搜索**：在流中寻找 24 位 **ASM** (`0xFAF320`)。
2. **滑动 CRC 校验 (Sliding CRC Check)**：
   - 由于接收端预先不知道 $L_{frame}$，且数据流中包含空闲填充。
   - **策略**：从 ASM 之后开始，假设不同的长度 $L$（步长 8 bits），截取数据并计算 CRC。
   - **判决**：若 CRC 校验通过，则认定找到了帧的结束边界。
3. **剥离**：去除 ASM 和 CRC-32。

#### 3. 输出：Transfer Frame

成功提取出的用户数据：$L_{frame}$ bits。

---

### 总结：接收效率与信噪比

假设接收到的信噪比为 $E_b/N_0 = 4.0 \text{dB}$：

#### 关键性能指标

| 指标        | 表现   | 说明                                                         |
|:--------- |:---- |:---------------------------------------------------------- |
| **同步灵敏度** | 高    | CSM (64 bits) 具有极强的自相关性，可在低信噪比下锁定。                         |
| **纠错能力**  | 强    | LDPC (Rate 1/2) 可纠正约 5-8% 的比特翻转错误，实现 **Post-FEC BER = 0**。 |
| **帧提取率**  | 100% | 只要 LDPC 译码正确，滑动 CRC 算法能 100% 精准定位变长帧。                      |

---

## 2. ProximityReceiver (流式状态机)

这是一份关于 **Proximity-1 基于状态机的流式接收机 (`ProximityReceiver` Class)** 的设计技术报告。

该模块是为了解决**工程化实现（Engineering Implementation）**中的数据碎片化与实时处理问题而设计的。与批处理函数 `receiver` 不同，本模块模拟了真实的硬件/SDR 行为。

---

### 核心架构：双缓冲分层状态机 (Dual-Buffer Hierarchical FSM)

接收机内部维护两个独立的缓冲区和两层状态机，以解耦物理层与链路层的速率差异。

#### 1. 第一层：物理层 FSM (PHY Layer FSM)

负责处理输入的 LLR 碎片，组装 LDPC 码块。

- **输入**：任意长度的 LLR 片段 (Chunk)。
- **缓冲区**：`PhyBuffer` (存储软信息)。
- **状态流转**：
  1. **`SEARCH_CSM`**：在 `PhyBuffer` 中滑动搜索 CSM。锁定后，丢弃头部无效数据，转入下一状态。
  2. **`ACCUMULATE_BLOCK`**：等待缓冲区积累满 **2048** 个数据点。满足条件后，提取数据送入译码器，并切回搜索状态。

#### 2. 中间处理：单块译码

当物理层 FSM 输出一个完整块时，立即触发：
`De-randomize` $\to$ `De-puncture` $\to$ `LDPC Decode` $\to$ **输出 1024 bits**。

#### 3. 第二层：链路层处理器 (Link Layer Processor)

负责处理译码后的比特流，提取传送帧。

- **输入**：来自译码器的 1024 bits 数据块。
- **缓冲区**：`LinkBuffer` (存储逻辑比特 0/1)。
- **处理逻辑**：
  1. **ASM 定位**：在 `LinkBuffer` 头部搜索 ASM。
  2. **滑动提取**：尝试匹配 CRC。
     - **匹配成功**：提取帧，从缓冲区移除该帧数据（含ASM/CRC）。
     - **匹配失败**：保留数据，等待下一次译码结果拼接到缓冲区末尾（处理跨块长帧）。

---

### 数据流转动态视图

假设发送了一个跨越 LDPC 边界的长帧：

| 时间步 (Time Step) | 输入 (Input)  | 物理层状态 (PHY State)              | 链路层缓冲 (LinkBuffer) | 输出 (Output)          |
|:--------------- |:----------- |:------------------------------ |:------------------ |:-------------------- |
| **T1**          | LLR Chunk 1 | SEARCH $\to$ ACCUMULATE        | `[Empty]`          | -                    |
| **T2**          | LLR Chunk 2 | ACCUMULATE (Full) $\to$ Decode | `[前半帧数据...]`       | -                    |
| **T3**          | LLR Chunk 3 | ACCUMULATE                     | `[前半帧数据...]`       | -                    |
| **T4**          | LLR Chunk 4 | ACCUMULATE (Full) $\to$ Decode | `[前半帧... + 后半帧]`   | **Frame Extracted!** |

### 关键特性总结

1. **流式处理 (Streaming)**：支持任意粒度的输入（如每次 1 bit 或 1000 bits），无需预先知道数据总量。
2. **内存管理 (Memory Management)**：
   - `PhyBuffer`：自动丢弃未同步的噪声数据。
   - `LinkBuffer`：帧提取后自动释放内存。
3. **鲁棒性 (Robustness)**：
   - 能处理**帧间空闲 (Inter-frame Gap)**。
   - 能处理**跨块传输 (Split Blocks)**。
   - 能利用 CRC 校验过滤掉 payload 中出现的**伪造 ASM**。

此模块是实现**软件无线电 (SDR)** 实时接收机的基础原型。
