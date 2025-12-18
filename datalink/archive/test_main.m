%% Proximity-1 全协议栈流式闭环仿真 (Full Stack Streaming)
% 核心特性: 使用 Proximity1Receiver 类替代函数式接收
% 验证点: 状态机在多次传输、信道中断、碎片化输入下的稳定性

clc; clear; close all;
clear functions;
addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('=======================================================\n');
fprintf('    Proximity-1 全协议栈流式仿真 (State Machine)\n');
fprintf('=======================================================\n');

%% 1. 初始化配置
pcid = 0;
Alice_FOP = FOP_Process(pcid);  % 发送状态机
Bob_FARM  = FARM_Process(pcid); % 接收状态机

% [关键改变] 初始化流式接收机对象 (持久化存在)
Bob_PhyRx = Proximity1Receiver(); 

% 参数配置
sim_params.CodingType = 2;      
sim_params.AcqSeqLen  = 128;
sim_params.TailSeqLen = 128;
sim_params.InterFrameGap = 32;

SNR_GOOD_dB = 4.0; 
SNR_BAD_dB  = 0.5; 

%% 2. 仿真循环
data_to_send = {10, 11, 12, 13};
total_steps = 6; 
simulate_channel_failure_at_step = 2; 

% 模拟接收机物理接口的缓冲区大小 (例如 FPGA 的 FIFO 深度)
PHY_CHUNK_SIZE = 256; 

for step = 1:total_steps
    fprintf('\n---------------- [Simulation Step %d] ----------------\n', step);
    
    % =====================================================================
    % A. Alice 准备数据
    % =====================================================================
    current_payload = [];
    if step <= length(data_to_send)
        current_payload = de2bi(data_to_send{step}, 8, 'left-msb');
    end
    
    [frame_bits, seq_num] = Alice_FOP.prepare_frame(current_payload, @frame_generator);
    
    if isempty(frame_bits)
        fprintf('[Alice] 无数据发送，跳过物理层传输。\n');
        continue; 
    end
    
    if Alice_FOP.Resending
        fprintf('[Alice] \t正在重传 Seq %d ...\n', seq_num);
    else
        fprintf('[Alice] \t发送新帧 Seq %d (Data: %d)...\n', seq_num, bi2de(frame_bits(end-7:end), 'left-msb'));
    end
    
    % =====================================================================
    % B. 物理层发射
    % =====================================================================
    tx_stream = scs_transmitter({frame_bits}, sim_params);
    
    % =====================================================================
    % C. 信道传输
    % =====================================================================
    tx_signal = 1 - 2*double(tx_stream);
    
    if step == simulate_channel_failure_at_step
        current_snr = SNR_BAD_dB;
        fprintf('[Channel] \t💥 突发强干扰! SNR 降至 %.1f dB\n', current_snr);
    else
        current_snr = SNR_GOOD_dB;
    end
    
    esn0 = current_snr + 10*log10(1/2);
    sigma = sqrt(1 / (2 * 10^(esn0/10)));
    rx_signal = tx_signal + sigma * randn(size(tx_signal));
    rx_llr = 2 * rx_signal / sigma^2;
    
    % =====================================================================
    % D. Bob 流式接收 (Streaming Reception)
    % =====================================================================
    % [关键改变] 模拟真实硬件行为：数据是一点一点到达的
    % 我们将 rx_llr 切分为多个小块，喂给状态机
    
    received_frames = {};
    num_chunks = ceil(length(rx_llr) / PHY_CHUNK_SIZE);
    
    % fprintf('[Bob PHY] \t数据到达，正在流式解调 (%d chunks)...\n', num_chunks);
    
    for k = 1:num_chunks
        % 1. 提取切片
        idx_start = (k-1)*PHY_CHUNK_SIZE + 1;
        idx_end = min(k*PHY_CHUNK_SIZE, length(rx_llr));
        chunk_llr = rx_llr(idx_start : idx_end);
        
        % 2. 喂给状态机
        new_frames = Bob_PhyRx.step(chunk_llr);
        
        % 3. 收集产出
        if ~isempty(new_frames)
            received_frames = [received_frames, new_frames];
            % fprintf('[Bob PHY] \t>> 在 Chunk %d 提取到帧！\n', k);
        end
    end
    
    % 检查当前状态机状态 (用于调试)
    % fprintf('[Bob PHY] \t传输结束，接收机状态: %s, PhyBuffer剩余: %d\n', ...
    %     Bob_PhyRx.State, length(Bob_PhyRx.PhyBuffer));
    
    % =====================================================================
    % E. 数据链路层处理 (FARM)
    % =====================================================================
    if isempty(received_frames)
        fprintf('[Bob DLL] \t❌ 未收到有效帧 (物理层丢包或校验失败)\n');
    else
        % 处理所有提取到的帧 (通常只有1帧，但也可能粘包)
        for i = 1:length(received_frames)
            rx_bits = received_frames{i};
            [header, payload] = frame_parser(rx_bits);
            
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
    % F. 反向链路
    % =====================================================================
    plcw_bits = Bob_FARM.get_PLCW();
    
    plcw_info = parse_PLCW(plcw_bits);
    ack_type = 'ACK';
    if plcw_info.RetransmitFlag, ack_type = 'NACK/Retransmit'; end
    
    fprintf('[Feedback] \tBob 发送 %s: Expecting V(R)=%d\n', ack_type, plcw_info.Report_Value);
    
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