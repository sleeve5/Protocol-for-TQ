% BER vs SNR 仿真程序
% 功能：在不同信噪比下测试系统误码率性能

clc; clear all; close all;
addpath(genpath('data'), genpath('libs'));

%% 1. 仿真参数配置
% SNR扫描范围（dB）
snr_range = -5:2:15;  % 从-5dB到15dB，步长2dB
num_snr_points = length(snr_range);

% 系统参数（完整版）
params = struct(...
    'fs', 100e6,...                      % 采样率
    'prn_rate', 3.125e6,...              % 伪码速率
    'prn_length', 1024,...               % 伪码长度
    'data_length', 64,...                % 每组数据长度
    'repeat_times', 32,...               % ← 添加此字段（与lisa_com.m第53行一致）
    'b', 0.1,...                         % 伪码调制系数
    'remote_laser_freq', 281.95e12 + 10e6,...  % 远端激光频率
    'local_laser_freq', 281.95e12,...           % 本地激光频率
    'current_time', datestr(now, 'yyyy-mm-dd_HH-MM-SS')...
);

% 测试数据配置
total_data_bits = 6400;  % 总数据量（100组×64比特）
remote_data = randi([0, 1], 1, total_data_bits);
real_distance = 80000;  % 固定距离80km
params.real_distance = real_distance;

%% 2. 初始化结果存储
ber_results = zeros(1, num_snr_points);
range_error_results = zeros(1, num_snr_points);

%% 3. SNR扫描循环
fprintf('\n===== BER vs SNR 仿真开始 =====\n');
fprintf('SNR扫描范围：%d dB 到 %d dB\n', snr_range(1), snr_range(end));
fprintf('总数据量：%d 比特\n', total_data_bits);
fprintf('每组数据长度：%d 比特\n', params.data_length);
fprintf('重复传输次数：%d\n\n', params.repeat_times);

for snr_idx = 1:num_snr_points
    current_snr = snr_range(snr_idx);
    fprintf('正在仿真 SNR = %+2d dB (%2d/%2d)...\n', ...
        current_snr, snr_idx, num_snr_points);
    
    % 添加SNR参数
    params.snr_db = current_snr;
    
    % 调用仿真函数
    [result, ~] = lisa_com(remote_data, real_distance, params);
    
    % 保存结果
    ber_results(snr_idx) = result.total_ber;
    range_error_results(snr_idx) = result.avg_range_error;
    
    fprintf('  ├─ 误码率：%.6f (%.2f%%)\n', result.total_ber, result.total_ber*100);
    fprintf('  └─ 测距误差：%.2f 米\n\n', result.avg_range_error);
end

%% 4. 结果可视化
figure('Position', [100, 100, 1200, 500]);

% BER vs SNR 曲线（对数坐标）
subplot(1, 2, 1);
semilogy(snr_range, ber_results, 'o-', 'LineWidth', 2, 'MarkerSize', 8, ...
    'Color', [0.2, 0.6, 0.8]);
grid on;
xlabel('SNR (dB)', 'FontSize', 12, 'FontWeight', 'bold');
ylabel('误码率 (BER)', 'FontSize', 12, 'FontWeight', 'bold');
title('BER vs SNR 性能曲线', 'FontSize', 14, 'FontWeight', 'bold');
ylim([1e-4, 1]);  % 设置纵轴范围

% 测距误差 vs SNR 曲线
subplot(1, 2, 2);
plot(snr_range, range_error_results, 's-', 'LineWidth', 2, 'MarkerSize', 8, ...
    'Color', [0.8, 0.3, 0.3]);
grid on;
xlabel('SNR (dB)', 'FontSize', 12, 'FontWeight', 'bold');
ylabel('平均测距误差 (米)', 'FontSize', 12, 'FontWeight', 'bold');
title('测距误差 vs SNR', 'FontSize', 14, 'FontWeight', 'bold');

%% 5. 保存结果
results_dir = 'results';
if ~exist(results_dir, 'dir')
    mkdir(results_dir);
end

save_path = fullfile(results_dir, sprintf('ber_snr_%s.mat', params.current_time));
save(save_path, 'snr_range', 'ber_results', 'range_error_results', 'params', '-v7.3');

fig_path = fullfile(results_dir, sprintf('ber_snr_%s.jpg', params.current_time));
print(gcf, '-djpeg', '-r300', fig_path);

fprintf('\n===== 仿真完成 =====\n');
fprintf('数据已保存至：%s\n', save_path);
fprintf('图像已保存至：%s\n', fig_path);