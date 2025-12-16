% --------------------------
% 延迟锁相环（DLL）函数，参考了邵子豪的工作
% 功能：输入采样后伪码、DLL数据，输出校正后的伪码延迟索引
% 输入参数：
%   sampled_prn      - 采样后的伪码序列
%   dll_input_dat    - DLL输入数据
%   params           - 伪码与数据参数结构体（可选，默认值如下）
%       .fs               - 采样率（默认10e6）
%       .prn_length       - 伪码序列长度（默认1024）
%       .prn_rate         - 伪码速率（默认3.125e6）
%       .data_length      - 每组数据的比特长度（默认64）
%       .repeat_times     - 单组数据的重复次数（默认2）
% 输出参数：
%   corrected_delay  - 校正后的伪码延迟索引
% --------------------------

function corrected_delay = DLL(sampled_prn, phase_error, params)
    % 1. 初始化DLL内部参数

    % 伪码与数据参数默认值（若未传入params，使用默认配置）
    default_params.fs = 100e6;
    default_params.prn_length = 1024;
    default_params.prn_rate = 3.125e6;
    default_params.data_length = 64;
    default_params.repeat_times = 2;
    
    if nargin < 3 || isempty(params)
        params = default_params;
    end

    fs = params.fs;
    prn_rate = params.prn_rate;
    prn_length = params.prn_length;
    repeat_times = params.repeat_times;
    prn_sample_mult = fs / prn_rate;
    data_length = params.data_length;
    prn_total_samples = prn_length * (fs / prn_rate);  % 伪码总采样数
    pn_ad = sampled_prn;        % 采样后伪码

    % --------------------------
    % 2. DLL捕获阶段：粗定位伪码延迟
    % --------------------------
    % 2.1 初始化捕获相关值数组
    capture_corr_sq = zeros(1, prn_length);     % 捕获阶段平方相关值
    bit_corr_val = zeros(1, data_length);       % 每个比特的相关值
    
    dll_start_group = repeat_times - 1;         % DLL起始数据组
    
    % 提取DLL输入数据（从相位误差中取目标数据段）
    % 数据段范围：第dll_start_group组，长度=伪码长度×采样倍数
    dat_start_idx = dll_start_group * prn_length * prn_sample_mult + 1;
    dat_end_idx = dat_start_idx + prn_length * prn_sample_mult - 1;
    dll_input_dat = phase_error(dat_start_idx : dat_end_idx);
    
    % 2.2 逐码片移动伪码，计算平方相关值
    for capture_idx = 1 : prn_length
        % 伪码循环移位（模拟不同延迟）
        if capture_idx < prn_length
            % 移位：从末尾取capture_idx×码片采样数，拼接到开头
            shift_samples = capture_idx * (fs / prn_rate);
            shifted_prn = [pn_ad(prn_total_samples - shift_samples + 1 : prn_total_samples), ...
                           pn_ad(1 : prn_total_samples - shift_samples)];
        else
            shifted_prn = pn_ad;  % 最后一个位置：不移位
        end

        % 2.3 逐比特计算相关值并平方
        for bit_idx = 1 : data_length
            bit_corr = 0;
            bit_sample_num = prn_length * prn_sample_mult / data_length;  % 每个比特的采样数
            % 逐采样点计算相关（伪码与数据相乘累加）
            for sample_idx = 1 : bit_sample_num
                bit_sample_idx = (bit_idx - 1) * bit_sample_num + sample_idx;
                if shifted_prn(bit_sample_idx) == 1
                    bit_corr = bit_corr + dll_input_dat(bit_sample_idx);
                else
                    bit_corr = bit_corr - dll_input_dat(bit_sample_idx);
                end
            end
            bit_corr_val(bit_idx) = bit_corr ^ 2;  % 相关值平方（增强峰值）
        end
        capture_corr_sq(capture_idx) = sum(bit_corr_val);  % 累加所有比特的平方相关值
    end

    % 2.4 找到捕获阶段的最大相关峰，确定粗延迟
    [~, coarse_delay] = max(capture_corr_sq);  % 最大相关峰索引（原auto_index）
    % 处理边界：若最大索引为伪码长度，重置为0
    if coarse_delay == prn_length
        coarse_delay = 0;
    end
    coarse_delay = coarse_delay + 1;  % 索引偏移校正（与原代码逻辑一致）

    % % 2.5 绘制捕获阶段相关峰图
    % figure;
    % plot(1 : prn_length, capture_corr_sq, 'b-', 'LineWidth', 1);
    % hold on;
    % grid on;
    % title('DLL Capture: Squared Correlation Peak');
    % xlabel('PN Code Shift Index');
    % ylabel('Squared Correlation Value');
    % legend('Correlation Curve');
    % hold off;

    % --------------------------
    % 3. DLL跟踪阶段：精定位伪码延迟
    % --------------------------
    % 3.1 生成超前/滞后支路数据（偏移1/2码片）
    half_chip_samples = (fs / prn_rate) / 2;  % 1/2码片对应的采样数
    % 滞后支路：数据向后移1/2码片
    lag_branch_dat = [dll_input_dat(prn_total_samples - half_chip_samples + 1 : prn_total_samples), ...
                      dll_input_dat(1 : prn_total_samples - half_chip_samples)];
    % 超前支路：数据向前移1/2码片
    lead_branch_dat = [dll_input_dat(half_chip_samples + 1 : prn_total_samples), ...
                       dll_input_dat(1 : half_chip_samples)];

    % 3.2 初始化跟踪阶段相关值数组
    lag_corr_sq = zeros(1, prn_sample_mult + 1);  % 滞后支路平方相关值（原square_aft）
    lead_corr_sq = zeros(1, prn_sample_mult + 1); % 超前支路平方相关值（原square_pre）

    % 3.3 逐采样点移动伪码，计算超前/滞后支路相关值
    for track_idx = 1 : prn_sample_mult + 1
        % 计算伪码移位采样数（精调移位）
        shift_offset = track_idx + (coarse_delay - 0.5) * prn_sample_mult - 1;
        % 伪码循环移位（处理边界情况）
        if shift_offset >= 1
            shift_samples = shift_offset * (fs / prn_rate) / prn_sample_mult;
            shifted_prn = [pn_ad(prn_total_samples - shift_samples + 1 : prn_total_samples), ...
                           pn_ad(1 : prn_total_samples - shift_samples)];
        else
            shift_samples = shift_offset * (fs / prn_rate) / prn_sample_mult;
            shifted_prn = [pn_ad(prn_total_samples - shift_samples + 1 - prn_total_samples : prn_total_samples), ...
                           pn_ad(1 : prn_total_samples - shift_samples - prn_total_samples)];
        end

        % 3.4 逐比特计算超前/滞后支路相关值并平方
        lag_bit_corr = zeros(1, data_length);  % 滞后支路比特相关值
        lead_bit_corr = zeros(1, data_length); % 超前支路比特相关值
        for bit_idx = 1 : data_length
            bit_sample_num = prn_length * prn_sample_mult / data_length;
            for sample_idx = 1 : bit_sample_num
                bit_sample_idx = (bit_idx - 1) * bit_sample_num + sample_idx;
                if shifted_prn(bit_sample_idx) == 1
                    lag_bit_corr(bit_idx) = lag_bit_corr(bit_idx) + lag_branch_dat(bit_sample_idx);
                    lead_bit_corr(bit_idx) = lead_bit_corr(bit_idx) + lead_branch_dat(bit_sample_idx);
                else
                    lag_bit_corr(bit_idx) = lag_bit_corr(bit_idx) - lag_branch_dat(bit_sample_idx);
                    lead_bit_corr(bit_idx) = lead_bit_corr(bit_idx) - lead_branch_dat(bit_sample_idx);
                end
            end
            lag_bit_corr(bit_idx) = lag_bit_corr(bit_idx) ^ 2;
            lead_bit_corr(bit_idx) = lead_bit_corr(bit_idx) ^ 2;
        end

        % 3.5 累加比特相关值，得到支路总相关值
        lag_corr_sq(track_idx) = sum(lag_bit_corr);
        lead_corr_sq(track_idx) = sum(lead_bit_corr);
    end

    % --------------------------
    % 4. 计算校正后的延迟索引（精调）
    % --------------------------
    corr_diff = lag_corr_sq - lead_corr_sq;  % 相关差值（滞后-超前）
    abs_corr_diff = abs(corr_diff);          % 相关差值取绝对值（找零点）
    [~, fine_delay] = min(abs_corr_diff);    % 找到最接近零点的索引（精调延迟）
    % 计算最终校正延迟（结合粗调+精调）
    corrected_delay = fine_delay + (coarse_delay - 0.5) * prn_sample_mult - 1;
end
