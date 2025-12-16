% --------------------------
% 接收端 CRC 校验函数
% 功能：校验输入片段是否包含合法的 CRC-32
% 输入:
%   rx_segment: logical 或 double 向量，包含 [Payload, CRC(32bits)]
% 输出:
%   isValid:   true 表示校验通过
%   cleanData: 去除 CRC 后的纯数据 (logical 行向量，如果校验失败则返回空)
% --------------------------

function [isValid, cleanData] = CRC32_check(rx_segment)
    % 1. 基本长度检查 (CRC 本身 32 bit)
    if length(rx_segment) <= 32
        isValid = false;
        cleanData = [];
        return;
    end

    % 2. 准备 CRC 检测器 (持久化)
    persistent crcDet;
    if isempty(crcDet)
        % Proximity-1 标准多项式: 00A00805
        poly = '00A00805'; 
        poly_vec = hex2bit_MSB(poly); 
        poly_vec = logical([true, poly_vec]); 
        
        crcDet = comm.CRCDetector(...
            'Polynomial', poly_vec, ...
            'InitialConditions', 0, ...
            'DirectMethod', true);
    end
    
    % 3. 执行检测
    % [关键修正] 强制转换为 double 列向量
    % 这保证了无论调用者传入 logical 还是 double，step 函数看到的永远是 double
    in_col = double(rx_segment(:));
    
    % step 输出: [数据部分(去掉了CRC), 错误标志]
    [data_out, err_flag] = step(crcDet, in_col);
    
    isValid = ~err_flag; % err_flag=0 表示无误
    
    if isValid
        % 输出转回 logical 行向量，保持数据类型统一
        cleanData = logical(data_out'); 
    else
        cleanData = [];
    end
end