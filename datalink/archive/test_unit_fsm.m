%% Proximity-1 基于状态机的流式接收测试
% 验证 Proximity1Receiver 类的流处理能力

clc; clear; close all;
% 环境初始化
addpath(genpath(fileparts(mfilename('fullpath'))));

% 1. 生成发送数据 (长数据流)
fprintf('[Tx] 生成测试数据流...\n');
frames = {randi([0 1],1,200)>0.5, randi([0 1],1,800)>0.5, randi([0 1],1,400)>0.5};

cs_params.CodingType = 2;
cs_params.AcqSeqLen = 128;
cs_params.TailSeqLen = 128;
cs_params.InterFrameGap = 32;

tx_bits = scs_transmitter(frames, cs_params);

% 模拟信道 (BPSK + AWGN)
tx_syms = 1 - 2*double(tx_bits);
rx_syms = awgn(tx_syms, 5, 'measured'); % SNR=5dB
rx_llr  = 2 * rx_syms; % 简单 LLR

% 2. 初始化接收机对象
fprintf('[Rx] 初始化状态机接收机...\n');
rx_obj = Proximity1Receiver();

% 3. 流式处理 (Streaming Loop)
% 模拟每次接收 256 个采样点 (比如来自 FPGA 或 SDR 的 buffer)
CHUNK_SIZE = 256;
total_samples = length(rx_llr);
num_chunks = ceil(total_samples / CHUNK_SIZE);

all_recovered_frames = {};

fprintf('[Rx] 开始流式接收 (%d chunks)...\n', num_chunks);

for i = 1:num_chunks
    % 提取当前切片
    idx_start = (i-1)*CHUNK_SIZE + 1;
    idx_end = min(i*CHUNK_SIZE, total_samples);
    rx_chunk = rx_llr(idx_start : idx_end);
    
    % --- 调用状态机 ---
    % 就像喂数据给黑盒子一样，有产出就拿，没产出就继续
    new_frames = rx_obj.step(rx_chunk);
    
    % 收集结果
    if ~isempty(new_frames)
        fprintf('    TimeStep %3d: 捕获到 %d 个新帧！(当前状态: %s)\n', ...
            i, length(new_frames), rx_obj.State);
        all_recovered_frames = [all_recovered_frames, new_frames];
    end
end

% 4. 验证
fprintf('\n[Result] 最终收到 %d 个帧 (发送 %d 个)\n', length(all_recovered_frames), length(frames));

if length(all_recovered_frames) == length(frames)
    match = true;
    for k = 1:length(frames)
        if ~isequal(all_recovered_frames{k}, frames{k})
            match = false;
        end
    end
    
    if match
        fprintf('✅ 测试通过：流式状态机完美工作！\n');
    else
        fprintf('❌ 测试失败：内容不匹配。\n');
    end
else
    fprintf('❌ 测试失败：丢帧。\n');
end