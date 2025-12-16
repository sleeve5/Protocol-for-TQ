% --------------------------
% 十六进制字符串转MSB优先二进制向量函数
% 功能：将十六进制字符串转换为符合邻近-1协议标准位序约定的二进制逻辑向量（第一个传送bit为b₀，即MSB优先）
% 输入参数：
%   hex_str   - 字符向量/字符串（char/string）：待转换的十六进制字符串。示例：'FAF320'
% 输出参数：
%   bit_vec   - 逻辑向量（logical）：MSB优先的二进制序列（行向量）
% --------------------------

function bit_vec = hex2bit_MSB(hex_str)
    % 统一将输入字符串转为大写，避免大小写混合导致的转换错误
    hex_str = upper(hex_str);
    
    % 计算十六进制字符串长度，确定输出二进制向量的总长度（1个十六进制字符→4bit）
    hex_len = length(hex_str);
    bit_vec = false(1, hex_len * 4);  % 初始化输出向量为逻辑型（节省内存，适配后续bit流处理）
    
    % 遍历每个十六进制字符，逐字符转换为4bit MSB优先二进制
    for i = 1:hex_len
        % 提取当前遍历的十六进制字符
        c = hex_str(i);
        
        % 将单个十六进制字符转换为十进制值
        if c >= '0' && c <= '9'
            % 数字字符（0-9）：直接转为对应的十进制值
            val = str2double(c);
        elseif c >= 'A' && c <= 'F'
            % 字母字符（A-F）：A对应10、B对应11...F对应15
            val = 10 + strfind('ABCDEF', c) - 1;
        else
            % 非法字符：抛出错误，提示具体非法字符
            error('十六进制字符串包含非法字符：%c，仅支持0-9、A-F（不区分大小写）', c);
        end
        
        % 将十进制值转换为4bit MSB优先的逻辑向量，写入输出向量对应位置
        % 'left-msb' 确保最高有效位（MSB）在前，符合标准5.1节位序约定
        bit_vec((i-1)*4 + 1 : i*4) = de2bi(val, 4, 'left-msb');
    end
end

