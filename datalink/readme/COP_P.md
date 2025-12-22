# Proximity-1 通信操作过程 (COP-P)

**对应文件**：`FOP_Process.m` (类), `FARM_Process.m` (类), `build_PLCW.m`, `parse_PLCW.m`

## 1. 概述

本模块实现了 Proximity-1 协议中的 **COP-P (Communication Operations Procedure - Proximity)**。它是保证数据链路层可靠传输（Sequence Controlled Service）的核心机制，通过 **Go-Back-N** 策略实现自动重传请求 (ARQ)。

系统由发送端的 **FOP-P** 和接收端的 **FARM-P** 两个异步状态机组成。

## 2. 发送端控制：FOP-P (Frame Operation Procedure)

`FOP_Process.m` 类维护发送端的序列状态和重传队列。

### 核心状态变量

* **`V(S)`**：下一个待发送帧的序列号。
* **`NN(R)`**：接收端已确认收到的序列号（ACK）。
* **`Sent_Queue`**：发送窗口缓冲区，保存已发送但未确认的帧。

### 工作逻辑

1. **发送新帧**：分配 `V(S)`，组装帧，存入 `Sent_Queue`，`V(S)++`。
2. **处理 ACK**：接收 PLCW，根据 `Report Value` 清除队列中已确认的帧。
3. **处理 NACK (重传)**：若 PLCW 中 `Retransmit Flag = 1`，则暂停新数据发送，将指针回退到最早未确认的帧，启动 **Go-Back-N** 重传。

关于 **SYNCH_TIMER** 的实现：
为了解决反向链路丢包导致的死锁问题，FOP-P 维护了一个递减计数器。当发送队列非空且长时间未收到 ACK 时，计时器归零触发 TimeOut 事件，强制 FOP-P 进入重传模式。该机制保证了协议在双向信道均不稳定的情况下仍具有自愈能力。


## 3. 接收端控制：FARM-P (Frame Acceptance and Reporting Mechanism)

`FARM_Process.m` 类负责接收端的帧过滤、排序和反馈生成。

### 核心状态变量

* **`V(R)`**：期望接收的下一个帧序列号。

### 状态机逻辑

* **Match (匹配)**：收到帧 `Seq == V(R)` $\to$ **接收**，`V(R)++`。
* **Gap (丢帧)**：收到帧 `Seq > V(R)` $\to$ **拒收**，丢弃数据，置位重传标志。
* **Duplicate (重复)**：收到帧 `Seq < V(R)` $\to$ **拒收** (视为重复帧)，丢弃数据，发送当前 `V(R)` 确认。

## 4. 控制字：PLCW (Proximity Link Control Word)

`build_PLCW.m` 和 `parse_PLCW.m` 负责处理反向链路的控制信息。

### 结构定义 (Annex B)

PLCW 是一个固定长度的 SPDU (16 bits)，结构如下：

| 字段                  | 长度     | 说明                         |
|:------------------- |:------ |:-------------------------- |
| **Format / Type**   | 2 bits | 标识这是一个 PLCW                |
| **Retransmit Flag** | 1 bit  | `1` = 请求发送端重传 (NACK)       |
| **PCID**            | 1 bit  | 物理信道 ID                    |
| **Expedited Cnt**   | 3 bits | 加速帧计数                      |
| **Report Value**    | 8 bits | 当前的 `V(R)` 值，告知发送方“我想要这一帧” |

## 5. 闭环工作流

1. **Alice (FOP)** 发送 `Seq=0, 1, 2`。
2. **Channel** 丢失 `Seq=1`。
3. **Bob (FARM)** 收到 `Seq=0` (收)，收到 `Seq=2` (拒，发现丢帧)。
4. **Bob** 生成 PLCW: `Report=1`, `Retransmit=1`。
5. **Alice** 解析 PLCW，回退指针，重传 `Seq=1, 2`。
6. **Bob** 收到 `Seq=1` (收)，收到 `Seq=2` (收)。通信恢复。
