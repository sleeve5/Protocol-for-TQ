% 多组通信测试程序：LISA通信测距仿真
% 功能：生成测试数据，运行LISA通信测距仿真，输出结果并保存
% 修改 total_data_bits 以测试大量数据

%% 初始化环境：清空命令行、变量和图像窗口
clc; clear all; close all;


%% 1. 环境配置
% 添加数据文件夹和工具库路径
addpath(genpath('.\data'), genpath('.\libs'));

% 配置结果保存根路径
results_root = fullfile(pwd(), 'results');
% 若根文件夹不存在则自动创建
if ~exist(results_root, 'dir')
    mkdir(results_root);
    fprintf('已创建结果根文件夹：%s\n', results_root);
end


%% 2. 系统参数设置
% 定义仿真所需的系统参数，包括采样率、码速率、激光频率等
params = struct(...
    'fs', 100e6,...                      % 采样率(Hz)
    'prn_rate', 3.125e6,...              % 伪码速率(Hz)
    'prn_length', 1024,...               % 伪码序列长度
    'data_rate', 195.3125e3,...          % 通信速率(Hz，暂不参与仿真)
    'data_length', 64,...                % 每组数据的比特数
    'repeat_times', 2,...                % 数据重复传输次数
    'b', 0.1,...                         % 伪码调制系数
    'remote_laser_freq', 281.95e12 + 10e6,...   % 远端激光源频率(Hz)
    'local_laser_freq', 281.95e12,...           % 本地激光源频率(Hz)
    'current_time', datestr(now, 'yyyy-mm-dd_HH-MM-SS')...  % 仿真时间戳（用于结果命名）
);


%% 3. 生成测试数据
total_data_bits = 6400;  % 总通信数据长度（比特）
remote_data = randi([0, 1], 1, total_data_bits);  % 随机生成二进制通信数据
real_distance = randi([50000, 100000]);  % 随机生成真实距离(50-100km)
total_groups = ceil(total_data_bits / params.data_length);  % 计算数据分组总数
params.real_distance = real_distance;


%% 4. 运行通信测距仿真
% 输出仿真启动信息和关键参数
fprintf('\n===== LISA通信测距仿真启动 =====\n');
fprintf('仿真时间：%s\n', params.current_time);
fprintf('总数据长度：%d位\n', total_data_bits);
fprintf('每组数据长度：%d位\n', params.data_length);
fprintf('总分组数：%d组\n', total_groups);
fprintf('真实距离：%.2f米\n', real_distance);

% 调用仿真核心函数，返回结果结构体
[result, save_data] = lisa_com(remote_data, real_distance, params);


%% 5. 显示仿真结果
fprintf('\n===== 仿真结果汇总 =====\n');
% 显示综合误码率
if ~isnan(result.total_ber)
    fprintf('综合误码率：%.8f\n', result.total_ber);
else
    fprintf('综合误码率：无有效分组（NaN）\n');
end
% 显示平均测距误差
if ~isnan(result.avg_range_error)
    fprintf('平均测距误差：%.2f米\n', result.avg_range_error);
else
    fprintf('平均测距误差：无有效分组（NaN）\n');
end
fprintf('\n===== 仿真完成 =====\n');
fprintf('已处理全部%d组数据\n', result.total_groups);


%% 6. 绘制仿真结果图表
% 创建图像窗口并设置尺寸
fig_handle = figure('Position', [100, 100, 800, 600]);
sgtitle('LISA通信测距仿真结果', 'FontSize', 14, 'FontWeight', 'bold');  % 图表总标题

% 绘制各组误码率曲线
subplot(2, 1, 1);
ber_values = [result.group_results.ber];  % 提取所有组的误码率
plot(1:result.total_groups, ber_values, 'o-', ...
    'LineWidth', 1.2, 'MarkerSize', 6, 'Color', [0.2, 0.6, 0.8]);
title('各组误码率', 'FontSize', 12);
xlabel('组号', 'FontSize', 10);
ylabel('误码率', 'FontSize', 10);
grid on; grid minor;  % 显示网格线，便于数据读取
xlim([0, result.total_groups + 1]);  % 扩展X轴范围，避免数据点贴边

% 绘制各组测距误差曲线
subplot(2, 1, 2);
range_errors = [result.group_results.range_error];  % 提取所有组的测距误差
plot(1:result.total_groups, range_errors, 'ro-', ...
    'LineWidth', 1.2, 'MarkerSize', 6, 'Color', [0.8, 0.3, 0.3]);
title('各组测距误差', 'FontSize', 12);
xlabel('组号', 'FontSize', 10);
ylabel('测距误差(米)', 'FontSize', 10);
grid on; grid minor;
xlim([0, result.total_groups + 1]);


%% 7. 保存仿真结果
% 生成结果子文件夹名称
subfolder_name = sprintf('lisa_results_%s_%dbits', params.current_time, total_data_bits);
subfolder_path = fullfile(results_root, subfolder_name);

% 若子文件夹不存在则创建
if ~exist(subfolder_path, 'dir')
    mkdir(subfolder_path);
end

% 定义所有结果文件的统一前缀和路径
file_prefix = sprintf('lisa_simulation_%s_%dbits', params.current_time, total_data_bits);
mat_save_path = fullfile(subfolder_path, [file_prefix, '.mat']);  % 数据文件路径
fig_save_path = fullfile(subfolder_path, [file_prefix, '.fig']);  % 图像编辑文件路径
jpg_save_path = fullfile(subfolder_path, [file_prefix, '.jpg']);  % 图像浏览文件路径

% 保存MAT数据文件
try
    save(mat_save_path, 'save_data', '-v7.3');  % v7.3格式支持大容量数据
    fprintf('\nMAT文件保存成功！\n路径：%s\n', mat_save_path);
catch err
    warning('MAT文件保存失败：%s\n', err.message);
end

% 保存FIG图像文件
try
    savefig(fig_handle, fig_save_path);
    fprintf('FIG文件保存成功！\n路径：%s\n', fig_save_path);
catch err
    warning('FIG文件保存失败：%s\n', err.message);
end

% 保存JPG图像文件
try
    print(fig_handle, '-djpeg', '-r300', jpg_save_path);
    fprintf('JPG文件保存成功！\n路径：%s\n', jpg_save_path);
catch err
    warning('JPG文件保存失败：%s\n', err.message);
end

