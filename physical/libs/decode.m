% --------------------------
% 数据解码专用函数
% 功能：输入DLL延迟结果，输出单组数据的解码结果及误码率
% 输入参数：
%   phase_error        - DPLL输出的相位误差信号
%   sampled_prn_remote - 远端采样后的伪码序列
%   remote_data        - 原始发送的单组远端数据
%   corrected_delay_idx- DLL输出的校正后延迟索引
%   params             - 伪码与数据参数结构体
%       .fs               - 采样率（默认100e6 Hz）
%       .prn_length       - 伪码序列长度（默认1024）
%       .prn_rate         - 伪码速率（默认3.125e6 Hz）
%       .data_length      - 单组数据的比特长度（默认64）
% 输出参数：
%   decode_result      - 解码结果结构体：
%       .received_data    - 单组解码后数据（长度=params.data_length）
%       .ber              - 误码率（百分比，基于单组数据对比）
%       .aligned_dat      - 延迟对齐后的相位误差数据（调试用）
%       .distance         - 基于DLL延迟计算的测距结果（米）
% --------------------------

function [decode_result] = decode(phase_error, sampled_prn_remote, remote_data, corrected_delay_idx, params)
    % 1. 参数初始化
    decode_result = struct();
    c = 3e8;  % 光速
    
    % 单组数据默认参数
    default_params.fs = 100e6;
    default_params.prn_length = 1024;
    default_params.prn_rate = 3.125e6;
    default_params.data_length = 64;  % 数据的比特长度

    % 补全未传入的参数
    if nargin < 5 || isempty(params)
        params = default_params;
    end

    % 提取核心参数
    fs = params.fs;
    prn_length = params.prn_length;
    prn_rate = params.prn_rate;
    data_length = params.data_length;
    prn_sample_mult = fs / prn_rate;        % 伪码每个码片的采样倍数
    total_dat_len = length(phase_error);    % 相位误差总长度

    % 2. 相位误差信号延迟对齐
    % 向前移动corrected_delay_idx个采样点，抵消传输延迟（确保数据对齐）
    decode_result.aligned_dat = [phase_error(corrected_delay_idx + 1 : total_dat_len), ...
                                 phase_error(1 : corrected_delay_idx)];

    % 3. 初始化解码数据
    decode_result.received_data = zeros(1, data_length);

    % 4. 逐比特解码
    % 单组数据的起始索引：从第1个采样点开始
    group_start_idx = 1;

    for bit_idx = 1 : data_length
        % 每个比特对应的采样点数量（伪码总采样数/单组比特数，与原逻辑一致）
        bit_sample_num = (prn_length * prn_sample_mult) / data_length;
        % 当前比特在对齐后数据中的起始索引
        bit_start_idx = group_start_idx + (bit_idx - 1) * bit_sample_num;

        % 相关运算（区分伪码0/1，累加相关性）
        corr_sum = 0;
        for sample_idx = 1 : bit_sample_num
            prn_sample_idx = (bit_idx - 1) * bit_sample_num + sample_idx;  % 伪码对应采样点
            if sampled_prn_remote(prn_sample_idx) == 0
                corr_sum = corr_sum + decode_result.aligned_dat(bit_start_idx + sample_idx - 1);
            else
                corr_sum = corr_sum - decode_result.aligned_dat(bit_start_idx + sample_idx - 1);
            end
        end

        % 数据判决：相关和>0判为0，否则判为1（与调制时的极性反转对应）
        if corr_sum > 0
            decode_result.received_data(bit_idx) = 0;
        else
            decode_result.received_data(bit_idx) = 1;
        end
    end

    % 5. 数据极性反转
    decode_result.received_data = double(~decode_result.received_data);

    % 6. 误码率计算
    if length(remote_data) ~= data_length
        warning('原始数据长度与单组解码数据长度不匹配（需均为%d位）', data_length);
        decode_result.ber = NaN;
    else
        error_bits = sum(abs(decode_result.received_data - remote_data));
        decode_result.ber = (error_bits / data_length) * 100;  % 仅用单组长度计算（无冗余）
    end

    % 7. 测距结果计算
    arrival_time = corrected_delay_idx / fs;
    decode_result.distance = c * arrival_time;
end

