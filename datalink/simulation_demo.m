%% Proximity-1 仿真结果可视化生成器 (For PPT) - Fixed
% =========================================================================
% 功能: 运行一次完整的 17万公里 ARQ 仿真，并记录所有中间状态，
%       最后生成三张用于 PPT 展示的高质量图表。
% 修复: 修正变量名 ONE_WAY_DELAY -> REAL_DELAY_SEC
% =========================================================================

clc; clear; close all;
clear functions; 
addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('正在生成仿真数据并绘图，请稍候...\n');

%% 1. 初始化与配置
PHY_DATA_RATE = 128e3; 
REAL_DISTANCE = 170000 * 1000; 
c = 3e8;
REAL_DELAY_SEC = REAL_DISTANCE / c; % [定义变量名]

sim_params.CodingType = 2;     
sim_params.AcqSeqLen = 512;    
sim_params.TailSeqLen = 128;   
sim_params.InterFrameGap = 64; 

SCID_ALICE = 10; SCID_BOB = 20;

io_alice = IO_Sublayer(SCID_ALICE); io_alice.init_link(SCID_BOB);
fop_alice = FOP_Process(0); 
fop_alice.TIMEOUT_THRESHOLD = 4; 
mac_alice = MAC_Controller(true, io_alice, fop_alice); 

io_bob = IO_Sublayer(SCID_BOB); io_bob.init_link(SCID_ALICE);
fop_bob = FOP_Process(0);
mac_bob = MAC_Controller(false, io_bob, fop_bob);
Bob_FARM = FARM_Process(0);
rx_bob_machine = Proximity1Receiver_timing();

% --- 数据记录器 ---
log_step = [];
log_snr = [];
log_action_tx = {}; 
log_seq_tx = [];    
log_seq_rx_ack = []; 
log_frame_status = {}; 
log_ranging_err = [];

%% 2. 仿真执行 (ARQ 场景)
payload_list = {1, 2, 3, 4, 5}; 
curr_payload_idx = 1;

max_steps = 25;
fail_step_start = 3;
fail_step_end = 3; 

% Phase I: Hailing (快速跳过)
mac_alice.start_hailing(SCID_BOB);
[tx_frame, ~] = frame_multiplexer(io_alice, SCID_BOB);

% [修正点] 这里使用 REAL_DELAY_SEC
run_simple_phy(tx_frame, 12, REAL_DELAY_SEC, sim_params, rx_bob_machine, PHY_DATA_RATE);
mac_alice.State = 'DATA_SERVICES';

% Phase II: Data Transfer Loop
for step = 1:max_steps
    % 终止条件
    if Bob_FARM.V_R == length(payload_list) && ~fop_alice.Resending && isempty(fop_alice.Sent_Queue)
        break;
    end
    
    log_step(end+1) = step;
    
    if step >= fail_step_start && step <= fail_step_end
        current_snr = 0.5; % 丢包
        channel_status = 'Bad';
    else
        current_snr = 10;
        channel_status = 'Good';
    end
    log_snr(end+1) = current_snr;
    
    % --- Alice Tx ---
    tx_frame = [];
    current_action = 'Idle';
    current_seq = NaN;
    
    if fop_alice.Resending
        [tx_frame, seq] = fop_alice.prepare_frame([], @frame_generator);
        if ~isempty(tx_frame)
            current_action = 'Resend';
            current_seq = seq;
        end
    elseif curr_payload_idx <= length(payload_list)
        p = de2bi(payload_list{curr_payload_idx}, 8, 'left-msb');
        [tx_frame, seq] = fop_alice.prepare_frame(p, @frame_generator);
        current_action = 'New';
        current_seq = seq;
        curr_payload_idx = curr_payload_idx + 1;
    end
    
    log_action_tx{end+1} = current_action;
    log_seq_tx(end+1) = current_seq;
    
    % --- PHY & Rx ---
    frame_status = 'None'; 
    meas_err = NaN;
    
    if ~isempty(tx_frame)
        [rx_frames, time_tags] = run_simple_phy(tx_frame, current_snr, REAL_DELAY_SEC, sim_params, rx_bob_machine, PHY_DATA_RATE);
        
        if isempty(rx_frames)
            frame_status = 'Lost'; 
        else
            for f = 1:length(rx_frames)
                [h, ~] = frame_parser(rx_frames{f});
                [accept, ~] = Bob_FARM.process_frame(h);
                if accept
                    frame_status = 'Accepted';
                    if ~isempty(time_tags.rx)
                        t_tx = time_tags.tx(1).BitIndex / PHY_DATA_RATE;
                        t_rx = REAL_DELAY_SEC + time_tags.rx(1).LogicBitIndex / PHY_DATA_RATE;
                        owlt = t_rx - t_tx;
                        meas_err = abs(owlt - REAL_DELAY_SEC) * 3e8; 
                    end
                else
                    frame_status = 'Rejected'; 
                end
            end
        end
    end
    log_frame_status{end+1} = frame_status;
    log_ranging_err(end+1) = meas_err;
    
    % --- Feedback ---
    plcw_bits = Bob_FARM.get_PLCW();
    plcw = parse_PLCW(plcw_bits);
    log_seq_rx_ack(end+1) = plcw.Report_Value;
    fop_alice.process_PLCW(plcw_bits);
end

%% 3. 绘图生成

% --- 图表 1: ARQ 协议交互时序图 ---
fig1 = figure('Color', 'w', 'Position', [100, 100, 1000, 600]);
hold on; grid on;

steps = log_step;
valid_tx = ~isnan(log_seq_tx);
stem(steps(valid_tx), log_seq_tx(valid_tx), 'bo-', 'LineWidth', 1.5, 'MarkerSize', 8, 'DisplayName', 'Alice发送(Seq)');
stairs(steps, log_seq_rx_ack, 'g-', 'LineWidth', 2, 'DisplayName', 'Bob确认(ACK)');

for i = 1:length(steps)
    if strcmp(log_frame_status{i}, 'Lost')
        plot(steps(i), log_seq_tx(i), 'rx', 'MarkerSize', 15, 'LineWidth', 2, 'HandleVisibility', 'off');
        text(steps(i), log_seq_tx(i)+0.3, 'Lost', 'Color', 'r', 'HorizontalAlignment', 'center');
    elseif strcmp(log_frame_status{i}, 'Rejected')
        plot(steps(i), log_seq_tx(i), 'mo', 'MarkerSize', 10, 'LineWidth', 2, 'HandleVisibility', 'off');
        text(steps(i), log_seq_tx(i)+0.3, 'Reject', 'Color', 'm', 'HorizontalAlignment', 'center');
    elseif strcmp(log_action_tx{i}, 'Resend')
        text(steps(i), log_seq_tx(i)-0.3, 'Retx', 'Color', 'b', 'HorizontalAlignment', 'center');
    end
end

xlabel('仿真时间步 (Simulation Step)');
ylabel('帧序列号 (Sequence Number)');
title('Proximity-1 COP-P (ARQ) 协议交互时序图');
legend('Location', 'SouthEast');
ylim([-0.5 6]);

% --- 图表 2: 测距误差分布图 ---
fig2 = figure('Color', 'w', 'Position', [150, 150, 800, 400]);
valid_range = ~isnan(log_ranging_err);
range_data = log_ranging_err(valid_range);
bar(range_data, 0.5, 'FaceColor', [0.2 0.6 0.8]);
grid on;
xlabel('成功接收帧序号');
ylabel('测距误差 (米)');
title(sprintf('17万公里链路单向光行时(OWLT)测距误差\n(平均误差: %.4f m)', mean(range_data)));
yline(3.0, 'r--', '系统采样分辨率限制 (3m)');

% --- 图表 3: 信道状态与吞吐量 ---
fig3 = figure('Color', 'w', 'Position', [200, 200, 800, 400]);
yyaxis left
plot(steps, log_snr, 'k-', 'LineWidth', 1);
ylabel('信道信噪比 (dB)');
yline(2.0, 'r--', 'LDPC门限');

yyaxis right
cum_success = zeros(size(steps));
count = 0;
for i=1:length(steps)
    if strcmp(log_frame_status{i}, 'Accepted'), count=count+1; end
    cum_success(i) = count;
end
plot(steps, cum_success, 'm-^', 'LineWidth', 2, 'MarkerFaceColor', 'm');
ylabel('累计成功接收帧数');
xlabel('仿真时间步');
title('信道质量对吞吐量的影响');
legend('SNR', 'Throughput');


%% 辅助函数
function [rx_frames, time_tags] = run_simple_phy(tx_frame, snr_db, delay_sec, cs_params, rx_machine, data_rate)
    if nargin < 6, data_rate = 1; end 
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