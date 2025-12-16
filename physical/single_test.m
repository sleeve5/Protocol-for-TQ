% 单组通信测试程序：LISA通信测距仿真
% 功能：生成64位数据，运行LISA通信测距仿真

clc;
clear all;
addpath(genpath('.\data'));
addpath(genpath('.\libs'));

%% 初始化参数
c = 3e8;                                % 光速
fs = 100e6;                             % 伪随机序列采样速率为100MHz
prn_length = 1024;                      % 伪码序列长度

prn_rate = 3.125e6;                     % 码速率为3.125MHz
data_rate = 195.3125e3;                 % 通信速率，暂不参与仿真流程
data_length = 64;                       % 每组数据的通信码长度
repeat_times = 2;                       % 传输2组相同数据
b = 0.1;                                % 伪码调制系数

remote_laser_freq = 281.95e12 + 10e6;   % 远端激光载频频率281.95THz + 10MHz
local_laser_freq = 281.95e12;           % 本地光载频频率281.95THz

L = repeat_times * prn_length * fs ...     
    / prn_rate;                         % 总采样点个数
prn_sample_mult = fs / prn_rate;        % 伪码每个码片的采样倍数
t = 0 : (L - 1);                        % 时间向量
dt = t / fs;                            % 产生长度为L,频率间隔为Fs的时间序列

params = struct();
params.fs = fs;
params.prn_rate = prn_rate;
params.prn_length = prn_length;
params.data_length = data_length;
params.repeat_times = repeat_times;


%% 生成伪码
load m1.mat
load m2.mat

sampled_prn1 = rectpulse(prn1, fs/prn_rate);
sampled_prn2 = rectpulse(prn2, fs/prn_rate);


%% 生成数据码
% 生成一个长度为data_length * data_groups的数据码
remote_data = randi([0, 1], 1, data_length);
local_data = zeros(1, data_length);


%% 采样并生成双极性复合码
% 将远端数据进行重采样
% 将64位的通信码进行16倍扩频（一个通信码对应16个伪码）再32位采样
sampled_remote_data = rectpulse(remote_data, (prn_length/data_length) * (fs/prn_rate));
sampled_local_data = rectpulse(local_data, (prn_length/data_length) * (fs/prn_rate));

% 生成复合码
composite_remote_data = double(mod(sampled_remote_data + sampled_prn1, 2));
composite_local_data = double(mod(sampled_local_data + sampled_prn2, 2));

% 复合码转换为双极性
composite_remote_data = (composite_remote_data - 0.5) *2;
composite_local_data = (composite_local_data - 0.5) *2;

% 将复合码重复data_nums次
composite_remote_data = repmat(composite_remote_data, 1, repeat_times);
composite_local_data = repmat(composite_local_data, 1, repeat_times);


%% 主载波调制
% 延迟
real_distance = randi(98300);
time_delay = real_distance / c;
delay = round(time_delay * fs);
total_length = prn_length * (fs / prn_rate) * repeat_times;

delayed_composite_remote_data = [composite_remote_data(total_length-delay+1 : total_length), ...
    composite_remote_data(1 : total_length-delay)];

% 将复合码以0.1的深度调制到载波
remote_signal = exp(1i*(2*pi*remote_laser_freq*dt + b*delayed_composite_remote_data));
local_signal = exp(1i*(2*pi*local_laser_freq*dt + b*composite_local_data));


%% 经过光电探测器
carrier_freq = remote_laser_freq - local_laser_freq;
signal_mix = PD(local_signal, remote_signal, params);


%% 经过PLL
[phase_error, dpll_output] = PLL(signal_mix, carrier_freq, params);


%% 经过DLL
% 调用DLL函数，获取远端/本地伪码的延迟索引
remote_delay_idx = DLL(sampled_prn1, phase_error, params);  % 远端伪码延迟
local_delay_idx = DLL(sampled_prn2, phase_error, params);   % 本地伪码延迟

% 计算校正后的延迟索引
corrected_delay_idx = remote_delay_idx - local_delay_idx;
if corrected_delay_idx < 0
    corrected_delay_idx = corrected_delay_idx + prn_length * prn_sample_mult;  % 加上伪码总采样数，避免负索引
end


%% 解码
decode_result = decode(phase_error, sampled_prn1, remote_data, corrected_delay_idx, params);


%% 结果分析
fprintf('误码率：%.4f %%\n', decode_result.ber);
fprintf('测距误差：%.2f 米\n', abs(decode_result.distance - real_distance));
