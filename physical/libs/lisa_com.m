% --------------------------
% LISA通信测距一体化仿真函数
% 功能：实现LISA通信测距一体化，输出仿真结果及待保存数据
% 输入参数:
%   remote_data     - 待传输通信码序列（二进制0/1）
%   real_distance   - 真实距离(m)
%   params          - 系统参数结构体（可选）
% 输出参数:
%   result          - 包含测距和误码率结果的结构体
%   save_data       - 用于保存到文件的完整数据结构体
% --------------------------

function [result, save_data] = lisa_com(remote_data, real_distance, params)
    % 初始化结果结构体
    % 包含误码率、测距误差、数据总量等全局统计信息
    total_bits = length(remote_data);
    result = struct(...
        'total_ber', 0,...                  % 总误码率
        'avg_range_error', 0,...            % 平均测距误差
        'total_bits', total_bits,...        % 总数据比特数
        'valid_groups', 0,...               % 有效数据组数
        'total_groups', 0,...               % 总数据组数
        'group_results', []...              % 各组详细结果
    );

    % 定义系统默认参数
    % 当输入参数params为空时使用，或补充params中缺失的字段
    default_params = struct(...
        'fs', 100e6,...                     % 采样率(Hz)
        'prn_rate', 3.125e6,...             % 伪码速率(Hz)
        'prn_length', 1024,...              % 伪码长度
        'data_length', 64,...               % 每组数据长度(bit)
        'b', 0.1,...                        % 伪码调制系数
        'remote_laser_freq', 281.95e12 + 10e6,...  % 远端激光频率(Hz)
        'local_laser_freq', 281.95e12,...           % 本地激光频率(Hz)
        'current_time', datestr(now, 'yyyy-mm-dd_HH-MM-SS')...  % 仿真时间戳
    );
    
    % 参数补全
    % 若输入params为空，则使用默认参数；否则补充缺失字段
    if nargin < 3 || isempty(params)
        params = default_params;
    else
        for field = fieldnames(default_params)'
            if ~isfield(params, field{1})
                params.(field{1}) = default_params.(field{1});
            end
        end
    end

    % 预计算常量参数
    % 存储循环中保持不变的计算结果，减少重复运算
    repeat_times = params.repeat_times;  % 复合码重复传输次数
    [result.total_groups, group_data] = split_data(remote_data, params.data_length);
    data_groups = result.total_groups;  % 总数据组数
    
    % 伪码相关参数计算
    prn_sample_mult = params.fs / params.prn_rate;  % 伪码采样倍数
    data_prn_mult = (params.prn_length / params.data_length) * prn_sample_mult;  % 数据采样倍数
    prn_total_samples = params.prn_length * prn_sample_mult;  % 伪码总采样数
    
    % 信号时间序列参数
    signal_length = repeat_times * prn_total_samples;  % 信号总长度
    time_seq = (0 : signal_length - 1) / params.fs;  % 时间序列
    delay_samples = round(real_distance / 3e8 * params.fs);  % 距离对应的延迟采样数

    % 加载伪码并采样
    % 从文件加载伪码序列，并根据采样倍数进行采样处理
    load data/m1.mat prn1;
    load data/m2.mat prn2;
    sampled_prn1 = rectpulse(prn1, prn_sample_mult);  % 伪码1采样
    sampled_prn2 = rectpulse(prn2, prn_sample_mult);  % 伪码2采样

    % 初始化组结果结构体数组
    % 预定义每组数据的结果格式，并扩展为指定长度的数组
    group_template = struct(...
        'group_idx', 0,...                  % 组索引
        'ber', NaN,...                      % 本组误码率
        'range_error', NaN,...              % 本组测距误差
        'measured_distance', NaN,...        % 本组测量距离
        'corrected_delay', NaN,...          % 校正后的延迟索引
        'original_group_data', [],...       % 本组原始数据
        'decoded_group_data', []...         % 本组解码数据
    );
    result.group_results = repmat(group_template, data_groups, 1);  % 生成指定长度的结果数组

    % 主循环：逐组处理数据
    % 对每组数据执行通信传输与测距仿真
    progress_step = 10;  % 进度显示步长(%)
    last_progress = 0;   % 上一次显示的进度
    local_data = zeros(1, params.data_length);  % 本地数据（全0）

    for group_idx = 1:data_groups
        % 显示仿真进度
        % 每完成指定比例的分组，输出一次进度信息
        current_progress = round((group_idx / data_groups) * 100, 1);
        if current_progress >= (last_progress + progress_step) && current_progress <= 100
            fprintf('仿真进度：%4.1f%% | 已处理第%d/%d组\n', ...
                current_progress, group_idx, data_groups);
            last_progress = current_progress;
        end

        % 数据准备与复合码生成
        % 提取本组数据，进行采样并生成双极性复合码
        result.group_results(group_idx).original_group_data = group_data(:, group_idx)';
        remote_data_curr = result.group_results(group_idx).original_group_data;  % 本组原始数据
        
        % 生成远端与本地的双极性复合码
        % 数据采样→与伪码叠加→转换为双极性码
        bipolar_remote = (double(mod(rectpulse(remote_data_curr, data_prn_mult) + sampled_prn1, 2)) - 0.5) * 2;
        bipolar_local = (double(mod(rectpulse(local_data, data_prn_mult) + sampled_prn2, 2)) - 0.5) * 2;
        
        % 重复复合码以提高可靠性
        bipolar_remote = repmat(bipolar_remote, 1, repeat_times);
        bipolar_local = repmat(bipolar_local, 1, repeat_times);
        
        % 信号延迟与载波调制
        % 对远端信号施加距离延迟，并进行载波调制
        bipolar_remote_delayed = circshift(bipolar_remote, delay_samples);  % 延迟处理
        
        % 载波调制（将复合码调制到激光载波上）
        remote_signal = exp(1i * (2 * pi * params.remote_laser_freq * time_seq + params.b * bipolar_remote_delayed));
        local_signal = exp(1i * (2 * pi * params.local_laser_freq * time_seq + params.b * bipolar_local));

        % 信号处理与结果计算
        % 执行光电探测、锁相环、解码等操作，计算测距结果
        carrier_freq = params.remote_laser_freq - params.local_laser_freq;  % 载波频率差
        [phase_error, ~] = PLL(PD(remote_signal, local_signal, params), carrier_freq, params);  % 相位提取
        
        % 计算校正后的延迟索引
        corrected_delay_idx = DLL(sampled_prn1, phase_error, params) - DLL(sampled_prn2, phase_error, params);
        if corrected_delay_idx < 0
            corrected_delay_idx = corrected_delay_idx + prn_total_samples;
        end
        
        % 解码与测距计算
        decode_res = decode_llr(phase_error, sampled_prn1, remote_data_curr, corrected_delay_idx, params);  % 解码数据
        measured_dist = 3e8 * (corrected_delay_idx / params.fs);  % 计算测量距离

        % 保存本组结果并累积统计量
        grp_res = result.group_results(group_idx);  % 临时引用本组结果
        grp_res.group_idx = group_idx;
        grp_res.ber = decode_res.ber;
        grp_res.range_error = abs(measured_dist - real_distance);
        grp_res.measured_distance = measured_dist;
        grp_res.corrected_delay = corrected_delay_idx;
        grp_res.decoded_group_data = decode_res.received_data;
        result.group_results(group_idx) = grp_res;  % 更新本组结果
        
        % 累积总误码率与有效组数
        if ~isnan(decode_res.ber)
            result.total_ber = result.total_ber + decode_res.ber * length(remote_data_curr);
            result.valid_groups = result.valid_groups + 1;
        end
        result.avg_range_error = result.avg_range_error + grp_res.range_error;  % 累积测距误差
    end

    % 计算综合结果
    % 基于各组累积的统计量，计算总误码率和平均测距误差
    if result.valid_groups > 0
        result.total_ber = result.total_ber / result.total_bits;  % 总误码率
    else
        result.total_ber = NaN;
    end
    
    if data_groups > 0
        result.avg_range_error = result.avg_range_error / data_groups;  % 平均测距误差
    else
        result.avg_range_error = NaN;
    end

    % 整理待保存数据
    % 汇总仿真时间、原始数据、解码结果、系统参数等信息
    save_data = struct(...
        'simulation_time', params.current_time,...      % 仿真时间戳
        'total_original_data', remote_data,...          % 完整原始数据
        'total_decoded_data', [result.group_results.decoded_group_data],...  % 完整解码数据
        'group_details', result.group_results,...       % 各组详细结果
        'comprehensive_results', struct(...             % 综合统计结果
            'total_bits', result.total_bits,...
            'total_groups', data_groups,...
            'total_ber', result.total_ber,...
            'avg_range_error', result.avg_range_error,...
            'real_distance', real_distance...
        ),...
        'system_params', params...                      % 系统参数
    );
end

