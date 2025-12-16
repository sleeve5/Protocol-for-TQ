%% Proximity-1 COP-P (ARQ) 自动重传闭环测试
% 演示: FOP-P (发送) <--> Channel (丢包) <--> FARM-P (接收)
clc; clear; close all;
addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('================================================\n');
fprintf('    COP-P (ARQ) 序列控制服务闭环演示\n');
fprintf('================================================\n');

% 1. 初始化
pcid = 0;
sender = FOP_Process(pcid);
receiver = FARM_Process(pcid);

% 定义一个简单的 Payload 生成函数 (模拟用户数据)
gen_payload = @(id) de2bi(id, 8, 'left-msb'); % 简单的 1 字节数据

fprintf('[Init] Sender V(S)=0, Receiver V(R)=0\n');

%% --- 第一幕: 正常发送 Frame 0 ---
fprintf('\n>>> [Step 1] 发送 Frame 0 (正常) <<<\n');

% 1. 发送端生成
payload0 = gen_payload(100); % 数据内容 100
[tx_frame0, seq0] = sender.prepare_frame(payload0, @frame_generator);
fprintf('    [Tx] 发送 Seq %d (Payload: 100)\n', seq0);

% 2. 理想信道传输
rx_header0 = get_header_info(tx_frame0); % 辅助函数提取头

% 3. 接收端处理
[accept, need_plcw] = receiver.process_frame(rx_header0);

if accept
    fprintf('    [Rx] 接收 Seq %d 成功! V(R) -> %d\n', rx_header0.SeqNo, receiver.V_R);
else
    fprintf('    [Rx] 接收 Seq %d 失败!\n', rx_header0.SeqNo);
end

% 4. 接收端发回 ACK (PLCW)
plcw_bits = receiver.get_PLCW();
sender.process_PLCW(plcw_bits); % 发送端处理 ACK
% 此时发送端的 NN(R) 应该更新为 1，队列中清除 Frame 0


%% --- 第二幕: 发送 Frame 1 但丢包 ---
fprintf('\n>>> [Step 2] 发送 Frame 1 (模拟信道丢包) <<<\n');

payload1 = gen_payload(101);
[tx_frame1, seq1] = sender.prepare_frame(payload1, @frame_generator);
fprintf('    [Tx] 发送 Seq %d (Payload: 101)\n', seq1);

fprintf('    [Channel] ⚠️ 警告: Frame 1 在传输途中丢失！\n');
% 接收端什么都没收到，状态不变


%% --- 第三幕: 发送 Frame 2 (触发乱序报警) ---
fprintf('\n>>> [Step 3] 发送 Frame 2 (导致接收端发现跳号) <<<\n');

payload2 = gen_payload(102);
[tx_frame2, seq2] = sender.prepare_frame(payload2, @frame_generator);
fprintf('    [Tx] 发送 Seq %d (Payload: 102)\n', seq2);

% 接收端收到 Frame 2
rx_header2 = get_header_info(tx_frame2);
[accept, need_plcw] = receiver.process_frame(rx_header2);

if ~accept
    fprintf('    [Rx] ❌ 拒绝 Seq %d! (期望 V(R)=%d). 发现丢包!\n', ...
        rx_header2.SeqNo, receiver.V_R);
else
    error('错误: 接收端应该拒绝乱序帧');
end

% 接收端生成 报警 PLCW
plcw_bits_nack = receiver.get_PLCW();
plcw_info = parse_PLCW(plcw_bits_nack);
fprintf('    [Rx -> Tx] 发送 PLCW: Report V(R)=%d, Retransmit=%d\n', ...
    plcw_info.Report_Value, plcw_info.RetransmitFlag);


%% --- 第四幕: 发送端处理报警并重传 ---
fprintf('\n>>> [Step 4] 发送端处理 NACK 并启动重传 <<<\n');

% 发送端收到 NACK
sender.process_PLCW(plcw_bits_nack);

if sender.Resending
    fprintf('    [Tx] 进入重传模式 (Go-Back-N)\n');
end

% 发送端下一次 prepare_frame 应该自动取出 Frame 1 (旧的)
[tx_frame_retry1, seq_retry1] = sender.prepare_frame([], @frame_generator);
fprintf('    [Tx Resend] 重发 Seq %d (应为 1)\n', seq_retry1);

% 验证接收端处理 Frame 1
rx_header_retry1 = get_header_info(tx_frame_retry1);
[accept, ~] = receiver.process_frame(rx_header_retry1);

if accept
    fprintf('    [Rx] ✅ 终于收到了 Seq %d! V(R) -> %d\n', seq_retry1, receiver.V_R);
end


%% --- 第五幕: 继续重传后续帧 ---
fprintf('\n>>> [Step 5] 发送端继续重传后续帧 (Frame 2) <<<\n');

% 因为是 Go-Back-N，发送端必须把 1 之后的所有帧(即Frame 2)也重发一遍
[tx_frame_retry2, seq_retry2] = sender.prepare_frame([], @frame_generator);
fprintf('    [Tx Resend] 重发 Seq %d (应为 2)\n', seq_retry2);

% 验证接收端处理 Frame 2
rx_header_retry2 = get_header_info(tx_frame_retry2);
[accept, ~] = receiver.process_frame(rx_header_retry2);

if accept
    fprintf('    [Rx] ✅ 接收 Seq %d 成功! V(R) -> %d\n', seq_retry2, receiver.V_R);
end

% 此时发送端重传队列应该空了，恢复正常模式
if sender.Resending == false
    fprintf('\n=== 演示结束: 重传完成，系统恢复正常状态 ===\n');
end


% =========================================================================
% 辅助函数: 快速提取 Header 信息 (跳过 frame_parser 的复杂逻辑，仅供逻辑验证)
function h = get_header_info(bits)
    h.SeqNo = bi2de(bits(33:40), 'left-msb');
    h.PCID = bits(17);
    h.QoS = bits(3); % 注意位序可能随 frame_generator 调整，这里假设 QoS 在第3位
end