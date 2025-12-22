%% Proximity-1 ARQ 鲁棒性测试：ACK 丢失与超时恢复 (Fixed)
% 验证点: FOP-P 的 SYNCH_TIMER 是否能解决 ACK 丢失导致的死锁
% 场景: Alice 发 Seq 0 -> Bob 收 -> Bob 发 ACK -> [ACK 丢失] -> Alice 超时 -> Alice 重传

clc; clear; close all;
clear functions; 
addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('=======================================================\n');
fprintf('    Proximity-1 可靠性测试: ACK 丢失与超时恢复\n');
fprintf('=======================================================\n');

% 1. 初始化
fop_alice = FOP_Process(0);
% 设置超时为 3 个仿真步 (加快测试)
% 注意：Timer 在 tick() 时递减
fop_alice.TIMEOUT_THRESHOLD = 4; 

farm_bob  = FARM_Process(0);

% 物理层参数
sim_params.CodingType = 2; 
sim_params.AcqSeqLen=128; 
sim_params.TailSeqLen=128; 
sim_params.InterFrameGap=64;

rx_bob_machine = Proximity1Receiver_timing();

PHY_DATA_RATE = 100e3; 

% 2. 仿真循环
max_steps = 15;
step = 0;

% [关键修正] 在第 1 步就丢弃 ACK，强迫系统进入等待超时状态
ack_loss_step = 1; 
target_payload = de2bi(255, 8, 'left-msb'); 

while step < max_steps
    step = step + 1;
    fprintf('\n--- Step %d ---\n', step);
    
    % --- A. Alice (FOP) 滴答与发送 ---
    % 1. 时钟滴答 (检查超时)
    % tick 返回 true 表示触发了超时重传
    is_timeout = fop_alice.tick();
    
    % 2. 准备帧
    tx_frame = [];
    
    % 只有当队列空(且没发过) 或 重传模式时，才会有动作
    if (fop_alice.V_S == 0 && isempty(fop_alice.Sent_Queue)) || fop_alice.Resending
        % 注意：prepare_frame 内部逻辑：如果 Resending=true，它会无视输入 payload，重发旧帧
        [tx_frame, seq] = fop_alice.prepare_frame(target_payload, @frame_generator);
        
        if ~isempty(tx_frame)
            if fop_alice.Resending
                fprintf('    [Alice] 🔄 触发超时重传！Seq %d (Timer重置为 %d)\n', seq, fop_alice.SYNCH_TIMER);
            else
                fprintf('    [Alice] 发送新帧 Seq %d (Timer启动 %d)\n', seq, fop_alice.SYNCH_TIMER);
            end
        end
    else
        % 正在等待 ACK，不发新数据
        fprintf('    [Alice] 等待 ACK... (Timer倒数: %d)\n', fop_alice.SYNCH_TIMER);
    end
    
    % --- B. 物理层传输 ---
    rx_plcw = [];
    if ~isempty(tx_frame)
        [rx_frames, ~] = run_simple_phy(tx_frame, 12, 0, sim_params, rx_bob_machine, PHY_DATA_RATE);
        
        % --- C. Bob (FARM) 接收 ---
        if ~isempty(rx_frames)
            for k=1:length(rx_frames)
                [h, ~] = frame_parser(rx_frames{k});
                [accept, ~] = farm_bob.process_frame(h);
                if accept
                    fprintf('    [Bob] ✅ 接收 Seq %d. V(R)->%d\n', h.SeqNo, farm_bob.V_R);
                else
                    fprintf('    [Bob] ⚠️ 收到 Seq %d (重复). V(R)=%d. 丢弃但重发ACK.\n', h.SeqNo, farm_bob.V_R);
                end
            end
        end
        
        % Bob 生成 ACK
        rx_plcw = farm_bob.get_PLCW();
    end
    
    % --- D. 反馈链路 (模拟丢包) ---
    if ~isempty(rx_plcw)
        if step == ack_loss_step
            fprintf('    [Channel] 💥 糟糕！Bob 发出的 ACK 在回程中丢失了！\n');
            rx_plcw = []; % 丢弃，模拟丢失
        else
            info = parse_PLCW(rx_plcw);
            ack_type = 'ACK'; if info.RetransmitFlag, ack_type = 'NACK'; end
            fprintf('    [Feedback] %s 到达 Alice (Expect %d)\n', ack_type, info.Report_Value);
        end
        
        % Alice 处理 ACK
        fop_alice.process_PLCW(rx_plcw);
    end
    
    % 终止条件
    % 只有当 Bob 收到了，且 Alice 也确认了(队列空)，才算成功
    if isempty(fop_alice.Sent_Queue) && farm_bob.V_R > 0
        fprintf('\n✅ 测试成功：Alice 队列已清空，Bob 已接收。\n');
        break;
    end
end

% -------------------------------------------------------------------------
% 辅助函数: 物理层
% -------------------------------------------------------------------------
function [rx_frames, time_tags] = run_simple_phy(tx_frame, snr_db, delay_sec, cs_params, rx_machine, data_rate)
    [tx_bits, tx_time_tags] = scs_transmitter_timing({tx_frame}, cs_params);
    tx_sym = 1 - 2*double(tx_bits);
    sigma = sqrt(1 / (2 * 10^((snr_db - 3)/10)));
    rx_sym = tx_sym + sigma * randn(size(tx_sym));
    rx_llr = 2 * rx_sym / sigma^2;
    chunk_size = 512;
    rx_frames = {}; rx_tags = [];
    for k = 1:ceil(length(rx_llr)/chunk_size)
        s = (k-1)*chunk_size+1; e = min(k*chunk_size, length(rx_llr));
        [f, t] = rx_machine.step(rx_llr(s:e));
        rx_frames = [rx_frames, f];
        if ~isempty(t), rx_tags = [rx_tags; t]; end
    end
    time_tags.tx = tx_time_tags; time_tags.rx = rx_tags;
end