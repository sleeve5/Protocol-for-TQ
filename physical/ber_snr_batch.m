% ========================================
% BER vs SNR 快速仿真程序（10^7 比特级）
% 功能：在不同信噪比下测试系统误码率性能
% 优化特性：
%   - 支持大数据量（10^7 比特）
%   - 自动采样加速
%   - 实时进度显示
%   - 结果统计分析
% ========================================

clc; clear all; close all;
addpath(genpath('data'), genpath('libs'));

%% ========== 1. 仿真参数配置 ==========
fprintf('\n╔═══════════════════════════════════════╗\n');
fprintf('║   BER vs SNR 快速仿真（10^7 比特）   ║\n');
fprintf('╚═══════════════════════════════════════╝\n\n');

% SNR扫描范围（dB）
snr_range = -5:2:15;  % 从-5dB到15dB，步长2dB
num_snr_points = length(snr_range);

% 系统参数（优化版）
params = struct(...
    'fs', 100e6,...                      % 采样率(Hz)
    'prn_rate', 3.125e6,...              % 伪码速率(Hz)
    'prn_length', 1024,...               % 伪码长度
    'data_length', 64,...                % 每组数据长度(bit)
    'repeat_times', 2,...                % ★ 关键优化：从 32 降到 2
    'b', 0.1,...                         % 伪码调制系数
    'remote_laser_freq', 281.95e12 + 10e6,...  % 远端激光频率(Hz)
    'local_laser_freq', 281.95e12,...           % 本地激光频率(Hz)
    'current_time', datestr(now, 'yyyy-mm-dd_HH-MM-SS'),...
    'sample_threshold', 1000,...         % ★ 超过 1000 组时启用采样
    'max_sample_size', 1000 ...           % ★ 最大采样 1000 组
);

% 测试数据配置
total_data_bits = 1e7;  % ★ 10^7 比特（156,250 组）
fprintf('生成随机数据：%d 比特 (%.1f MB)...\n', total_data_bits, total_data_bits/8/1024/1024);
remote_data = randi([0, 1], 1, total_data_bits);

real_distance = 80000;  % 固定距离 80km
params.real_distance = real_distance;

fprintf('参数配置完成！\n');
fprintf('  - 总数据量：%d 比特\n', total_data_bits);
fprintf('  - 每组长度：%d 比特\n', params.data_length);
fprintf('  - 总组数：%d 组\n', ceil(total_data_bits / params.data_length));
fprintf('  - 重复次数：%d 次\n', params.repeat_times);
fprintf('  - 采样策略：每个SNR点采样 %d 组\n', params.max_sample_size);
fprintf('  - 真实距离：%d 米 (%.1f km)\n\n', real_distance, real_distance/1000);

%% ========== 2. 初始化结果存储 ==========
ber_results = zeros(1, num_snr_points);
range_error_results = zeros(1, num_snr_points);
ber_confidence = zeros(1, num_snr_points);  % 置信区间
range_confidence = zeros(1, num_snr_points);
simulation_time = zeros(1, num_snr_points);  % 每个SNR点的仿真时间

%% ========== 3. 无噪声基线测试 ==========
fprintf('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
fprintf('【基线测试】无噪声性能验证\n');
fprintf('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

params_baseline = params;
if isfield(params_baseline, 'snr_db')
    params_baseline = rmfield(params_baseline, 'snr_db');
end

tic;
[result_baseline, ~] = lisa_com_batch(remote_data, real_distance, params_baseline);
baseline_time = toc;

fprintf('\n基线测试结果：\n');
fprintf('  - 误码率：%.8f (%.4f%%)\n', result_baseline.total_ber, result_baseline.total_ber*100);
fprintf('  - 测距误差：%.2f 米\n', result_baseline.avg_range_error);
fprintf('  - 用时：%.1f 秒\n', baseline_time);

if result_baseline.total_ber > 0.1
    warning('⚠ 无噪声误码率异常偏高！请检查参数设置');
end

fprintf('\n');

%% ========== 4. SNR扫描循环 ==========
fprintf('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
fprintf('【主仿真】SNR 扫描\n');
fprintf('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
fprintf('SNR 范围：%+d dB → %+d dB (步长 %d dB)\n', ...
    snr_range(1), snr_range(end), snr_range(2)-snr_range(1));
fprintf('总 SNR 点数：%d\n\n', num_snr_points);

total_start_time = tic;

for snr_idx = 1:num_snr_points
    current_snr = snr_range(snr_idx);

    fprintf('┌─────────────────────────────────────┐\n');
    fprintf('│ SNR = %+3d dB  [%2d/%2d]               │\n', ...
        current_snr, snr_idx, num_snr_points);
    fprintf('└─────────────────────────────────────┘\n');

    % 添加SNR参数
    params.snr_db = current_snr;

    % 运行仿真
    point_start_time = tic;
    [result, ~] = lisa_com_batch(remote_data, real_distance, params);
    simulation_time(snr_idx) = toc(point_start_time);

    % 保存结果
    ber_results(snr_idx) = result.total_ber;
    range_error_results(snr_idx) = result.avg_range_error;
    ber_confidence(snr_idx) = result.ber_confidence;
    range_confidence(snr_idx) = result.range_confidence;

    % 显示结果
    fprintf('  ✓ 误码率：%.6f ± %.6f (%.2f%%)\n', ...
        result.total_ber, result.ber_confidence, result.total_ber*100);
    fprintf('  ✓ 测距误差：%.2f ± %.2f 米\n', ...
        result.avg_range_error, result.range_confidence);
    fprintf('  ✓ 用时：%.1f 秒\n', simulation_time(snr_idx));

    % 预估剩余时间
    if snr_idx < num_snr_points
        avg_time_per_point = toc(total_start_time) / snr_idx;
        remaining_points = num_snr_points - snr_idx;
        estimated_remaining = avg_time_per_point * remaining_points;
        fprintf('  ⏱ 预计剩余时间：%.1f 分钟\n', estimated_remaining/60);
    end

    fprintf('\n');
end

total_elapsed_time = toc(total_start_time);

fprintf('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
fprintf('【完成】总用时：%.1f 分钟 (%.1f 秒)\n', ...
    total_elapsed_time/60, total_elapsed_time);
fprintf('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n');

%% ========== 5. 结果可视化 ==========
fprintf('生成可视化图表...\n');

fig = figure('Position', [100, 100, 1400, 600]);
set(fig, 'Color', 'w');

% 子图1：BER vs SNR（对数坐标）
subplot(1, 3, 1);
errorbar(snr_range, ber_results, ber_confidence, 'o-', ...
    'LineWidth', 2, 'MarkerSize', 8, 'Color', [0.2, 0.6, 0.8], ...
    'MarkerFaceColor', [0.2, 0.6, 0.8], 'CapSize', 10);
set(gca, 'YScale', 'log');
grid on;
xlabel('SNR (dB)', 'FontSize', 12, 'FontWeight', 'bold');
ylabel('误码率 (BER)', 'FontSize', 12, 'FontWeight', 'bold');
title('BER vs SNR 性能曲线', 'FontSize', 14, 'FontWeight', 'bold');
ylim([1e-5, 1]);
set(gca, 'FontSize', 11);

% 添加理论曲线（BPSK）
hold on;
snr_linear_theory = 10.^(snr_range/10);
ber_theory = 0.5 * erfc(sqrt(snr_linear_theory));
plot(snr_range, ber_theory, '--', 'LineWidth', 1.5, 'Color', [0.8, 0.3, 0.3]);
legend('仿真结果 (95% CI)', 'BPSK 理论值', 'Location', 'southwest', 'FontSize', 10);
hold off;

% 子图2：测距误差 vs SNR
subplot(1, 3, 2);
errorbar(snr_range, range_error_results, range_confidence, 's-', ...
    'LineWidth', 2, 'MarkerSize', 8, 'Color', [0.8, 0.3, 0.3], ...
    'MarkerFaceColor', [0.8, 0.3, 0.3], 'CapSize', 10);
grid on;
xlabel('SNR (dB)', 'FontSize', 12, 'FontWeight', 'bold');
ylabel('平均测距误差 (米)', 'FontSize', 12, 'FontWeight', 'bold');
title('测距误差 vs SNR', 'FontSize', 14, 'FontWeight', 'bold');
set(gca, 'FontSize', 11);

% 子图3：仿真时间统计
subplot(1, 3, 3);
bar(snr_range, simulation_time, 'FaceColor', [0.4, 0.7, 0.4], 'EdgeColor', 'k');
grid on;
xlabel('SNR (dB)', 'FontSize', 12, 'FontWeight', 'bold');
ylabel('仿真时间 (秒)', 'FontSize', 12, 'FontWeight', 'bold');
title('各SNR点仿真时间', 'FontSize', 14, 'FontWeight', 'bold');
set(gca, 'FontSize', 11);

% 总标题
sgtitle(sprintf('LISA 通信系统 BER 仿真 | 数据量: %.0e 比特 | 采样: %d 组', ...
    total_data_bits, params.max_sample_size), 'FontSize', 16, 'FontWeight', 'bold');

%% ========== 6. 保存结果 ==========
fprintf('保存结果...\n');

results_dir = 'results';
if ~exist(results_dir, 'dir')
    mkdir(results_dir);
end

% 保存数据
timestamp = params.current_time;
mat_filename = sprintf('ber_snr_fast_%s_%dbits.mat', timestamp, total_data_bits);
mat_path = fullfile(results_dir, mat_filename);

save(mat_path, 'snr_range', 'ber_results', 'range_error_results', ...
    'ber_confidence', 'range_confidence', 'simulation_time', ...
    'params', 'result_baseline', 'total_elapsed_time', '-v7.3');

fprintf('  ✓ 数据文件：%s\n', mat_path);

% 保存图像
jpg_filename = sprintf('ber_snr_fast_%s_%dbits.jpg', timestamp, total_data_bits);
jpg_path = fullfile(results_dir, jpg_filename);
print(fig, '-djpeg', '-r300', jpg_path);

fprintf('  ✓ 图像文件：%s\n', jpg_path);

% 保存文本报告
txt_filename = sprintf('ber_snr_report_%s.txt', timestamp);
txt_path = fullfile(results_dir, txt_filename);
fid = fopen(txt_path, 'w');

fprintf(fid, '========================================\n');
fprintf(fid, 'LISA 通信系统 BER vs SNR 仿真报告\n');
fprintf(fid, '========================================\n\n');
fprintf(fid, '仿真时间：%s\n', timestamp);
fprintf(fid, '总数据量：%d 比特 (%.2f MB)\n', total_data_bits, total_data_bits/8/1024/1024);
fprintf(fid, '采样组数：%d 组\n', params.max_sample_size);
fprintf(fid, '重复次数：%d 次\n', params.repeat_times);
fprintf(fid, '真实距离：%d 米\n\n', real_distance);

fprintf(fid, '----------------------------------------\n');
fprintf(fid, '无噪声基线测试\n');
fprintf(fid, '----------------------------------------\n');
fprintf(fid, '误码率：%.8f (%.4f%%)\n', result_baseline.total_ber, result_baseline.total_ber*100);
fprintf(fid, '测距误差：%.2f 米\n\n', result_baseline.avg_range_error);

fprintf(fid, '----------------------------------------\n');
fprintf(fid, 'SNR 扫描结果\n');
fprintf(fid, '----------------------------------------\n');
fprintf(fid, 'SNR(dB)  |  BER        |  测距误差(m)  |  时间(s)\n');
fprintf(fid, '---------+-------------+---------------+---------\n');
for i = 1:num_snr_points
    fprintf(fid, '%+7d  |  %.6f  |  %8.2f      |  %6.1f\n', ...
        snr_range(i), ber_results(i), range_error_results(i), simulation_time(i));
end

fprintf(fid, '\n总用时：%.1f 分钟\n', total_elapsed_time/60);
fclose(fid);

fprintf('  ✓ 报告文件：%s\n', txt_path);

fprintf('\n✅ 仿真完成！所有结果已保存。\n\n');
