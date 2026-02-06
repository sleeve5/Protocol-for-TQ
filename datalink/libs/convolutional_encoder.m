function coded_bits = convolutional_encoder(input_bits)
% CONVOLUTIONAL_ENCODER Proximity-1 卷积编码器 (无状态版)
% 规范: Rate 1/2, K=7, G1=171(oct), G2=133(oct), G2 Inverted
% 输入: 逻辑向量
% 输出: 逻辑向量 (长度 * 2)

    % 1. 定义 Trellis (注意: 使用十进制数表示八进制)
    % 171 oct = 121 dec
    % 133 oct = 91 dec
    trellis = poly2trellis(7, [171 133]);
    
    % 2. 创建编码器 (每次新建，确保无状态残留)
    % 使用 Truncated 模式，适合包/帧处理
    enc = comm.ConvolutionalEncoder(...
        'TrellisStructure', trellis, ...
        'TerminationMethod', 'Truncated');
        
    % 3. 编码
    in_col = double(input_bits(:));
    encoded = step(enc, in_col);
    
    % 4. 符号反转 (G2 Inversion)
    % G2 在偶数位置 (2, 4, 6...)
    % 0->1, 1->0
    encoded(2:2:end) = 1 - encoded(2:2:end);
    
    % 5. 输出
    coded_bits = logical(encoded');
end