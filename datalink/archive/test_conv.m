%% Proximity-1 Convolutional Code 全面性能分析 (SNR Version)
% =========================================================================
% 目标: 
%   1. 评估 CCSDS Proximity-1 卷积码 (K=7, Rate 1/2) 的 BER/FER 性能。
%   2. 对比 [Raw BER] (信道质量) 与 [Post BER] (解码后质量)。
%   3. 找出 "图像清晰" (BER < 1e-5) 所需的 SNR 门限。
% =========================================================================
clc; clear; close all;
clear functions; 

% 1. 环境初始化
script_dir = fileparts(mfilename('fullpath'));
if isempty(script_dir), script_dir = pwd; end
addpath(genpath(script_dir));
fprintf('=======================================================\n');
fprintf('    Proximity-1 Convolutional Code 性能仿真 (SNR 模式)\n');
fprintf('=======================================================\n');

%% 2. 仿真参数
% 扫描范围 (根据 Conv Code K=7 特性调整)
% Conv 码通常在 Eb/No 4.5dB (SNR 1.5dB) 左右达到极低误码
range1 = -2.0 : 0.5 : 0.0;    % 低信噪比区 (性能可能差于 BPSK)
range2 =  0.0 : 0.2 : 2.0;    % 瀑布区 (性能剧烈变化)
range3 =  2.5 : 0.5 : 4.0;    % 无误码区
SNR_range = [range1 range2 range3];

% 仿真控制
K_INFO = 1000;       % 每帧信息比特数
min_errors = 300;    % 累计最少错误数 (保证统计显著性)
min_blocks = 2000;   % 最少跑多少帧
max_blocks = 20000;  % 最多跑多少帧 (防死循环)

% 结果容器
res_snr      = zeros(size(SNR_range));
res_ber_raw  = zeros(size(SNR_range)); % 未编码(信道)误���率
res_ber_post = zeros(size(SNR_range)); % 编码后误码率
res_fer      = zeros(size(SNR_range)); % 误帧率
res_blocks   = zeros(size(SNR_range)); 

h_wait = waitbar(0, '正在初始化...');

%% 3. 仿真主循环
for i = 1:length(SNR_range)
    SNR = SNR_range(i);

    % --- 核心逻辑：直接使用 SNR 计算噪声方差 ---
    % SNR = Es/N0 (符号信噪比)
    % sigma = sqrt(N0/2) = sqrt(1 / (2 * SNR_linear))
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
    fprintf('SNR = %5.2f dB: ', SNR);

    while true
        % --- A. 数据生成 ---
        num_batch = 20; % 批次处理
        tx_info = randi([0 1], 1, K_INFO * num_batch); % 生成逻辑向量
        
        % --- B. 卷积编码 (Rate 1/2) ---
        % 注意：这里将长流一次性送入，模拟流式传输，或分块截断
        % 为简单起见，我们将 batch 视为一个长包
        tx_stream = convolutional_encoder(tx_info);

        % --- C. 信道 (BPSK + AWGN) ---
        % 0 -> +1, 1 -> -1 (由编码器 G2 反转后直接映射)
        tx_sym = 1 - 2*double(tx_stream);
        
        noise = sigma * randn(size(tx_sym));
        rx_sym = tx_sym + noise;
        
        % LLR 计算
        rx_llr = 2 * rx_sym / sigma^2;

        % --- D. 统计 Raw BER (未编码前的物理层误码) ---
        % 硬判决: >0 为 0, <0 为 1
        rx_hard_phy = rx_sym < 0; 
        cnt_bit_err_raw = cnt_bit_err_raw + sum(tx_stream(:) ~= rx_hard_phy(:));
        cnt_total_bits_phy = cnt_total_bits_phy + length(tx_stream);

        % --- E. 卷积译码 ---
        rx_info_bits = convolutional_decoder(rx_llr);

        % --- F. 统计 Post-FEC BER & FER ---
        % 确保长度匹配 (decoder 输出是列向量，转为行向量对比)
        rx_info_bits = rx_info_bits(:)';
        tx_info = tx_info(:)';
        
        len = min(length(tx_info), length(rx_info_bits));
        tx_cut = tx_info(1:len);
        rx_cut = rx_info_bits(1:len);

        % 误比特统计
        bit_diff = sum(tx_cut ~= rx_cut);
        cnt_bit_err_post = cnt_bit_err_post + bit_diff;
        cnt_total_bits_inf = cnt_total_bits_inf + len;

        % 误帧(块)统计
        tx_mat = reshape(tx_cut, K_INFO, []);
        rx_mat = reshape(rx_cut, K_INFO, []);
        blk_errs = any(tx_mat ~= rx_mat, 1); % 每一列是一帧

        cnt_blk_err = cnt_blk_err + sum(blk_errs);
        cnt_total_blks = cnt_total_blks + length(blk_errs);

        % 退出条件: 错误数足够 或 跑了足够多的块
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
floor_val = 1e-7; % 对数坐标下 0 的替代值
plot_ber_raw  = res_ber_raw;
plot_ber_post = res_ber_post;
plot_fer      = res_fer;

% 处理 0 值以便绘图
plot_ber_post(plot_ber_post == 0) = floor_val;
plot_fer(plot_fer == 0)           = floor_val;

% 子图 1: BER 对比
subplot(1, 3, 1);
semilogy(res_snr, plot_ber_raw, 'r-s', 'LineWidth', 1.5, 'DisplayName', '无编码 (Raw Channel)');
hold on; grid on;
semilogy(res_snr, plot_ber_post, 'b-o', 'LineWidth', 2.0, 'MarkerFaceColor', 'b', 'DisplayName', '卷积编码 (Post-Viterbi)');
yline(1e-5, 'k--', 'Clear Image Threshold'); % 清晰图像阈值线
xlabel('SNR (dB) [Es/N0]'); ylabel('误码率 (BER)');
title('1. 误码率性能对比 (BER)');
legend('Location', 'SouthWest'); ylim([floor_val 1]);

% 子图 2: FER 性能
subplot(1, 3, 2);
semilogy(res_snr, plot_fer, 'g-^', 'LineWidth', 1.5, 'MarkerFaceColor', 'g');
grid on;
xlabel('SNR (dB) [Es/N0]'); ylabel('误帧率 (FER)');
title(['2. 帧错误率 (Frame Size = ' num2str(K_INFO) ')']);
ylim([floor_val 1.1]);

% 子图 3: 编码增益可视化
subplot(1, 3, 3);
semilogy(res_snr, plot_ber_raw ./ plot_ber_post, 'm-', 'LineWidth', 2);
grid on;
xlabel('SNR (dB)'); ylabel('改善倍数 (Raw / Post)');
title('3. 编码带来的改善倍数');
ylim([0.1 1e5]);

% %% 5. 保存结果
% sim_results.SNR_range = res_snr;
% sim_results.Raw_BER = res_ber_raw;
% sim_results.Post_BER = res_ber_post;
% sim_results.FER = res_fer;
% sim_results.Time = datestr(now, 'yyyy-mm-dd_HH-MM-SS');
% save_filename = sprintf('Conv_SNR_Results_%s.mat', sim_results.Time);
% save(fullfile(script_dir, save_filename), 'sim_results');
% fprintf('\n仿真完成，数据已保存至 %s\n', save_filename);