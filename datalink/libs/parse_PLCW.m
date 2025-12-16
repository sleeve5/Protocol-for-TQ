function plcw_info = parse_PLCW(plcw_bits)
% PARSE_PLCW 解析 Proximity-1 PLCW 比特流
% 输入: 16 bits logical/double 向量
% 输出: 结构体

    % 确保输入格式
    bits = double(plcw_bits(:)');
    
    if length(bits) ~= 16
        warning('PLCW 长度错误，应为 16 bits');
        plcw_info = []; return;
    end
    
    % 解析字段 (对应 build_PLCW 的封装顺序)
    % [Format(1), Type(1), Retx(1), PCID(1), Res(1), Exp(3), Report(8)]
    
    plcw_info.FormatID = bits(1);
    plcw_info.TypeID = bits(2);
    plcw_info.RetransmitFlag = logical(bits(3));
    plcw_info.PCID = bits(4);
    % bits(5) is Reserved
    plcw_info.Exp_Counter = bi2de(bits(6:8), 'left-msb');
    plcw_info.Report_Value = bi2de(bits(9:16), 'left-msb');
end