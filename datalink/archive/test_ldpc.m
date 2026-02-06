%% Proximity-1 LDPC 全面性能分析 (SNR Version)
% =========================================================================
% 目标: 
%   1. 评估 CCSDS C2 LDPC (Rate 1/2) 的 BER/FER 性能。
%   2. 建立 [SNR] 与 [Raw BER / FER] 的直接映射关系。
% =========================================================================
clc; clear; close all;
clear functions; 
% 1. 环境初始化
script_dir = fileparts(mfilename('fullpath'));
if isempty(script_dir), script_dir = pwd; end
addpath(genpath(script_dir));
fprintf('=======================================================\n');
fprintf('    Proximity-1 LDPC 性能全景仿真 (SNR 模式)\n');
fprintf('=======================================================\n');

%% 2. 仿真参数
% 扫描范围 (根据 Rate 1/2 调整 SNR 范围)
range1 = -3 : 0.5 : -1.5;
range2 = -1.4 : 0.1 : - 0.5;
range3 = -0.25 : 0.25 : 0.25;
SNR_range = [range1 range2 range3];
% SNR_range = -3 : 0.25 : 0.25; 
% 仿真控制
K_INFO = 1024;
CODE_RATE = 1/2;
min_errors = 500;    
min_blocks = 5000;    
max_blocks = 50000;  

% 结果容器
res_snr      = zeros(size(SNR_range));
res_ber_raw  = zeros(size(SNR_range)); 
res_ber_post = zeros(size(SNR_range)); 
res_fer      = zeros(size(SNR_range)); 
res_blocks   = zeros(size(SNR_range)); 

h_wait = waitbar(0, '正在初始化...');

%% 3. 仿真主循环
for i = 1:length(SNR_range)
    SNR = SNR_range(i);

    % --- 核心逻辑：直接使用 SNR 计算噪声方差 ---
    % 对于 BPSK，EsN0 = SNR
    sigma = sqrt(1 / (2 * 10^(SNR/10)));

    % 统计计数器
    cnt_bit_err_raw  = 0;
    cnt_bit_err_post = 0;
    cnt_blk_err      = 0;
    cnt_total_bits_phy = 0; 
    cnt_total_bits_inf = 0; 
    cnt_total_blks   = 0;

    msg = sprintf('Simulating SNR = %.2f dB...', SNR);
    waitbar(i/length(SNR_range), h_wait, msg);
    fprintf('SNR = %.2f dB: ', SNR);

    while true
        % --- A. 数据生成与编码 ---
        num_batch = 50; 
        tx_info = randi([0 1], 1, K_INFO * num_batch) > 0.5;
        tx_stream = ldpc_encoder(tx_info);

        % --- B. 信道 (BPSK + AWGN) ---
        tx_sym = 1 - 2*double(tx_stream);
        noise = sigma * randn(size(tx_sym));
        rx_sym = tx_sym + noise;
        rx_llr = 2 * rx_sym / sigma^2;

        % --- C. 统计 Raw BER ---
        rx_hard_phy = rx_sym < 0;
        cnt_bit_err_raw = cnt_bit_err_raw + sum(tx_stream ~= rx_hard_phy);
        cnt_total_bits_phy = cnt_total_bits_phy + length(tx_stream);

        % --- D. 译码 ---
        rx_info_bits = ldpc_decoder(rx_llr);

        % --- E. 统计 Post-FEC BER & FER ---
        len = min(length(tx_info), length(rx_info_bits));
        tx_cut = tx_info(1:len);
        rx_cut = rx_info_bits(1:len);

        bit_diff = sum(tx_cut ~= rx_cut);
        cnt_bit_err_post = cnt_bit_err_post + bit_diff;
        cnt_total_bits_inf = cnt_total_bits_inf + len;

        tx_mat = reshape(tx_cut, K_INFO, []);
        rx_mat = reshape(rx_cut, K_INFO, []);
        blk_errs = any(tx_mat ~= rx_mat, 1);

        cnt_blk_err = cnt_blk_err + sum(blk_errs);
        cnt_total_blks = cnt_total_blks + num_batch;

        if (cnt_blk_err >= min_errors && cnt_total_blks >= min_blocks) || ...
           (cnt_total_blks >= max_blocks)
            break;
        end
    end

    res_snr(i)      = SNR;
    res_ber_raw(i)  = cnt_bit_err_raw / cnt_total_bits_phy;
    res_ber_post(i) = cnt_bit_err_post / cnt_total_bits_inf;
    res_fer(i)      = cnt_blk_err / cnt_total_blks;
    res_blocks(i)   = cnt_total_blks;

    fprintf('RawBER=%.4f | PostBER=%.2e | FER=%.2e (Blks:%d)\n', ...
        res_ber_raw(i), res_ber_post(i), res_fer(i), cnt_total_blks);
end
close(h_wait);

%% 4. 数据可视化
figure('Color', 'w', 'Position', [100, 100, 1400, 500]);
floor_val = 1e-7; 
plot_ber_raw  = res_ber_raw;
plot_ber_post = res_ber_post;
plot_fer      = res_fer;
plot_ber_post(plot_ber_post == 0) = floor_val;
plot_fer(plot_fer == 0)           = floor_val;

% 子图 1: BER
subplot(1, 3, 1);
semilogy(res_snr, plot_ber_raw, 'r-s', 'LineWidth', 1.5, 'DisplayName', '无编码');
hold on; grid on;
semilogy(res_snr, plot_ber_post, 'b-o', 'LineWidth', 1.5, 'DisplayName', 'LDPC 编码');
xlabel('SNR (dB)'); ylabel('误码率');
title('1. 误码率性能 (BER)');
legend; ylim([floor_val 1]);

% 子图 2: FER
subplot(1, 3, 2);
semilogy(res_snr, plot_fer, 'b-o', 'LineWidth', 1.5);
grid on;
xlabel('SNR (dB)'); ylabel('误块率（重传率）');
title('2. 重传率性能 (FER)');
ylim([floor_val 1.1]);

% 子图 3: BER vs FER
subplot(1, 3, 3);
[sorted_raw, idx_raw] = sort(res_ber_raw);
sorted_fer_raw = res_fer(idx_raw);
plot(sorted_raw * 100, sorted_fer_raw * 100, 'r-s', 'LineWidth', 1.5);
grid on;
xlabel('原始误码率(%)'); ylabel('误块率（重传率）(%)');
title('3. 原始误码率与重传关系');

%% 5. 保存结果
simulation_results.SNR_range = res_snr;
simulation_results.Raw_BER = res_ber_raw;
simulation_results.Post_BER = res_ber_post;
simulation_results.FER = res_fer;
simulation_results.Time = datestr(now, 'yyyy-mm-dd_HH-MM-SS');
save_filename = sprintf('LDPC_SNR_Results_%s.mat', simulation_results.Time);
save(fullfile(script_dir, save_filename), 'simulation_results');
fprintf('\n仿真完成，数据已保存至 %s\n', save_filename);
