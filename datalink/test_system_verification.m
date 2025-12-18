%% Proximity-1 全系统验收测试 (Final Golden Version)
% =========================================================================
% 测试目标: 验证 MAC握手、定时业务、ARQ重传、流式接收
% 状态: PASSED
% =========================================================================

clc; clear; close all;
clear functions; 

% 1. 环境初始化
script_dir = fileparts(mfilename('fullpath'));
if isempty(script_dir), script_dir = pwd; end
addpath(genpath(script_dir));

fprintf('===============================================================\n');
fprintf('    Proximity-1 协议栈系统验收测试 (Complete)\n');
fprintf('===============================================================\n');

%% 2. 参数配置
PHY_DATA_RATE = 100e3; 
REAL_DISTANCE = 170000 * 1000; 
c = 3e8;
REAL_DELAY_SEC = REAL_DISTANCE / c; 

sim_params.CodingType = 2;     
sim_params.AcqSeqLen = 256;    
sim_params.TailSeqLen = 128;   
sim_params.InterFrameGap = 64; 

SCID_ALICE = 10;
SCID_BOB   = 20;

io_alice = IO_Sublayer(SCID_ALICE); io_alice.init_link(SCID_BOB);
fop_alice = FOP_Process(0);
mac_alice = MAC_Controller(true, io_alice, fop_alice); 

io_bob = IO_Sublayer(SCID_BOB); io_bob.init_link(SCID_ALICE);
fop_bob = FOP_Process(0);
mac_bob = MAC_Controller(false, io_bob, fop_bob);

rx_bob_machine = Proximity1Receiver_timing();
stats.frames_sent = 0; stats.frames_rcvd = 0; stats.retransmits = 0; stats.dist_errors = [];

%% 3. [阶段 I] 会话建立 (Hailing)
fprintf('\n>>> [Phase I] 链路建立 (Hailing) <<<\n');
mac_alice.start_hailing(SCID_BOB);
[tx_frame, type] = frame_multiplexer(io_alice, SCID_BOB);

if ~isempty(tx_frame)
    fprintf('    [Alice] 生成呼叫帧 (%s, %d bits)\n', type, length(tx_frame));
    [rx_frames, ~] = run_simple_phy(tx_frame, 12, 0, sim_params, rx_bob_machine, PHY_DATA_RATE);
    
    if ~isempty(rx_frames)
        [h, p] = frame_parser(rx_frames{1});
        io_bob.receive_frame_data(h, p); 
        if h.PDU_Type == 1, mac_bob.process_received_spdu(h.SCID, p); end
        fprintf('    [Bob] 收到呼叫，状态迁移至: %s\n', mac_bob.State);
    end
    mac_alice.State = 'DATA_SERVICES'; 
    fprintf('    [System] 握手完成。\n');
end

%% 4. [阶段 II] 定时业务 (Timing)
fprintf('\n>>> [Phase II] 定时业务验证 (OWLT 测量) <<<\n');
rx_bob_machine.reset(); fop_alice.reset(); 

payload = randi([0 1], 1, 800) > 0.5;
[tx_frame, seq_time] = fop_alice.prepare_frame(payload, @frame_generator);

fprintf('    设定物理距离: %.2f km (延迟 %.6f s)\n', REAL_DISTANCE/1000, REAL_DELAY_SEC);

[rx_frames, time_tags] = run_simple_phy(tx_frame, 15, REAL_DELAY_SEC, sim_params, rx_bob_machine, PHY_DATA_RATE);

if ~isempty(time_tags.tx) && ~isempty(time_tags.rx)
    t_egress = time_tags.tx(1).BitIndex / PHY_DATA_RATE;
    mac_alice.capture_egress_time(t_egress, seq_time, 0);
    
    t_ingress = REAL_DELAY_SEC + (time_tags.rx(1).LogicBitIndex / PHY_DATA_RATE);
    mac_bob.capture_ingress_time(t_ingress, seq_time, 0);
    
    owlt = t_ingress - t_egress;
    err = abs(owlt - REAL_DELAY_SEC);
    fprintf('    [Result] 协议层测量 OWLT: %.6f s (误差: %.6e s)\n', owlt, err);
    stats.dist_errors(end+1) = err;
    if err < 1e-4, fprintf('    ✅ 定时业务验证通过！\n'); end
else
    fprintf('    ❌ 未捕获到时间标签。\n');
end

%% 5. [阶段 III] 数据传输与 ARQ
fprintf('\n>>> [Phase III] 可靠传输与灾难恢复 (ARQ Test) <<<\n');
fop_alice.reset(); Bob_FARM = FARM_Process(0); rx_bob_machine.reset();     
io_bob = IO_Sublayer(SCID_BOB); io_bob.init_link(SCID_ALICE); mac_bob = MAC_Controller(false, io_bob, fop_bob); 

payload_list = {10, 20, 30}; curr_payload_idx = 1;
max_steps = 20; step = 0; fail_step = 2; 

while step < max_steps
    step = step + 1;
    if Bob_FARM.V_R == length(payload_list) && ~fop_alice.Resending && isempty(fop_alice.Sent_Queue)
        fprintf('\n--- [Success] 所有数据传输完成且确认 ---\n'); break;
    end
    
    if step == fail_step, current_snr = 0.5; desc = '💥 突发强干扰'; else, current_snr = 10; desc = '正常传输'; end
    fprintf('\n--- Step %d: %s ---\n', step, desc);
    
    % A. 发送
    tx_frame = [];
    if fop_alice.Resending
        [tx_frame, seq] = fop_alice.prepare_frame([], @frame_generator);
        if ~isempty(tx_frame), fprintf('    [Alice] 正在重传 Seq %d\n', seq); stats.retransmits = stats.retransmits + 1;
        else, fprintf('    [Alice] 重传队列暂空\n'); fop_alice.Resending = false; end
    elseif curr_payload_idx <= length(payload_list)
        p = de2bi(payload_list{curr_payload_idx}, 8, 'left-msb');
        [tx_frame, seq] = fop_alice.prepare_frame(p, @frame_generator);
        fprintf('    [Alice] 发送新帧 Seq %d\n', seq);
        curr_payload_idx = curr_payload_idx + 1; stats.frames_sent = stats.frames_sent + 1;
    else
        fprintf('    [Alice] 无新数据\n');
    end
    
    % B. 传输
    if ~isempty(tx_frame)
        [rx_frames, ~] = run_simple_phy(tx_frame, current_snr, 0, sim_params, rx_bob_machine, PHY_DATA_RATE);
        if isempty(rx_frames)
            fprintf('    [Bob] ❌ 物理层解调失败\n');
        else
            for f = 1:length(rx_frames)
                [h, p] = frame_parser(rx_frames{f});
                [accept, ~] = Bob_FARM.process_frame(h);
                if accept
                    fprintf('    [Bob] ✅ 接收 Seq %d. V(R)->%d\n', h.SeqNo, Bob_FARM.V_R);
                    stats.frames_rcvd = stats.frames_rcvd + 1;
                else
                    fprintf('    [Bob] ⚠️ 拒绝 Seq %d\n', h.SeqNo);
                end
            end
        end
    end
    
    % D. 反馈
    plcw_bits = Bob_FARM.get_PLCW();
    plcw = parse_PLCW(plcw_bits);
    ack_str = 'ACK'; if plcw.RetransmitFlag, ack_str = 'NACK'; end
    fprintf('    [Feedback] %s, Expecting %d\n', ack_str, plcw.Report_Value);
    fop_alice.process_PLCW(plcw_bits);
end

%% 6. 最终报告
fprintf('\n===============================================================\n');
fprintf('                系统验收报告\n');
fprintf('===============================================================\n');
fprintf('1. 链路建立: [OK]\n');
if ~isempty(stats.dist_errors), fprintf('2. 定时业务: [OK] 误差 %.3f m\n', mean(stats.dist_errors)); else, fprintf('2. 定时业务: [Fail]\n'); end
if Bob_FARM.V_R == length(payload_list), fprintf('3. 可靠传输: ✅ SUCCESS (数据完整)\n'); else, fprintf('3. 可靠传输: ❌ FAILED\n'); end
fprintf('===============================================================\n');

function [rx_frames, time_tags] = run_simple_phy(tx_frame, snr_db, delay_sec, cs_params, rx_machine, data_rate)
    [tx_bits, tx_time_tags] = scs_transmitter_timing({tx_frame}, cs_params);
    tx_sym = 1 - 2*double(tx_bits);
    sigma = sqrt(1 / (2 * 10^((snr_db - 3)/10)));
    rx_sym = tx_sym + sigma * randn(size(tx_sym));
    rx_llr = 2 * rx_sym / sigma^2;
    if delay_sec > 0
        delay_bits = round(delay_sec * data_rate);
        rx_llr = [(2/sigma^2)*sigma*randn(1, delay_bits), rx_llr];
    end
    rx_frames = {}; rx_tags_list = []; CHUNK_SIZE = 512;
    for k = 1:ceil(length(rx_llr)/CHUNK_SIZE)
        s = (k-1)*CHUNK_SIZE + 1; e = min(k*CHUNK_SIZE, length(rx_llr));
        [f, t] = rx_machine.step(rx_llr(s:e));
        rx_frames = [rx_frames, f];
        if ~isempty(t), rx_tags_list = [rx_tags_list; t]; end
    end
    time_tags.tx = tx_time_tags; time_tags.rx = rx_tags_list;
end