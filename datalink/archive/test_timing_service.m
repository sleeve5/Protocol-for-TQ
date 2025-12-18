%% Proximity-1 定时业务验证 (Timing Service Verification)
% 验证点：
% 1. 发送端能否捕捉到 ASM 离去时刻 (Egress Time)
% 2. 接收端能否捕捉到 ASM 到达时刻 (Ingress Time)
% 3. 记录是否写入 MAC 层的 Buffer

clc; clear; close all;
addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('===== Proximity-1 定时业务验证 =====\n');

% 1. 初始化
io = IO_Sublayer(10);
io.init_link(20);
fop = FOP_Process(0);
mac = MAC_Controller(true, io, fop);

sim_params.CodingType = 2; % LDPC
sim_params.AcqSeqLen = 128;
sim_params.TailSeqLen = 128;
sim_params.InterFrameGap = 64;
% 假设物理符号速率 (用于将 BitIndex 转换为 时间)
PHY_RATE = 200e3; % 200 kbps (Logic Rate)

% 2. 生成数据
fprintf('[Tx] 生成 3 个测试帧 (Seq 0, 1, 2)...\n');
frames = {};
for i = 0:2
    payload = randi([0 1], 1, 800) > 0.5;
    % 手动调用 FOP 封装以获得 SeqNo
    [frm, seq] = fop.prepare_frame(payload, @frame_generator);
    frames{end+1} = frm;
end

% 3. 发射并捕捉时间 (Tx Time Tagging)
[tx_bits, tx_tags] = scs_transmitter_timing(frames, sim_params);

fprintf('\n[MAC] 记录发射时间 (Egress)...\n');
for i = 1:length(tx_tags)
    % 将 BitIndex 转换为仿真时间 (秒)
    % Time = BitIndex / Rate
    t_val = tx_tags(i).BitIndex / PHY_RATE;
    mac.record_egress_time(tx_tags(i).SeqNo, t_val);
end

% 4. 模拟信道 (Delay + Noise)
fprintf('\n[Channel] 添加 1.5秒 物理延迟...\n');
DELAY_SEC = 1.5;
tx_signal = 1 - 2*double(tx_bits);
rx_signal = awgn(tx_signal, 10, 'measured');
rx_llr = 2 * rx_signal;

% % 5. 接收并捕捉时间 (Rx Time Tagging)
% fprintf('\n[Rx] 接收处理 (Ingress)...\n');
% [rx_frames, rx_tags] = receiver_timing(rx_llr, sim_params, io);
% 
% fprintf('[MAC] 记录接收时间 (Ingress)...\n');
% for i = 1:length(rx_tags)
%     % 接收端的逻辑索引 -> 时间
%     % 注意：这里的时间是相对于"接收窗口开始"的时间
%     % 真实物理时间 = 接收开始时间 + (BitIndex / Rate)
%     % 在仿真中，接收开始时间 = 发射开始 + 传播延迟
%     t_start_rx = DELAY_SEC; 
%     t_val = t_start_rx + (rx_tags(i).LogicBitIndex / PHY_RATE);
% 
%     mac.record_ingress_time(rx_tags(i).SeqNo, t_val);
% end

% 5. 接收并捕捉时间 (Rx Time Tagging - 流式验证)
fprintf('\n[Rx] 接收处理 (Ingress - Streaming)...\n');

% 初始化流式接收机
rx_obj = Proximity1Receiver_timing();

% 模拟分块输入 (例如每次 1024 采样点)
CHUNK_SIZE = 1024;
total_rx_len = length(rx_llr);
num_chunks = ceil(total_rx_len / CHUNK_SIZE);

for k = 1:num_chunks
    s = (k-1)*CHUNK_SIZE + 1;
    e = min(k*CHUNK_SIZE, total_rx_len);
    chunk = rx_llr(s:e);
    
    % 调用 step，获取帧和标签
    [new_frames, new_tags] = rx_obj.step(chunk);
    
    % 处理收到的标签
    if ~isempty(new_tags)
        for t = 1:length(new_tags)
            % 计算物理时间
            % 注意：这里的 LogicBitIndex 是译码后的比特索引。
            % 在完美时钟下，假设物理延迟 DELAY_SEC 已知
            % t_val = DELAY_SEC + (BitIndex / Rate)
            
            tag = new_tags(t);
            t_val = DELAY_SEC + (tag.LogicBitIndex / PHY_RATE);
            
            mac.record_ingress_time(tag.SeqNo, t_val);
            
            % 将数据上交给 IO 层 (可选)
            % [h, p] = frame_parser(new_frames{t});
            % io.receive_frame_data(h, p);
        end
    end
end

% 6. 验证结果
fprintf('\n=== 最终 MAC 时间记录表 ===\n');
[tx_log, rx_log] = mac.get_time_logs();

fprintf('SeqNo |  Egress Time (Tx) | Ingress Time (Rx) | Diff (Observed Delay)\n');
fprintf('------+-------------------+-------------------+----------------------\n');

for i = 1:length(tx_log)
    seq = tx_log(i).SeqNo;
    t_tx = tx_log(i).Time;
    
    % 查找对应的 Rx 记录
    idx = find([rx_log.SeqNo] == seq);
    if ~isempty(idx)
        t_rx = rx_log(idx).Time;
        diff = t_rx - t_tx;
        fprintf('  %3d | %12.6f s    | %12.6f s    | %12.6f s\n', seq, t_tx, t_rx, diff);
        
        if abs(diff - DELAY_SEC) < 1e-3
            % 验证通过
        else
            warning('Seq %d 时间差异常', seq);
        end
    else
        fprintf('  %3d | %12.6f s    |    (Lost)         |         -\n', seq, t_tx);
    end
end

fprintf('\n(注: Diff 应接近设置的物理延迟 %.4f s)\n', DELAY_SEC);