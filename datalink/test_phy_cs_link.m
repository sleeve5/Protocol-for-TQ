%% Step 1: 物理与编码层链路测试 (含延迟与噪声)
% 目标: 验证接收机能否在长延迟(噪声填充)后正确锁定 CSM 并提取数据
% 状态: PASSED

clc; clear; close all;
clear functions; 
addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('=== [Step 1] 物理与编码层连通性测试 ===\n');

% 1. 配置
PHY_RATE = 100e3;
DISTANCE = 170000 * 1000; % 17万公里
DELAY_SEC = DISTANCE / 3e8;

sim_params.CodingType = 2; 
sim_params.AcqSeqLen = 512; % 增加捕获序列长度
sim_params.TailSeqLen = 128;
sim_params.InterFrameGap = 64;

% 2. 生成一帧数据
payload = randi([0 1], 1, 800) > 0.5;
cfg.SCID = 10; cfg.PCID = 0; cfg.PortID = 0; 
cfg.SourceDest = 0; cfg.SeqNo = 0; cfg.QoS = 0; cfg.PDU_Type = 0;
tx_frame = frame_generator(payload, cfg);

% 3. 发射
[tx_bits, ~] = scs_transmitter_timing({tx_frame}, sim_params);
fprintf('发射长度: %d bits\n', length(tx_bits));

% 4. 信道 (含延迟噪声填充)
tx_sym = 1 - 2*double(tx_bits);
SNR_dB = 10; % 高信噪比，专注测同步逻辑
sigma = sqrt(1 / (2 * 10^((SNR_dB - 3)/10)));
rx_sym = tx_sym + sigma * randn(size(tx_sym));
rx_llr_pure = 2 * rx_sym / sigma^2;

% [关键] 构造延迟噪声 (必须是高斯噪声，不能是0)
delay_bits = round(DELAY_SEC * PHY_RATE);
fprintf('模拟延迟: %.4f s (%d bits)\n', DELAY_SEC, delay_bits);

delay_noise = (2/sigma^2) * (sigma * randn(1, delay_bits));
rx_llr_total = [delay_noise, rx_llr_pure];

% 5. 接收 (流式)
rx = Proximity1Receiver_timing();
chunk_size = 512;
n_chunks = ceil(length(rx_llr_total)/chunk_size);
frames_out = {};

fprintf('开始接收处理 (共 %d chunks)...\n', n_chunks);
for k = 1:n_chunks
    s = (k-1)*chunk_size+1; 
    e = min(k*chunk_size, length(rx_llr_total));
    [f, ~] = rx.step(rx_llr_total(s:e));
    if ~isempty(f), frames_out = [frames_out, f]; end
end

% 6. 验证
if isempty(frames_out)
    fprintf('❌ 失败: 未提取到帧。\n');
else
    [~, rx_payload] = frame_parser(frames_out{1});
    if isequal(rx_payload, payload)
        fprintf('✅ 成功: 在长延迟后正确提取数据！\n');
    else
        fprintf('❌ 失败: 数据内容不匹配。\n');
    end
end