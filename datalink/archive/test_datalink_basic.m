%% Proximity-1 数据链路层基础测试 (Frame Sublayer Loopback)
% 验证: Frame Generator -> Transmitter -> Channel -> Receiver -> Frame Parser

clc; clear; close all;
% 环境初始化
addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('=== 数据链路层 (Frame Layer) 闭环测试 ===\n');

% =========================================================================
% 1. 配置帧头参数 (模拟两个航天器通信)
% =========================================================================
% Frame 1: 发送给火星车 (SCID 100)，序列号 0
cfg1.SCID = 100;
cfg1.PCID = 0;
cfg1.PortID = 1;
cfg1.SourceDest = 1; % Destination
cfg1.SeqNo = 0;
cfg1.QoS = 0;       % Sequence Controlled
cfg1.PDU_Type = 0;  % User Data
cfg1.FrameLen = 0;  % 稍后根据 Payload 自动计算

% Frame 2: 发送给轨道器 (SCID 200)，序列号 1
cfg2 = cfg1;
cfg2.SCID = 200;
cfg2.SeqNo = 1;

% =========================================================================
% 2. 生成 User Payload 并组帧
% =========================================================================
fprintf('[DLL Tx] 正在组装传送帧...\n');

% 生成随机用户数据 (80 bits & 160 bits)
payload1 = randi([0 1], 1, 80) > 0.5;
payload2 = randi([0 1], 1, 160) > 0.5;

% 调用你写的 frame_generator
% 注意: 假设 frame_generator 会自动计算长度并填入 cfg.FrameLen
% 如果你的 frame_generator 需要外部算好长度，请在这里先算好
cfg1.FrameLen = (40 + length(payload1))/8 - 1; 
cfg2.FrameLen = (40 + length(payload2))/8 - 1;

% 调用生成器 (需确保 frame_generator 在 libs 中)
tx_frame1 = frame_generator(payload1, cfg1); 
tx_frame2 = frame_generator(payload2, cfg2);

frames_to_send = {tx_frame1, tx_frame2};

% =========================================================================
% 3. 通过物理层链路 (C&S + Physical Channel)
% =========================================================================
fprintf('[PHY] 物理层传输 (Tx -> Channel -> Rx)...\n');

% C&S 参数
cs_params.CodingType = 2; % LDPC
cs_params.AcqSeqLen = 256;
cs_params.TailSeqLen = 256;
cs_params.InterFrameGap = 64;

% 调用发射机
tx_bits = scs_transmitter(frames_to_send, cs_params);

% 模拟信道 (BPSK + AWGN 4dB)
rx_signal = awgn(1 - 2*double(tx_bits), 4.0, 'measured');
rx_llr = 2 * rx_signal; % 简单 LLR

% 调用接收机
rx_raw_frames = receiver(rx_llr, cs_params);

fprintf('      接收机输出了 %d 个帧比特流。\n', length(rx_raw_frames));

% =========================================================================
% 4. 帧解析与验证 (Frame Parsing)
% =========================================================================
fprintf('[DLL Rx] 正在解析帧头并验证...\n');

for i = 1:length(rx_raw_frames)
    curr_bits = rx_raw_frames{i};
    
    % 调用解析器
    [parsed_header, parsed_payload] = frame_parser(curr_bits);
    
    fprintf('\n    --- Frame #%d Analysis ---\n', i);
    
    % 验证 A: 协议版本
    if parsed_header.Version == 2
        fprintf('    [Check] Version: 3 (OK)\n');
    else
        fprintf('    [Fail] Version Error: %d\n', parsed_header.Version);
    end
    
    % 验证 B: SCID (航天器ID)
    fprintf('    [Info ] SCID: %d, SeqNo: %d, Length: %d bytes\n', ...
        parsed_header.SCID, parsed_header.SeqNo, parsed_header.Length_Cnt+1);
    
    % 验证 C: 内容比对
    if i == 1
        ref_payload = payload1;
        ref_scid = 100;
    else
        ref_payload = payload2;
        ref_scid = 200;
    end
    
    if parsed_header.SCID == ref_scid && isequal(parsed_payload, ref_payload)
        fprintf('    ✅ 验证通过：帧头信息正确，用户数据无误！\n');
    else
        fprintf('    ❌ 验证失败：数据不匹配。\n');
    end
end