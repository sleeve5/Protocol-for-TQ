%% Proximity-1 流式定时业务验证 (Streaming Timing Verification)
% 验证点：在碎片化接收模式下，Proximity1Receiver 能否正确计算 ASM 到达时刻
% 依赖：Proximity1Receiver v3.0

clc; clear; close all;
clear functions; % 清除持久化变量

addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('=======================================================\n');
fprintf('    Proximity-1 流式定时业务验证 (Streaming)\n');
fprintf('=======================================================\n');

% 1. 初始化
io = IO_Sublayer(10);
io.init_link(20);
fop = FOP_Process(0);
mac_alice = MAC_Controller(true, io, fop);
mac_bob   = MAC_Controller(false, io, fop); % 仅用于存储 Rx Time

sim_params.CodingType = 2; 
sim_params.AcqSeqLen = 128;
sim_params.TailSeqLen = 128;
sim_params.InterFrameGap = 64;

PHY_RATE = 200e3; % 逻辑比特率 (200 kbps)

% 2. 生成数据 (Seq 0, 1, 2)
fprintf('[Tx] 生成 3 个测试帧...\n');
frames = {};
for i = 0:2
    payload = randi([0 1], 1, 800) > 0.5;
    [frm, seq] = fop.prepare_frame(payload, @frame_generator);
    frames{end+1} = frm;
end

% 3. 发射并捕捉离去时间
[tx_bits, tx_tags] = scs_transmitter_timing(frames, sim_params);

fprintf('[MAC Alice] 记录 Egress Time...\n');
for i = 1:length(tx_tags)
    t_val = tx_tags(i).BitIndex / PHY_RATE;
    mac_alice.capture_egress_time(t_val, tx_tags(i).SeqNo, tx_tags(i).QoS);
end

% 4. 模拟信道 (1.5s 延迟)
REAL_DELAY_SEC = 1.5;
fprintf('\n[Channel] 物理延迟: %.6f 秒\n', REAL_DELAY_SEC);

tx_signal = 1 - 2*double(tx_bits);
rx_signal = awgn(tx_signal, 12, 'measured'); % 高信噪比
rx_llr = 2 * rx_signal;

% 5. 流式接收 (Streaming Rx)
fprintf('\n[Rx] 启动流式接收 (模拟碎片化到达)...\n');

% 初始化流式接收机对象
rx_obj = Proximity1Receiver_timing();

% 模拟物理接口 Buffer 大小 (例如每次读 512 点)
CHUNK_SIZE = 512;
total_rx_len = length(rx_llr);
num_chunks = ceil(total_rx_len / CHUNK_SIZE);

total_frames_found = 0;

for k = 1:num_chunks
    s = (k-1)*CHUNK_SIZE + 1;
    e = min(k*CHUNK_SIZE, total_rx_len);
    chunk = rx_llr(s:e);
    
    % 调用 step (返回帧 + 标签)
    [new_frames, new_tags] = rx_obj.step(chunk);
    
    % 统计
    if ~isempty(new_frames)
        total_frames_found = total_frames_found + length(new_frames);
        % fprintf('    Chunk %d: 提取到 %d 帧\n', k, length(new_frames));
    end
    
    % 记录接收时间
    if ~isempty(new_tags)
        for t = 1:length(new_tags)
            tag = new_tags(t);
            
            % 计算物理时间
            % Time = Start_Time + Delay + (LogicBitIndex / Rate)
            t_val = REAL_DELAY_SEC + (tag.LogicBitIndex / PHY_RATE);
            
            mac_bob.capture_ingress_time(t_val, tag.SeqNo, tag.QoS);
        end
    end
end

fprintf('    流式接收结束，共提取 %d 帧。\n', total_frames_found);

% =========================================================================
% 6. 验证结果
% =========================================================================
fprintf('\n=== 最终 MAC 时间记录表 (流式) ===\n');

% [修正点] 分别从 Alice 和 Bob 获取日志
% Alice 只有发射记录 (Tx)
tx_log = mac_alice.get_timing_logs('Tx'); 

% Bob 只有接收记录 (Rx)
rx_log = mac_bob.get_timing_logs('Rx');   

fprintf('%-6s | %-15s | %-15s | %-15s | %-10s\n', 'SeqNo', 'Egress(s)', 'Ingress(s)', 'Diff(s)', 'Status');
fprintf('-------+-----------------+-----------------+-----------------+----------\n');

for i = 1:length(tx_log)
    seq = tx_log(i).SeqNo;
    t_out = tx_log(i).Time;
    
    % 在 Bob 的接收记录中查找对应的 SeqNo
    match_idx = -1;
    for k = 1:length(rx_log)
        if rx_log(k).SeqNo == seq
            match_idx = k; break;
        end
    end
    
    if match_idx > 0
        t_in = rx_log(match_idx).Time;
        diff = t_in - t_out;
        
        % 允许微小误差 (浮点精度)
        if abs(diff - REAL_DELAY_SEC) < 1e-4
            status = '✅ PASS';
        else
            status = '❌ FAIL';
        end
        
        fprintf('   %3d | %15.6f | %15.6f | %15.6f | %s\n', ...
            seq, t_out, t_in, diff, status);
    else
        fprintf('   %3d | %15.6f |      (Lost)     |        -        | ⚠️ LOST\n', seq, t_out);
    end
end