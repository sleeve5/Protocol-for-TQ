%% Proximity-1 全协议栈综合仿真 (Full Stack: DLL + C&S + PHY)
% 场景: Alice 发送数据 -> 噪声信道(偶发丢包) -> Bob 接收 -> Bob 回复 PLCW -> Alice 处理
clc; clear; close all;
addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('=======================================================\n');
fprintf('    Proximity-1 全协议栈闭环仿真 (The Final Test)\n');
fprintf('=======================================================\n');

%% 1. 初始化配置
% --- 协议层对象 ---
pcid = 0;
Alice_FOP = FOP_Process(pcid);  % 发送方逻辑
Bob_FARM  = FARM_Process(pcid); % 接收方逻辑

% --- 物理层/C&S 参数 ---
sim_params.CodingType = 2;      % LDPC
sim_params.AcqSeqLen  = 128;
sim_params.TailSeqLen = 128;
sim_params.InterFrameGap = 32;

% --- 信道参数 ---
% 正常信噪比 (无误码)
SNR_GOOD_dB = 4.0; 
% 恶劣信噪比 (必然丢包) -> 用于制造事故
SNR_BAD_dB  = 0.5; 

%% 2. 仿真循环 (模拟多次传输交互)
% 我们计划发送 4 个数据包: Payload 10, 11, 12, 13
data_to_send = {10, 11, 12, 13};
total_steps = 6; % 仿真步数 (给重传留出时间)

% 标志位: 是否在第2步人为制造信道故障
simulate_channel_failure_at_step = 2; 

for step = 1:total_steps
    fprintf('\n---------------- [Simulation Step %d] ----------------\n', step);
    
    % =====================================================================
    % A. Alice (发送方) 准备数据
    % =====================================================================
    % 如果队列里还有未确认的，或者还有新数据要发
    current_payload = [];
    if step <= length(data_to_send)
        % 简单的 Payload 生成 (1字节)
        current_payload = de2bi(data_to_send{step}, 8, 'left-msb');
    end
    
    % FOP 决定发什么 (新帧 or 重传旧帧 or 空闲)
    % 注意：FOP_Process 的 prepare_frame 逻辑是"有数据就发新帧，没数据就不发"
    % 如果处于重传模式，它会忽略输入的新数据，优先重传
    
    [frame_bits, seq_num] = Alice_FOP.prepare_frame(current_payload, @frame_generator);
    
    if isempty(frame_bits)
        fprintf('[Alice] 无数据发送 (等待 ACK 或 传输完成)\n');
        % 即使无数据，为了维持链路，实际可能会发 Idle PLTU，这里跳过
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
    % 封装为比特流 (LDPC 编码等)
    tx_stream = scs_transmitter({frame_bits}, sim_params);
    
    % =====================================================================
    % C. 信道传输 (Channel)
    % =====================================================================
    % 调制
    tx_signal = 1 - 2*double(tx_stream);
    
    % 决定当前信道质量
    if step == simulate_channel_failure_at_step
        current_snr = SNR_BAD_dB;
        fprintf('[Channel] \t💥 突发强干扰! SNR 降至 %.1f dB (预计丢包)\n', current_snr);
    else
        current_snr = SNR_GOOD_dB;
    end
    
    % 加噪
    % Es/N0 计算 (Rate 1/2)
    esn0 = current_snr + 10*log10(1/2);
    sigma = sqrt(1 / (2 * 10^(esn0/10)));
    rx_signal = tx_signal + sigma * randn(size(tx_signal));
    
    % 解调 (LLR)
    rx_llr = 2 * rx_signal / sigma^2;
    
    % =====================================================================
    % D. Bob (接收方) 处理
    % =====================================================================
    % 1. 物理层与C&S接收 (译码 + 校验)
    % receiver 函数返回的是通过了 CRC 的帧
    received_frames = receiver(rx_llr, sim_params);
    
    % 2. 数据链路层处理 (FARM)
    if isempty(received_frames)
        fprintf('[Bob] \t❌ 物理层解调失败 (未检测到有效帧)\n');
        % 此时 Bob 不知道发了什么，状态不变，等待超时或下一帧触发 NACK
    else
        % 假设一次只发了一帧
        rx_bits = received_frames{1};
        
        % 解析帧头
        [header, payload] = frame_parser(rx_bits);
        
        % FARM 状态机处理 (检查序号)
        [accept, need_ack] = Bob_FARM.process_frame(header);
        
        if accept
            data_val = bi2de(payload, 'left-msb');
            fprintf('[Bob] \t✅ 成功接收 Seq %d (Data: %d). V(R) -> %d\n', ...
                header.SeqNo, data_val, Bob_FARM.V_R);
        else
            fprintf('[Bob] \t⚠️ 拒绝接收 Seq %d (期望 %d).\n', ...
                header.SeqNo, Bob_FARM.V_R);
        end
    end
    
    % =====================================================================
    % E. 反向链路 (Feedback Loop)
    % =====================================================================
    % Bob 生成 PLCW (ACK/NACK)
    plcw_bits = Bob_FARM.get_PLCW();
    
    % 为了简化，我们假设反向链路是完美的 (或者是通过独立的无噪信道传回去)
    % 在真实仿真中，这里也应该走一遍 scs_transmitter -> Channel -> scs_receiver
    % 但为了代码不至于太长，我们这里直接透传 PLCW bits 给 Alice
    
    % 解析 PLCW 用于打印日志
    plcw_info = parse_PLCW(plcw_bits);
    ack_type = 'ACK';
    if plcw_info.RetransmitFlag, ack_type = 'NACK/Retransmit'; end
    
    fprintf('[Feedback] \tBob 发送 %s: Expecting V(R)=%d\n', ack_type, plcw_info.Report_Value);
    
    % Alice 处理 PLCW
    Alice_FOP.process_PLCW(plcw_bits);
    
    % 检查 Alice 状态
    if Alice_FOP.Resending
        fprintf('[Alice] \t状态更新: 进入重传模式.\n');
    else
        fprintf('[Alice] \t状态更新: 正常发送模式.\n');
    end
    
end

fprintf('\n=======================================================\n');
fprintf('    仿真结束\n');
fprintf('=======================================================\n');