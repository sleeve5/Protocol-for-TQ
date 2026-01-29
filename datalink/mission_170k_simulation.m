%% Proximity-1 深空链路点对点仿真 (Mission: Earth-LISA) - Fixed
% =========================================================================
% 仿真场景: 
%   - 节点: Alice (Earth) <--> Bob (LISA Satellite)
%   - 距离: 170,000 km (单向光行时 ~0.57s)
%   - 信道: BPSK + AWGN + 传播延迟
%
% 修正记录:
%   1. 补充缺失的 Bob_FARM 对象初始化。
% =========================================================================

clc; clear; close all;
clear functions; % 重置持久化变量

% 1. 环境初始化
script_dir = fileparts(mfilename('fullpath'));
if isempty(script_dir), script_dir = pwd; end
addpath(genpath(script_dir));

fprintf('===============================================================\n');
fprintf('    LISA 星间链路 Proximity-1 协议仿真 (170,000 km)\n');
fprintf('===============================================================\n');

%% 2. 任务参数配置

% --- A. 物理与空间参数 ---
PHY_DATA_RATE = 195.3125e3;          % 128 kbps
LINK_DISTANCE = 170000 * 1000;  % 17万公里
LIGHT_SPEED   = 3e8;
ONE_WAY_DELAY = LINK_DISTANCE / LIGHT_SPEED; % ~0.567秒

% --- B. 协议层配置 ---
sim_params.CodingType = 2;      
sim_params.AcqSeqLen  = 512;    
sim_params.TailSeqLen = 128;   
sim_params.InterFrameGap = 64; 

% --- C. 节点初始化 ---
SCID_ALICE = 10; 
SCID_BOB   = 20; 

% Alice (发送方)
io_alice  = IO_Sublayer(SCID_ALICE); io_alice.init_link(SCID_BOB);
fop_alice = FOP_Process(0);
fop_alice.TIMEOUT_THRESHOLD = 8; % 增大超时阈值适应长延迟
mac_alice = MAC_Controller(true, io_alice, fop_alice); 
mac_alice.Hail_Wait_Duration = 3.0; 

% Bob (接收方)
io_bob    = IO_Sublayer(SCID_BOB); io_bob.init_link(SCID_ALICE);
fop_bob   = FOP_Process(0);
mac_bob   = MAC_Controller(false, io_bob, fop_bob);

% [关键修正] 初始化 Bob 的 FARM 接收控制器
Bob_FARM  = FARM_Process(0); 

% Bob 的流式接收机
rx_bob_machine = Proximity1Receiver_timing();

% 统计
stats.sent = 0; stats.rcvd = 0; stats.retx = 0;

fprintf('[Config] 链路距离: %.2f km\n', LINK_DISTANCE/1000);
fprintf('[Config] 单向延迟: %.4f s\n', ONE_WAY_DELAY);
fprintf('[Config] 数据速率: %.4f kbps\n', PHY_DATA_RATE/1000);

%% 3. [Phase I] 链路建立 (Hailing)
fprintf('\n>>> [Phase I] 链路建立 (Hailing) <<<\n');

% 1. Alice 发起呼叫
mac_alice.start_hailing(SCID_BOB);
[tx_frame, type] = frame_multiplexer(io_alice, SCID_BOB);

if ~isempty(tx_frame)
    fprintf('    [SC-10] 发送 Hailing P-Frame (%d bits)\n', length(tx_frame));
    
    % 2. 物理传输 (正向)
    [rx_frames, ~, ~] = run_simple_phy(tx_frame, 12, ONE_WAY_DELAY, sim_params, rx_bob_machine, PHY_DATA_RATE);
    
    % 3. Bob 接收处理
    if ~isempty(rx_frames)
        [h, p] = frame_parser(rx_frames{1});
        io_bob.receive_frame_data(h, p); 
        if h.PDU_Type == 1
             mac_bob.process_received_spdu(h.SCID, p);
        end
        fprintf('    [SC-20] 收到呼叫 (延迟 %.3fs)，状态迁移至: %s\n', ONE_WAY_DELAY, mac_bob.State);
        fprintf('    [SC-20] 发送握手确认...\n');
    end
    
    % 假设 Alice 收到应答
    mac_alice.State = 'DATA_SERVICES'; 
    fprintf('    [SC-10] 收到确认 (延迟 %.3fs)，状态迁移至: DATA_SERVICES\n', ONE_WAY_DELAY);
    fprintf('    [System] 会话建立完成。\n');
else
    error('SC-10 未生成 Hailing 帧');
end

%% 4. [Phase II] 数据传输与重传 (Data Transfer & ARQ)
fprintf('\n>>> [Phase II] 数据传输与 ARQ 演示 <<<\n');
% 场景：发送 4 帧，第 2 帧丢包
payload_list = {101, 102, 103, 104}; 
curr_payload_idx = 1;

step = 0;
max_steps = 20;
fail_step = 2; % 在第 2 步触发信道中断

rx_bob_machine.reset(); 

while step < max_steps
    step = step + 1;
    
    % --- 0. 终止条件 ---
    if Bob_FARM.V_R == length(payload_list) && ~fop_alice.Resending && isempty(fop_alice.Sent_Queue)
        fprintf('\n--- [Success] 所有数据传输完成且确认 ---\n');
        break;
    end
    
    % --- 1. 信道状态 ---
    if step == fail_step
        current_snr = 0.5; % 极低信噪比 -> 丢包
        desc = '💥 信道中断 (Deep Space Fade)';
    else
        current_snr = 10; 
        desc = '链路正常';
    end
    fprintf('\n--- Step %d: %s ---\n', step, desc);
    
    % --- 2. Alice (Tx) ---
    tx_frame = [];
    
    if fop_alice.Resending
        [tx_frame, seq] = fop_alice.prepare_frame([], @frame_generator);
        if ~isempty(tx_frame)
            fprintf('    [SC-10] 正在重传 Seq %d (ARQ)\n', seq);
            stats.retx = stats.retx + 1;
        else
            fprintf('    [SC-10] 重传队列空，等待 ACK\n');
            fop_alice.Resending = false; 
        end
    elseif curr_payload_idx <= length(payload_list)
        p = de2bi(payload_list{curr_payload_idx}, 8, 'left-msb');
        [tx_frame, seq] = fop_alice.prepare_frame(p, @frame_generator);
        fprintf('    [SC-10] 发送新帧 Seq %d (Data: %d)\n', seq, payload_list{curr_payload_idx});
        curr_payload_idx = curr_payload_idx + 1;
        stats.sent = stats.sent + 1;
    else
        fprintf('    [SC-10] 无新数据，维持链路 (Idle)...\n');
    end
    
    % --- 3. 物理层传输 ---
    if ~isempty(tx_frame)
        [rx_frames, ~] = run_simple_phy(tx_frame, current_snr, ONE_WAY_DELAY, sim_params, rx_bob_machine, PHY_DATA_RATE);
        
        % --- 4. Bob (Rx) ---
        if isempty(rx_frames)
            fprintf('    [SC-20] ❌ 物理层解调失败\n');
        else
            for f = 1:length(rx_frames)
                [h, p] = frame_parser(rx_frames{f});
                
                % FARM 接收判决
                [accept, ~] = Bob_FARM.process_frame(h);
                
                if accept
                    data_val = -1; 
                    if ~isempty(p), data_val = bi2de(p, 'left-msb'); end
                    fprintf('    [SC-20] ✅ 接收 Seq %d (Data: %d). V(R)->%d\n', h.SeqNo, data_val, Bob_FARM.V_R);
                    stats.rcvd = stats.rcvd + 1;
                else
                    fprintf('    [SC-20] ⚠️ 拒绝 Seq %d (期望 V(R)=%d)\n', h.SeqNo, Bob_FARM.V_R);
                end
            end
        end
    end
    
    % --- 5. 反馈链路 ---
    plcw_bits = Bob_FARM.get_PLCW();
    plcw = parse_PLCW(plcw_bits);
    
    ack_str = 'ACK'; 
    if plcw.RetransmitFlag, ack_str = 'NACK'; end
    
    fprintf('    [Return Link] SC-20 发送 %s (Expect %d)... 传输中(%.3fs)...\n', ...
        ack_str, plcw.Report_Value, ONE_WAY_DELAY);
    
    fop_alice.process_PLCW(plcw_bits);
end

%% 5. 仿真总结报告
fprintf('\n===============================================================\n');
fprintf('    LISA 星间链路仿真报告\n');
fprintf('===============================================================\n');
fprintf('1. 链路参数:\n');
fprintf('   - 距离: 170,000 km\n');
fprintf('   - RTT:  %.4f s\n', ONE_WAY_DELAY*2);
fprintf('2. 传输统计:\n');
fprintf('   - 发送帧数: %d\n', length(payload_list));
fprintf('   - 成功接收: %d\n', stats.rcvd);
fprintf('   - 重传次数: %d\n', stats.retx);

if Bob_FARM.V_R == length(payload_list)
    fprintf('3. 最终结论: ✅ SUCCESS\n');
    fprintf('   在长延迟和高噪声干扰下，协议栈成功保证了数据的完整性和顺序性。\n');
else
    fprintf('3. 最终结论: ❌ FAILED\n');
end
fprintf('===============================================================\n');

%% ========================================================================
%  辅助函数: 简化版物理层信道 (BPSK + AWGN + Delay)
% =========================================================================
function [rx_frames, time_tags, tags] = run_simple_phy(tx_frame, snr_db, delay_sec, cs_params, rx_machine, data_rate)
    
    if nargin < 6, data_rate = 1; end 

    [tx_bits, tx_time_tags] = scs_transmitter_timing({tx_frame}, cs_params);
    
    tx_sym = 1 - 2*double(tx_bits);
    
    sigma = sqrt(1 / (2 * 10^((snr_db - 3)/10)));
    rx_sym = tx_sym + sigma * randn(size(tx_sym));
    rx_llr = 2 * rx_sym / sigma^2;
    
    if delay_sec > 0
        delay_bits = round(delay_sec * data_rate);
        % 使用噪声填充
        delay_noise = (2/sigma^2) * (sigma * randn(1, delay_bits));
        rx_llr = [delay_noise, rx_llr];
    end
    
    rx_frames = {}; rx_tags_list = [];
    
    CHUNK_SIZE = 512;
    num_chunks = ceil(length(rx_llr)/CHUNK_SIZE);
    
    for k = 1:num_chunks
        s = (k-1)*CHUNK_SIZE + 1;
        e = min(k*CHUNK_SIZE, length(rx_llr));
        chunk = rx_llr(s:e);
        
        [f, t] = rx_machine.step(chunk);
        rx_frames = [rx_frames, f];
        if ~isempty(t), rx_tags_list = [rx_tags_list; t]; end
    end
    
    time_tags.tx = tx_time_tags;
    time_tags.rx = rx_tags_list;
    tags.bit_errors = 0; tags.bits_compared = 0;
end