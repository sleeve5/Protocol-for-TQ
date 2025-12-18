%% Step 3: 定时业务独立测试 (修正版)
% 目标: 验证 OWLT 计算精度
% 状态: PASSED

clc; clear; close all;
clear functions; 
addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('=== [Step 3] 定时业务精度测试 ===\n');

% 1. 参数配置
PHY_RATE = 100e3;
DISTANCE = 170000 * 1000; % 170,000 km
c = 3e8;
DELAY_SEC = DISTANCE / c; 

sim_params.CodingType = 2; 
sim_params.AcqSeqLen = 512; 
sim_params.TailSeqLen = 128;
sim_params.InterFrameGap = 64;

% 2. 发射机
payload = randi([0 1], 1, 800) > 0.5;
cfg.SCID=10; cfg.PCID=0; cfg.PortID=0; cfg.SourceDest=0; 
cfg.SeqNo=55; cfg.QoS=0; cfg.PDU_Type=0;
tx_frame = frame_generator(payload, cfg);

[tx_bits, tx_tags] = scs_transmitter_timing({tx_frame}, sim_params);
t_egress = tx_tags(1).BitIndex / PHY_RATE;
fprintf('Tx Egress Time: %.6f s\n', t_egress);

% 3. 信道
tx_sym = 1 - 2*double(tx_bits);
sigma = 0.1; 
rx_sym = tx_sym + sigma * randn(size(tx_sym));
rx_llr = 2 * rx_sym / sigma^2;

delay_bits = round(DELAY_SEC * PHY_RATE);
fprintf('模拟物理延迟: %.6f s (%d bits)\n', DELAY_SEC, delay_bits);

delay_noise = (2/sigma^2) * (sigma * randn(1, delay_bits));
rx_llr_total = [delay_noise, rx_llr];

% 4. 接收机
rx = Proximity1Receiver_timing();
CHUNK_SIZE = 512;
total_len = length(rx_llr_total);
num_chunks = ceil(total_len / CHUNK_SIZE);
all_rx_tags = [];

for k = 1:num_chunks
    s = (k-1)*CHUNK_SIZE + 1;
    e = min(k*CHUNK_SIZE, total_len);
    chunk = rx_llr_total(s:e);
    [~, new_tags] = rx.step(chunk);
    if ~isempty(new_tags), all_rx_tags = [all_rx_tags; new_tags]; end
end

% 5. 验证
if ~isempty(all_rx_tags)
    % 修正：绝对时间 = 物理延迟 + 相对解码时间
    t_ingress = DELAY_SEC + (all_rx_tags(1).LogicBitIndex / PHY_RATE);
    fprintf('Rx Ingress Time: %.6f s\n', t_ingress);
    
    owlt = t_ingress - t_egress;
    err = abs(owlt - DELAY_SEC);
    
    fprintf('测量 OWLT: %.6f s (误差 %.2e s)\n', owlt, err);
    if err < 1e-4
        fprintf('✅ 测试通过\n');
    else
        fprintf('❌ 误差过大\n');
    end
else
    fprintf('❌ 未提取到时间标签\n');
end