% --------------------------
% 空闲数据序列生成函数
% 功能：生成指定长度的空闲数据序列（Capture/Idle Sequence）。
% 输入参数：
%   total_length_bit - 整数：所需的总长度（bit）。
% 输出参数：
%   idle_sequence_bit - 逻辑向量（logical）：MSB优先的空闲数据序列（行向量）。
% --------------------------

function idle_sequence_bit = generate_idle_sequence(total_length_bit)
    % 标准规定的 32 位伪随机序列 
    PRN_HEX = '352EF853';
    PRN_LEN = 32;

    % 1. 将 32 位 Hex 转换为 MSB 优先的 Logical 向量
    prn_base_sequence = hex2bit_MSB(PRN_HEX);
    
    if length(prn_base_sequence) ~= PRN_LEN
        error('GENERATE_IDLE_SEQUENCE:PRNLengthError', ...
              '基础 PRN 序列长度错误，应为 %d bit，实际为 %d bit。', PRN_LEN, length(prn_base_sequence));
    end

    % 2. 计算需要重复的次数
    num_repeats = ceil(total_length_bit / PRN_LEN);
    
    % 3. 重复基础序列
    repeated_sequence = repmat(prn_base_sequence, 1, num_repeats);
    
    % 4. 截取到所需的精确长度
    idle_sequence_bit = repeated_sequence(1:total_length_bit);
    
end

