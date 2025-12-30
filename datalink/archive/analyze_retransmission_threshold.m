%% Proximity-1 LDPC 全面性能分析 (All-in-One + Save Results)
% =========================================================================
% 目标: 
%   1. 评估 CCSDS C2 LDPC (Rate 1/2) 的 BER/FER 性能。
%   2. 建立 [物理层原始误码率 Raw BER] 与 [链路层重传率 FER] 的直接映射关系。
%   3. [新增] 保存详细的仿真结果数据到本地文件。
%
% 逻辑:
%   FER (误块率) == 重传概率 (因为 CRC 失败必重传)
%   通过一次仿真循环，同时收集 SNR, RawBER, PostBER, FER 数据。
% =========================================================================

clc; clear; close all;
clear functions; % 清除持久变量

% 1. 环境初始化
script_dir = fileparts(mfilename('fullpath'));
if isempty(script_dir), script_dir = pwd; end
addpath(genpath(script_dir));

fprintf('=======================================================\n');
fprintf('    Proximity-1 LDPC 性能全景仿真 (Starting...)\n');
fprintf('=======================================================\n');

%% 2. 仿真参数

% 扫描范围 (0dB - 3.2dB 是 Rate 1/2 的关键变化区)
EbN0_range = 0 : 0.25 : 3.25; 

% 仿真控制
K_INFO = 1024;
CODE_RATE = 1/2;
min_errors = 500;    % 最少收集错误帧数 (保证FER准确性)
min_blocks = 5000;    % 最少仿真块数
max_blocks = 100000;  % 最大仿真块数

% 结果容器
res_snr      = zeros(size(EbN0_range));
res_ber_raw  = zeros(size(EbN0_range)); % 物理层误码率
res_ber_post = zeros(size(EbN0_range)); % 译码后误码率
res_fer      = zeros(size(EbN0_range)); % 误帧率 (重传率)
res_blocks   = zeros(size(EbN0_range)); % 实际仿真块数 (新增统计)

h_wait = waitbar(0, '正在初始化...');

%% 3. 仿真主循环
for i = 1:length(EbN0_range)
    EbN0 = EbN0_range(i);
    
    % 噪声计算
    EsN0 = EbN0 + 10*log10(CODE_RATE);
    sigma = sqrt(1 / (2 * 10^(EsN0/10)));
    
    % 统计计数器
    cnt_bit_err_raw  = 0;
    cnt_bit_err_post = 0;
    cnt_blk_err      = 0;
    cnt_total_bits_phy = 0; % 物理层总比特 (含校验)
    cnt_total_bits_inf = 0; % 信息层总比特
    cnt_total_blks   = 0;
    
    msg = sprintf('Simulating %.2f dB...', EbN0);
    waitbar(i/length(EbN0_range), h_wait, msg);
    fprintf('Eb/N0 = %.2f dB: ', EbN0);
    
    while true
        % --- A. 数据生成与编码 ---
        num_batch = 50; % 批处理加速 (增大批次以提高大块仿真速度)
        tx_info = randi([0 1], 1, K_INFO * num_batch) > 0.5;
        
        % 调用底层编码器 (含 CSM+Randomization)
        % 兼容新旧函数名
        tx_stream = ldpc_encoder(tx_info);
        
        % --- B. 信道 (BPSK + AWGN) ---
        tx_sym = 1 - 2*double(tx_stream);
        noise = sigma * randn(size(tx_sym));
        rx_sym = tx_sym + noise;
        rx_llr = 2 * rx_sym / sigma^2;
        
        % --- C. 统计 Raw BER (物理层健康度) ---
        % 统计范围: 整个物理层码流 (CSM + Code)
        % CSM 是非编码的，Code 是编码的，Raw BER 反映信道本身的恶劣程度
        rx_hard_phy = rx_sym < 0;
        cnt_bit_err_raw = cnt_bit_err_raw + sum(tx_stream ~= rx_hard_phy);
        cnt_total_bits_phy = cnt_total_bits_phy + length(tx_stream);
        
        % --- D. 译码 (理想同步假设) ---
        % 假设同步完美，直接送入译码器
        rx_info_bits = ldpc_decoder(rx_llr);
        
        % --- E. 统计 Post-FEC BER & FER ---
        % 维度对齐
        len = min(length(tx_info), length(rx_info_bits));
        tx_cut = tx_info(1:len);
        rx_cut = rx_info_bits(1:len);
        
        % 1. 比特误码
        bit_diff = sum(tx_cut ~= rx_cut);
        cnt_bit_err_post = cnt_bit_err_post + bit_diff;
        cnt_total_bits_inf = cnt_total_bits_inf + len;
        
        % 2. 误块 (Frame Error) -> 等同于重传
        tx_mat = reshape(tx_cut, K_INFO, []);
        rx_mat = reshape(rx_cut, K_INFO, []);
        % 每一列是一个块，只要列里有 1 个错，该块就是错的
        blk_errs = any(tx_mat ~= rx_mat, 1);
        
        cnt_blk_err = cnt_blk_err + sum(blk_errs);
        cnt_total_blks = cnt_total_blks + num_batch;
        
        % --- 退出条件 ---
        % 收集到足够多的错误块，或者跑了足够多的总块数
        if (cnt_blk_err >= min_errors && cnt_total_blks >= min_blocks) || ...
           (cnt_total_blks >= max_blocks)
            break;
        end
    end
    
    % 记录结果
    res_snr(i)      = EbN0;
    res_ber_raw(i)  = cnt_bit_err_raw / cnt_total_bits_phy;
    res_ber_post(i) = cnt_bit_err_post / cnt_total_bits_inf;
    res_fer(i)      = cnt_blk_err / cnt_total_blks;
    res_blocks(i)   = cnt_total_blks; % 记录实际跑的块数
    
    fprintf('RawBER=%.4f | PostBER=%.2e | FER=%.2e (Blks:%d)\n', ...
        res_ber_raw(i), res_ber_post(i), res_fer(i), cnt_total_blks);
end
close(h_wait);

%% 4. 数据可视化 (三图合一 & 双维分析)
figure('Color', 'w', 'Position', [100, 100, 1400, 500]);

% --- 数据预处理：处理 0 值以便 Log 绘图 ---
floor_val = 1e-7; % 稍微调小一点，适应更大的仿真量
plot_ber_raw  = res_ber_raw;
plot_ber_post = res_ber_post;
plot_fer      = res_fer;

% 将 0 替换为 floor_val
plot_ber_post(plot_ber_post == 0) = floor_val;
plot_fer(plot_fer == 0)           = floor_val;

% =========================================================================
% 子图 1: 误码率性能 (BER Waterfall)
% =========================================================================
subplot(1, 3, 1);
semilogy(res_snr, plot_ber_raw, 'r-s', 'LineWidth', 1.5, 'DisplayName', '无编码');
hold on; grid on;
semilogy(res_snr, plot_ber_post, 'b-o', 'LineWidth', 1.5, 'DisplayName', 'LDPC 编码');

xlabel('E_b/N_0 (dB)'); ylabel('误码率');
title('1. 误码率性能 (BER)');
legend('无编码', 'LDPC 编码');
ylim([floor_val 1]); xlim([0 3.5]);

% =========================================================================
% 子图 2: 重传率性能 (FER Waterfall)
% =========================================================================
subplot(1, 3, 2);
semilogy(res_snr, plot_fer, 'b-o', 'LineWidth', 1.5);
grid on;

xlabel('E_b/N_0 (dB)'); ylabel('误块率（重传率）');
title('2. 重传率性能 (FER)');
legend('LDPC 编码');
ylim([floor_val 1.1]); xlim([0 3.5]);

% =========================================================================
% 子图 3: 误码率与重传率的关系 (BER vs FER) - [您的需求]
% =========================================================================
subplot(1, 3, 3);

% 1. 曲线 A: 物理层原始误码率 vs 重传率 (红色)
% 需要排序以保证线条平滑
[sorted_raw, idx_raw] = sort(res_ber_raw);
sorted_fer_raw = res_fer(idx_raw);

p1 = plot(sorted_raw * 100, sorted_fer_raw * 100, 'r-s', ...
    'LineWidth', 1.5, 'DisplayName', '无编码');
hold on; grid on;

% 2. 曲线 B: 译码后残留误码率 vs 重传率 (蓝色)
[sorted_post, idx_post] = sort(res_ber_post);
sorted_fer_post = res_fer(idx_post);

p2 = plot(sorted_post * 100, sorted_fer_post * 100, 'b-o', ...
    'LineWidth', 1.5, 'DisplayName', 'LDPC 编码');

% 装饰
xlabel('误码率(%)'); 
ylabel('误块率（重传率）(%)');
title('3. 误码率与重传触发关系');
xlim([0 15]); ylim([-5 105]);
legend([p1, p2], 'Location', 'SouthEast');

%% 5. 保存结果 (关键功能)
% =========================================================================
% 将所有仿真数据打包保存为 .mat 文件
% =========================================================================

% 创建结果结构体
simulation_results.EbN0_range = EbN0_range;
simulation_results.Raw_BER = res_ber_raw;
simulation_results.Post_BER = res_ber_post;
simulation_results.FER = res_fer;
simulation_results.Total_Blocks = res_blocks;
simulation_results.Params = struct('K', K_INFO, 'Rate', CODE_RATE, ...
    'MinErr', min_errors, 'MinBlks', min_blocks, 'MaxBlks', max_blocks);
simulation_results.Time = datestr(now, 'yyyy-mm-dd_HH-MM-SS');

% 构造文件名 (含时间戳)
save_filename = sprintf('LDPC_Sim_Results_%s.mat', simulation_results.Time);
save_path = fullfile(script_dir, save_filename);

% 保存
save(save_path, 'simulation_results');

fprintf('\n=======================================================\n');
fprintf('    仿真完成！\n');
fprintf('    数据已保存至: %s\n', save_filename);
fprintf('    包含字段: Raw_BER, Post_BER, FER, Total_Blocks\n');
fprintf('=======================================================\n');