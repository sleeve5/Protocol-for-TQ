% --------------------------
% 锁相环(PLL)函数，参考了邵子豪的工作
% 功能：对输入参考信号进行相位跟踪，输出相位误差和锁相后的信号
% 输入参数：
%   ref_signal    - 输入参考信号（待锁相的信号）
%   carrier_freq  - 参考信号的载波频率 (Hz)
%   params        - 结构体参数（可选），包含：
%       .fs           - 采样率 (Hz)，默认100e6
%       .prn_length   - 伪码长度，默认1024
%       .prn_rate     - 伪码速率 (Hz)，默认3.125e6
%       .data_length  - 每组数据比特数，默认64
%       .data_groups  - 数据总组数，默认32
% 输出参数：
%   phase_error   - 经过低通滤波后的相位误差
%   pll_output    - 锁相环输出信号（与输入信号相位同步的正弦信号）
% --------------------------

function [phase_error, dpll_output] = PLL(ref_signal, carrier_freq, params)
    
    % 1. 参数初始化与校验
    % 设置默认参数
    default_params.fs = 100e6;          % 系统采样率，默认100MHz
    default_params.prn_length = 1024;   % 伪码序列长度
    default_params.prn_rate = 3.125e6;  % 伪码速率，默认3.125MHz
    default_params.data_length = 64;    % 每组数据比特数
    default_params.data_groups = 32;    % 数据总组数

    % 若未传入参数或参数为空，使用默认值
    if nargin < 3 || isempty(params)
        params = default_params;
    end
       
    % 提取核心参数
    num_samples = length(ref_signal);  % 信号采样点数
    fs = params.fs;                    % 采样率
    Ts = 1 / fs;                       % 采样周期 (s)
    carrier_freq_ref = carrier_freq;   % 参考载波频率

    % 2. 初始化PLL内部变量
    % NCO（数控振荡器）参数
    nco_gain = 1/4096;                 % NCO增益常数
    
    % 环路滤波器参数
    loop_int_gain = 0.0032;            % 积分器增益
    loop_prop_gain = 3.1;              % 比例项增益
    
    % 状态变量预分配（提升运行效率）
    nco_phase = zeros(1, num_samples); % NCO相位（周期归一化，范围[0,1)）
    loop_int = zeros(1, num_samples);  % 环路滤波器积分输出
    phase_error_raw = zeros(1, num_samples); % 原始相位误差
    loop_tune = zeros(1, num_samples); % 环路滤波器总输出
    nco_output = zeros(1, num_samples);% NCO输出信号

    % 3. PLL核心环路
    for n = 2 : num_samples
        % 3.1 NCO相位计算（基于前一时刻状态和环路调谐值）
        % 相位增量 = 载波频率×采样周期 + 前一时刻相位 + 调谐值×NCO增益
        phase_increment = carrier_freq_ref * Ts + nco_phase(n-1) + loop_tune(n-1) * nco_gain;
        nco_phase(n) = mod(phase_increment, 1);  % 相位归一化（取小数部分）

        % 3.2 NCO输出信号（正弦波，基于当前相位）
        nco_output(n) = sin(2 * pi * nco_phase(n-1));  % 用前一时刻相位避免超前

        % 3.3 鉴相器（计算输入信号与NCO输出的相位误差）
        % 采用乘法型鉴相：误差 = 参考信号 × NCO输出（适用于BPSK等调制）
        phase_error_raw(n) = ref_signal(n-1) * nco_output(n);

        % 3.4 环路滤波器（PI控制器：积分项 + 比例项）
        loop_int(n) = loop_int_gain * phase_error_raw(n) + loop_int(n-1);  % 积分部分
        loop_tune(n) = loop_int(n) + loop_prop_gain * phase_error_raw(n);   % 总输出（调谐NCO）
    end

    % 4. 相位误差低通滤波（平滑噪声）
    filter_order = 10;                 % Butterworth滤波器阶数
    cutoff_freq = 1.5e6;               % 截止频率1.5MHz（滤除高频噪声）
    % 设计归一化低通滤波器（双线性变换）
    [b, a] = butter(filter_order, 2 * cutoff_freq / fs, 'low');
    phase_error = filtfilt(b, a, phase_error_raw);  % 零相位滤波（无相位失真）

    % % 5. 绘制功率谱密度对比图
    % figure;
    % % 计算NCO输出信号的功率谱（截取稳定段，跳过前10000点过渡过程）
    % [pspectrum_nco, freq_nco] = pwelch(nco_output(10000:end), 2048, 512, 2048, fs);
    % % 计算参考信号的功率谱
    % [pspectrum_ref, freq_ref] = pwelch(ref_signal, 2048, 512, 2048, fs);
    % % 计算相位误差的功率谱
    % [pspectrum_err, freq_err] = pwelch(phase_error, 2048, 512, 2048, fs);
    % 
    % % 归一化功率谱（以最大峰值为基准，便于对比）
    % peak_power = max(pspectrum_nco);  % 以NCO输出峰值为参考
    % plot(freq_nco, 10*log10(pspectrum_nco / peak_power), 'b', 'LineWidth', 1.2);
    % hold on;
    % plot(freq_ref, 10*log10(pspectrum_ref / peak_power), 'r', 'LineWidth', 1.2);
    % plot(freq_err, 10*log10(pspectrum_err / peak_power), 'k', 'LineWidth', 1.2);
    % hold off;
    % 
    % % 图形标注
    % xlabel('频率 (Hz)', 'FontSize', 10);
    % ylabel('归一化功率谱 (dB)', 'FontSize', 10);
    % legend('锁相输出功率谱', '锁相输入功率谱', '相位误差功率谱', 'FontSize', 9);
    % grid on;
    % title('PLL信号功率谱对比', 'FontSize', 11);

    % 6. 输出结果赋值
    dpll_output = sin(2 * pi * nco_phase);  % 最终锁相输出信号

end
    
