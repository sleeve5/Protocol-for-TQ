function tx_stream = ldpc_encoder(input_bits)
% LDPC_ENCODER Proximity-1 发送端 LDPC 编码 (新版 API)
%
% 修正: 使用 ldpcEncoderConfig 和 ldpcEncode 替代过时的 comm.LDPCEncoder
%
% 输入: input_bits (逻辑向量, 1024的倍数)
% 输出: tx_stream (含 CSM, 随机化, 打孔)

    % --- 1. 持久化变量 ---
    % cfg_obj 替代原来的 enc_obj
    persistent cfg_obj punct_pat pn_seq csm_bits;

    % --- 2. 初始化 ---
    if isempty(cfg_obj)
        % 定位文件
        lib_path = fileparts(mfilename('fullpath'));
        config_file = fullfile(lib_path, '..', 'data', 'CCSDS_C2_matrix.mat');
        
        if exist(config_file, 'file') ~= 2
            error('LDPC配置缺失，请先运行 utils/generate_LDPC_matrix.m');
        end
        
        data = load(config_file);
        punct_pat = data.puncture_pattern;
        
        % [API 升级] 使用 ldpcEncoderConfig
        % 输入必须是 sparse logical
        H = logical(data.H); 
        cfg_obj = ldpcEncoderConfig(H);
        
        % 预计算
        len_coded = sum(punct_pat); 
        pn_seq = generate_pn_sequence(len_coded);
        csm_bits = hex2bit_MSB('034776C7272895B0');
    end

    % --- 3. 运行时常量 ---
    K_INFO = 1024;
    
    % --- 4. 输入处理 ---
    if iscolumn(input_bits), input_bits = input_bits'; end
    
    total_len = length(input_bits);
    num_blocks = total_len / K_INFO;
    
    % 输出长度: (64 CSM + 2048 Data)
    block_out_len = 64 + length(pn_seq);
    tx_stream = false(1, num_blocks * block_out_len);
    
    idx_in = 1;
    idx_out = 1;
    
    % --- 5. 编码循环 ---
    for i = 1:num_blocks
        chunk = input_bits(idx_in : idx_in + K_INFO - 1)';
        
        % [API 升级] 使用 ldpcEncode
        % 输出为 double 0/1, 需转 logical
        full_codeword_dbl = ldpcEncode(chunk, cfg_obj);
        full_codeword = logical(full_codeword_dbl);
        
        % 转置为行向量
        if iscolumn(full_codeword), full_codeword = full_codeword'; end
        
        % 打孔
        codeword = full_codeword(punct_pat);
        
        % 随机化
        rand_cw = xor(codeword, pn_seq);
        
        % 拼接
        tx_stream(idx_out : idx_out + block_out_len - 1) = [csm_bits, rand_cw];
        
        idx_in = idx_in + K_INFO;
        idx_out = idx_out + block_out_len;
    end
end

% 内部辅助: PN生成 (不变)
function seq = generate_pn_sequence(len)
    registers = true(1, 8); 
    seq = false(1, len);
    for k = 1:len
        seq(k) = registers(8);
        feedback = xor(registers(8), registers(6));
        feedback = xor(feedback, registers(4));
        feedback = xor(feedback, registers(3));
        feedback = xor(feedback, registers(2));
        feedback = xor(feedback, registers(1));
        registers = [feedback, registers(1:7)];
    end
end