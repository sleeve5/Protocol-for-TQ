function spdu_bits = build_SPDU(directives_cell)
% BUILD_SPDU 构建 Variable-Length SPDU (Type 1)
% 对应标准: CCSDS 211.0-B-6 Annex B
%
% 输入: directives_cell (包含多个 16-bit 指令的 cell 数组)
% 输出: logical 向量

    % SPDU Header (1 byte)
    % Format ID (1 bit): 0 (Variable Length)
    % Type ID (3 bits): 000 (Directives/Reports)
    % Length (4 bits): Data Field Octets
    
    num_octets = length(directives_cell) * 2; % 每个指令2字节
    if num_octets > 15
        error('SPDU 数据过长 (最大15字节)');
    end
    
    header = [0, 0, 0, 0, de2bi(num_octets, 4, 'left-msb')];
    
    data_field = [];
    for i = 1:length(directives_cell)
        data_field = [data_field, directives_cell{i}];
    end
    
    spdu_bits = logical([header, data_field]);
end