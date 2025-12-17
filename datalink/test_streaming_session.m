%% Proximity-1 全协议栈流式闭环仿真 (Full Stack + Streaming State Machine)
% 版本: Final_v2.0 (集成 Proximity1Receiver 类)
%
% 核心特性:
%   1. 发送端: FOP-P (ARQ) + Frame Gen + LDPC Tx
%   2. 信道: BPSK + AWGN + 模拟丢包
%   3. 接收端: Proximity1Receiver (流式状态机) + FARM-P
%
% 验证目标: 验证接收机状态机在碎片化输入和信道中断下的鲁棒性

clc; clear; close all;
% 清除持久变量，确保 Proximity1Receiver 从头初始化
clear functions; 

% =========================================================================
% 1. 环境初始化
% =========================================================================
script_dir = fileparts(mfilename('fullpath'));
if isempty(script_dir), script_dir = pwd; end
addpath(genpath(script_dir));

fprintf('=======================================================\n');
fprintf('    Proximity-1 全协议栈流式仿真 (Real Streaming)\n');
fprintf('=======================================================\n');

%% 2. 初始化配置

% --- 协议层对象 ---
pcid = 0;
Alice_FOP = FOP_Process(pcid);  % 发送方逻辑 (ARQ Sender)
Bob_FARM  = FARM_Process(pcid); % 接收方逻辑 (ARQ Receiver)

% --- [关键] 初始化流式接收机对象 ---
% 这个对象在整个仿真过程中持久存在，模拟硬件接收机上电
Bob_PhyRx = Proximity1Receiver(); 

% --- 参数配置 ---
sim_params.CodingType = 2;      
sim_params.AcqSeqLen  = 128;
sim_params.TailSeqLen = 128;
sim_params.InterFrameGap = 64;

% 信道参数
SNR_GOOD_dB = 4.0; 
SNR_BAD_dB  = 0.5; 

% 模拟物理接口的数据块大小 (模拟 FIFO 深度，例如每次读 256 个采样点)
PHY_CHUNK_SIZE = 256; 

%% 3. 仿真循环 (模拟随时间推移的多次传输)
% 计划: 0(正常) -> 1(丢包) -> 2(乱序被拒) -> 1(重传) -> 2(重传) -> 3(正常)
data_to_send = {10, 11, 12, 13};
total_steps = 6; 
simulate_channel_failure_at_step = 2; 

for step = 1:total_steps
    fprintf('\n---------------- [Simulation Step %d] ----------------\n', step);
    
    % =====================================================================
    % A. Alice (发送方) 准备数据
    % =====================================================================
    current_payload = [];
    if step <= length(data_to_send)
        current_payload = de2bi(data_to_send{step}, 8, 'left-msb');
    end
    
    % FOP 决定发什么 (新帧 or 重传旧帧)
    [frame_bits, seq_num] = Alice_FOP.prepare_frame(current_payload, @frame_generator);
    
    if isempty(frame_bits)
        fprintf('[Alice] 无数据发送，等待... \n');
        continue; 
    end
    
    if Alice_FOP.Resending
        fprintf('[Alice] \t正在重传 Seq %d ...\n', seq_num);
    else
        fprintf('[Alice] \t发送新帧 Seq %d (Data: %d)...\n', seq_num, bi2de(frame_bits(end-7:end), 'left-msb'));
    end
    
    % =====================================================================
    % B. 物理层发射 (C&S Tx)
    % =====================================================================
    tx_stream = scs_transmitter({frame_bits}, sim_params);
    
    % =====================================================================
    % C. 信道传输 (Channel)
    % =====================================================================
    tx_signal = 1 - 2*double(tx_stream);
    
    % 模拟信道状态
    if step == simulate_channel_failure_at_step
        current_snr = SNR_BAD_dB;
        fprintf('[Channel] \t💥 突发强干扰! SNR 降至 %.1f dB (物理层将失锁)\n', current_snr);
    else
        current_snr = SNR_GOOD_dB;
    end
    
    % 加噪与解调 (LLR)
    esn0 = current_snr + 10*log10(1/2);
    sigma = sqrt(1 / (2 * 10^(esn0/10)));
    rx_signal = tx_signal + sigma * randn(size(tx_signal));
    rx_llr = 2 * rx_signal / sigma^2;
    
    % =====================================================================
    % D. Bob 流式接收 (Streaming Reception)
    % =====================================================================
    % [核心升级] 这里不再调用 receiver()，而是切片调用 Bob_PhyRx.step()
    
    frames_collected_this_step = {};
    num_chunks = ceil(length(rx_llr) / PHY_CHUNK_SIZE);
    
    % fprintf('[Bob PHY] \t数据到达，正在流式解调 (%d chunks)...\n', num_chunks);
    
    for k = 1:num_chunks
        % 1. 提取物理接口数据切片
        idx_start = (k-1)*PHY_CHUNK_SIZE + 1;
        idx_end = min(k*PHY_CHUNK_SIZE, length(rx_llr));
        chunk_llr = rx_llr(idx_start : idx_end);
        
        % 2. 喂给状态机 (就像硬件 FIFO 读入一样)
        new_frames = Bob_PhyRx.step(chunk_llr);
        
        % 3. 收集产出
        if ~isempty(new_frames)
            frames_collected_this_step = [frames_collected_this_step, new_frames];
            % fprintf('[Bob PHY] \t>> 在 Chunk %d 提取到帧！\n', k);
        end
    end
    
    % =====================================================================
    % E. 数据链路层处理 (FARM)
    % =====================================================================
    if isempty(frames_collected_this_step)
        fprintf('[Bob DLL] \t❌ 本次传输未提取到有效帧 (可能丢包或正在积攒数据)\n');
    else
        % 处理所有提取到的帧
        for i = 1:length(frames_collected_this_step)
            rx_bits = frames_collected_this_step{i};
            
            % 1. 解析帧头
            [header, payload] = frame_parser(rx_bits);
            
            % 2. FARM 状态机判决
            [accept, ~] = Bob_FARM.process_frame(header);
            
            if accept
                data_val = bi2de(payload, 'left-msb');
                fprintf('[Bob DLL] \t✅ 成功接收 Seq %d (Data: %d). V(R) -> %d\n', ...
                    header.SeqNo, data_val, Bob_FARM.V_R);
            else
                fprintf('[Bob DLL] \t⚠️ 拒绝接收 Seq %d (期望 %d).\n', ...
                    header.SeqNo, Bob_FARM.V_R);
            end
        end
    end
    
    % =====================================================================
    % F. 反向链路 (Feedback)
    % =====================================================================
    plcw_bits = Bob_FARM.get_PLCW();
    plcw_info = parse_PLCW(plcw_bits);
    
    ack_type = 'ACK';
    if plcw_info.RetransmitFlag, ack_type = 'NACK/Retransmit'; end
    
    fprintf('[Feedback] \tBob 发送 %s: Expecting V(R)=%d\n', ack_type, plcw_info.Report_Value);
    
    % Alice 处理反馈
    Alice_FOP.process_PLCW(plcw_bits);
    
    if Alice_FOP.Resending
        fprintf('[Alice] \t状态: 重传模式.\n');
    else
        fprintf('[Alice] \t状态: 正常模式.\n');
    end
end

fprintf('\n=======================================================\n');
fprintf('    流式仿真结束\n');
fprintf('=======================================================\n');