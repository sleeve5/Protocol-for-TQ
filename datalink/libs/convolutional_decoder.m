function decoded_bits = convolutional_decoder(rx_soft_bits)
% CONVOLUTIONAL_DECODER Viterbi 译码器 (无状态版)
% 输入: LLR (0->正, 1->负)
% 输出: 逻辑向量

    % 1. 定义 Trellis
    trellis = poly2trellis(7, [171 133]);
    
    % 2. 创建译码器
    % TracebackDepth: 35 (5*K)
    dec = comm.ViterbiDecoder(...
        'TrellisStructure', trellis, ...
        'InputFormat', 'Unquantized', ...
        'TracebackDepth', 35, ...
        'TerminationMethod', 'Truncated');
        
    % 3. 符号反转恢复 (G2 Invert Back)
    % LLR 域: 取反 = 符号翻转
    rx_proc = rx_soft_bits(:);
    rx_proc(2:2:end) = -rx_proc(2:2:end);
    
    % 4. 译码
    decoded = step(dec, rx_proc);
    decoded_bits = logical(decoded');
end