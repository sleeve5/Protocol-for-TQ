%% Step 2: 数据链路层逻辑测试 (DLL Logic Only)
% 目标: 验证 FOP-P (发送) 和 FARM-P (接收) 在丢包场景下的交互逻辑
% 状态: PASSED

clc; clear; close all;
clear functions; 
addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('=== [Step 2] DLL 协议逻辑测试 (纯逻辑) ===\n');

% 初始化
fop = FOP_Process(0);
farm = FARM_Process(0);

% 待发数据: 3个包 (Payload: 10, 20, 30)
payloads = {10, 20, 30};
curr_idx = 1;

fprintf('计划发送: Seq 0, 1, 2\n');

% 模拟 15 个时间步
for t = 1:15
    fprintf('\n--- Time %d ---\n', t);
    
    % --- 1. Alice (Tx) 决策 ---
    tx_frame = [];
    
    if fop.Resending
        % [重传模式]
        [tx_frame, seq] = fop.prepare_frame([], @frame_generator);
        if ~isempty(tx_frame)
            fprintf('[Tx] 重传 Seq %d\n', seq);
        else
            fprintf('[Tx] 重传队列暂空 (Wait ACK)\n');
            % 此时应保持 Resending 状态，直到收到 ACK 更新
        end
    elseif curr_idx <= length(payloads)
        % [新数据模式]
        p = de2bi(payloads{curr_idx}, 8, 'left-msb');
        [tx_frame, seq] = fop.prepare_frame(p, @frame_generator);
        fprintf('[Tx] 发送新帧 Seq %d\n', seq);
        curr_idx = curr_idx + 1;
    else
        fprintf('[Tx] 无新数据\n');
    end
    
    % --- 2. 模拟丢包 (在 t=2 时丢弃 Seq 1) ---
    if t == 2
        fprintf('[Channel] 💥 丢包! (Seq 1 丢失)\n');
        tx_frame = []; 
    end
    
    % --- 3. Bob (Rx) 接收 ---
    if ~isempty(tx_frame)
        [h, ~] = frame_parser(tx_frame);
        [accept, ~] = farm.process_frame(h);
        
        if accept
            fprintf('[Rx] ✅ 接收 Seq %d. V(R)=%d\n', h.SeqNo, farm.V_R);
        else
            fprintf('[Rx] ⚠️ 拒绝 Seq %d (期望 %d). 触发 NACK.\n', h.SeqNo, farm.V_R);
        end
    end
    
    % --- 4. 反馈链路 (PLCW) ---
    plcw_bits = farm.get_PLCW();
    plcw_info = parse_PLCW(plcw_bits);
    
    ack_type = 'ACK';
    if plcw_info.RetransmitFlag, ack_type = 'NACK'; end
    fprintf('[Fb] %s, Expect %d\n', ack_type, plcw_info.Report_Value);
    
    % Alice 处理反馈
    fop.process_PLCW(plcw_bits);
    
    % --- 5. 终止检查 ---
    if farm.V_R == 3 && isempty(fop.Sent_Queue) && ~fop.Resending
        fprintf('\n✅ 测试通过: 所有数据传输完成且队列清空。\n');
        return;
    end
end

fprintf('\n❌ 测试失败: 未在规定时间内完成传输。\n');