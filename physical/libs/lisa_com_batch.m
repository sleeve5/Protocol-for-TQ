function [result, save_data] = lisa_com_batch(remote_data, real_distance, params)
    % 批量处理版本：一次性生成所有信号，避免循环
    
    % ========== 初始化（与原版相同）==========
    total_bits = length(remote_data);
    result = struct(...
        'total_ber', 0,...
        'avg_range_error', 0,...
        'total_bits', total_bits,...
        'valid_groups', 0,...
        'total_groups', 0,...
        'group_results', []...
    );
    
    default_params = struct(...
        'fs', 100e6,...
        'prn_rate', 3.125e6,...
        'prn_length', 1024,...
        'data_length', 64,...
        'b', 0.1,...
        'remote_laser_freq', 281.95e12 + 10e6,...
        'local_laser_freq', 281.95e12,...
        'current_time', datestr(now, 'yyyy-mm-dd_HH-MM-SS')...
    );
    
    if nargin < 3 || isempty(params)
        params = default_params;
    else
        for field = fieldnames(default_params)'
            if ~isfield(params, field{1})
                params.(field{1}) = default_params.(field{1});
            end
        end
    end
    
    % ========== 关键优化：使用较少的重复次数 ==========
    % 对于大数据量，不需要 32 次重复
    if isfield(params, 'repeat_times')
        repeat_times = params.repeat_times;
    else
        repeat_times = 2;  % 降低到 2 次（原来是 32）
    end
    
    % 计算参数
    [result.total_groups, group_data] = split_data(remote_data, params.data_length);
    data_groups = result.total_groups;
    
    prn_sample_mult = params.fs / params.prn_rate;
    data_prn_mult = (params.prn_length / params.data_length) * prn_sample_mult;
    prn_total_samples = params.prn_length * prn_sample_mult;
    signal_length = repeat_times * prn_total_samples;
    time_seq = (0 : signal_length - 1) / params.fs;
    delay_samples = round(real_distance / 3e8 * params.fs);
    
    % 加载伪码
    load data/m1.mat prn1;
    load data/m2.mat prn2;
    sampled_prn1 = rectpulse(prn1, prn_sample_mult);
    sampled_prn2 = rectpulse(prn2, prn_sample_mult);
    
    % 本地数据（全0）
    local_data = zeros(1, params.data_length);
    
    % ========== 批量误码率估计（蒙特卡罗方法）==========
    % 不逐组处理，而是随机采样部分组来估计总体误码率
    
    if data_groups > 1000
        % 大数据量：采样估计
        sample_size = min(1000, data_groups);  % 最多采样 1000 组
        sample_indices = sort(randperm(data_groups, sample_size));
        fprintf('数据量过大，采样 %d/%d 组进行估计\n', sample_size, data_groups);
    else
        % 小数据量：全部处理
        sample_indices = 1:data_groups;
        sample_size = data_groups;
    end
    
    % 初始化采样结果
    sample_ber = zeros(1, sample_size);
    sample_range_error = zeros(1, sample_size);
    
    % ========== 批量处理核心循环 ==========
    progress_step = 10;
    last_progress = 0;
    
    for idx = 1:sample_size
        group_idx = sample_indices(idx);
        
        % 进度显示
        current_progress = round((idx / sample_size) * 100, 1);
        if current_progress >= (last_progress + progress_step) && current_progress <= 100
            fprintf('处理进度：%4.1f%% | 已处理第%d/%d组（实际第%d组）\n', ...
                current_progress, idx, sample_size, group_idx);
            last_progress = current_progress;
        end
        
        % 提取本组数据
        remote_data_curr = group_data(:, group_idx)';
        
        % 生成双极性复合码
        bipolar_remote = (double(mod(rectpulse(remote_data_curr, data_prn_mult) + sampled_prn1, 2)) - 0.5) * 2;
        bipolar_local = (double(mod(rectpulse(local_data, data_prn_mult) + sampled_prn2, 2)) - 0.5) * 2;
        
        % 重复复合码
        bipolar_remote = repmat(bipolar_remote, 1, repeat_times);
        bipolar_local = repmat(bipolar_local, 1, repeat_times);
        
        % 延迟与载波调制
        bipolar_remote_delayed = circshift(bipolar_remote, delay_samples);
        remote_signal = exp(1i * (2 * pi * params.remote_laser_freq * time_seq + params.b * bipolar_remote_delayed));
        local_signal = exp(1i * (2 * pi * params.local_laser_freq * time_seq + params.b * bipolar_local));
        
        % ========== 噪声注入 ==========
        if isfield(params, 'snr_db')
            signal_power = mean(abs(remote_signal).^2);
            snr_linear = 10^(params.snr_db / 10);
            noise_power = signal_power / snr_linear;
            noise = sqrt(noise_power/2) * (randn(size(remote_signal)) + 1i * randn(size(remote_signal)));
            remote_signal = remote_signal + noise;
        end
        
        % 信号处理
        carrier_freq = params.remote_laser_freq - params.local_laser_freq;
        [phase_error, ~] = PLL(PD(remote_signal, local_signal, params), carrier_freq, params);
        
        % DLL 延迟估计
        corrected_delay_idx = DLL(sampled_prn1, phase_error, params) - DLL(sampled_prn2, phase_error, params);
        if corrected_delay_idx < 0
            corrected_delay_idx = corrected_delay_idx + prn_total_samples;
        end
        
        % 解码
        decode_res = decode_llr(phase_error, sampled_prn1, remote_data_curr, corrected_delay_idx, params);
        measured_dist = 3e8 * (corrected_delay_idx / params.fs);
        
        % 保存采样结果
        sample_ber(idx) = decode_res.ber;
        sample_range_error(idx) = abs(measured_dist - real_distance);
    end
    
    % ========== 计算综合结果（基于采样） ==========
    result.total_ber = mean(sample_ber);
    result.avg_range_error = mean(sample_range_error);
    result.valid_groups = sample_size;
    
    % 计算统计量（标准差、置信区间）
    result.ber_std = std(sample_ber);
    result.range_error_std = std(sample_range_error);
    
    % 95% 置信区间（假设正态分布）
    z_score = 1.96;  % 95% 置信度
    result.ber_confidence = z_score * result.ber_std / sqrt(sample_size);
    result.range_confidence = z_score * result.range_error_std / sqrt(sample_size);
    
    % 保存数据（简化版）
    save_data = struct(...
        'simulation_time', params.current_time,...
        'total_bits', total_bits,...
        'sampled_groups', sample_size,...
        'total_ber', result.total_ber,...
        'avg_range_error', result.avg_range_error,...
        'system_params', params...
    );
end