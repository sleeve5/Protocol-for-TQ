% --------------------------
% 数据解码专用函数v2
% 功能：输入DLL延迟结果，输出单组数据的解码结果及误码率，新增输出LDPC解码所需的llr
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
%       .soft_output_LLR  - 软信息输出（LLR近似值，与corr_sum成正比） <--- 新增
%       .aligned_dat      - 延迟对齐后的相位误差数据（调试用）
%       .distance         - 基于DLL延迟计算的测距结果（米）
% --------------------------

function [decode_result] = decode_llr(phase_error, sampled_prn_remote, remote_data, corrected_delay_idx, params)
    
    % 1. 参数初始化
    decode_result = struct();
    
    fs = params.fs;
    prn_length = params.prn_length;
    prn_rate = params.prn_rate;
    data_length = params.data_length;
    
    % 物理常量
    c = 3e8; % 光速

    % 计算伪码每个码片的采样倍数
    prn_sample_mult = fs / prn_rate;
    
    % 结果向量初始化
    decode_result.received_data = zeros(1, data_length);
    decode_result.soft_output_LLR = zeros(1, data_length); % <--- 初始化 LLR 向量
    decode_result.aligned_dat = zeros(1, length(phase_error)); % 仅用于对齐后的信号存储
    
    % 2. 延迟对齐与数据提取
    % 伪码总采样点数
    prn_total_sample_num = length(sampled_prn_remote); 
    
    % 根据DLL输出的校正延迟索引，对DPLL的输出相位误差进行循环移位对齐
    decode_result.aligned_dat = circshift(phase_error, [0, -corrected_delay_idx]);
    
    % 测距结果（基于延迟索引）
    time_delay = corrected_delay_idx / fs;
    decode_result.distance = time_delay * c; % 距离 (米)
    
    % 3. 比特解调与判决
    
    % 测距误差（用于单组数据的性能评估）
    real_distance = params.real_distance;
    decode_result.range_error = abs(decode_result.distance - real_distance);

    % 由于每组数据的长度固定，且与PRN码的长度相关，我们假设一个PRN周期传输data_length个比特
    group_start_idx = 1; % 从对齐后的数据流的第一个采样点开始解调

    for bit_idx = 1 : data_length
        % 每个比特对应的采样点数量（伪码总采样数/单组比特数）
        bit_sample_num = prn_total_sample_num / data_length;
        % 当前比特在对齐后数据中的起始索引
        bit_start_idx = group_start_idx + (bit_idx - 1) * bit_sample_num;

        % 相关运算（区分伪码0/1，累加相关性）
        corr_sum = 0;
        for sample_idx = 1 : bit_sample_num
            % 伪码对应采样点索引 (假设PRN是重复的)
            prn_sample_idx = mod((bit_idx - 1) * bit_sample_num + sample_idx - 1, prn_total_sample_num) + 1;
            
            % 混频后的信号与本地伪码的异相进行相关
            % 伪码=0时，相关和 = +aligned_dat (对应BPSK的0相位)
            % 伪码=1时，相关和 = -aligned_dat (对应BPSK的π相位)
            if sampled_prn_remote(prn_sample_idx) == 0
                corr_sum = corr_sum + decode_result.aligned_dat(bit_start_idx + sample_idx - 1);
            else
                corr_sum = corr_sum - decode_result.aligned_dat(bit_start_idx + sample_idx - 1);
            end
        end

        % 软信息输出 (LLR) <--- 新增
        % LDPC译码器使用此相关值作为软信息。LLR>0 倾向于 '0'，LLR<0 倾向于 '1'
        decode_result.soft_output_LLR(bit_idx) = corr_sum;

        % 数据判决（硬判决）：相关和>0判为0，否则判为1
        if corr_sum > 0
            decode_result.received_data(bit_idx) = 0;
        else
            decode_result.received_data(bit_idx) = 1;
        end
    end

    decode_result.received_data = double(~decode_result.received_data);
    
    % 4. 误码率（BER）计算 (基于硬判决结果)
    % 远端数据 remote_data 在传输前已编码（0/1），需转换为硬判决形式 (0/1)
    % 接收到的 received_data 也是硬判决 (0/1)
    
    % 确保 remote_data 是行向量
    if iscolumn(remote_data)
        remote_data = remote_data';
    end
    
    % 只比较与实际数据长度一致的部分
    compare_len = min(length(remote_data), data_length);
    bit_errors = sum(remote_data(1:compare_len) ~= decode_result.received_data(1:compare_len));
    decode_result.ber = bit_errors / compare_len;
    
end