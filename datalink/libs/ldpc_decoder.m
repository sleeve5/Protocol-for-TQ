% --------------------------
% LDPC 解码函数
% 功能：执行接收端LDPC处理全流程（剥离CSM -> 去随机化 -> 逆打孔 -> LDPC译码）。
% 输入参数：
%   rx_blocks   - 向量（double）：接收到的已同步比特流，总长度必须是块长（2048或2112）的整数倍。
% 输出参数：
%   decoded_stream - 逻辑向量（logical）：译码后的原始信息比特流（行向量），每块1024 bits。
% --------------------------

function decoded_stream = ldpc_decoder(rx_blocks)
    
    % 1. 缓存变量
    % 缓存解码器对象、打孔模式和伪随机序列，避免重复计算
    persistent dec_obj punct_pat pn_seq;
    
    % 2. 初始化
    if isempty(dec_obj)
        % 定位配置文件路径
        lib_path = fileparts(mfilename('fullpath'));
        config_file = fullfile(lib_path, '..', 'data', 'CCSDS_C2_matrix.mat');
        
        if exist(config_file, 'file') ~= 2
            error('LDPC_DECODER: 配置文件缺失 (%s)。请先运行 utils/generate_LDPC_matrix.m', config_file);
        end
        
        % 加载 H 矩阵和打孔模式
        data = load(config_file);
        punct_pat = data.puncture_pattern;
        
        % --- 关键修正: 强制转换为逻辑稀疏矩阵 ---
        H_logical = logical(data.H);
        
        % 初始化新版 LDPC 译码器配置对象
        dec_obj = ldpcDecoderConfig(H_logical);
        
        % 预计算伪随机序列 (长度为传输码字长度: 2048)
        % 发送端先打孔再随机化，所以接收端先去随机化再逆打孔
        len_coded = sum(punct_pat); 
        pn_seq = generate_pn_sequence_rx(len_coded);
    end

    % 3. 参数定义
    K_INFO = 1024;          % 信息位长度
    N_CODED = 2048;         % 传输码字长度 (打孔后)
    BLOCK_WITH_CSM = 2112;  % 含CSM的块长 (64 + 2048)
    
    % 4. 块结构分析
    total_len = length(rx_blocks);
    
    % 自动检测输入是否包含 CSM
    if mod(total_len, BLOCK_WITH_CSM) == 0
        has_csm = true;
        block_step = BLOCK_WITH_CSM;
    elseif mod(total_len, N_CODED) == 0
        has_csm = false;
        block_step = N_CODED;
    else
        error('LDPC_DECODER: 输入长度(%d)不符合对齐要求，必须是 %d 或 %d 的倍数', ...
              total_len, N_CODED, BLOCK_WITH_CSM);
    end
    
    num_blocks = total_len / block_step;
    decoded_stream = false(1, num_blocks * K_INFO); % 预分配输出
    
    % 准备逆打孔容器 (LLR=0 表示 Erasure/不确定)
    % 长度为完整码字长度 2560
    full_len = length(punct_pat);
    depunctured_llr = zeros(full_len, 1);
    
    % 5. 批量处理循环
    idx_in = 1;
    idx_out = 1;
    
    for i = 1:num_blocks
        % A. 提取当前块
        curr_chunk = rx_blocks(idx_in : idx_in + block_step - 1);
        
        % B. 剥离 CSM (如果存在)
        if has_csm
            % 丢弃前64位，保留后2048位数据
            codeword_part = curr_chunk(65:end);
        else
            codeword_part = curr_chunk;
        end
        
        % 确保列向量 (以便后续计算)
        if size(codeword_part, 1) == 1, codeword_part = codeword_part'; end
        
        % C. 去随机化 (De-randomization)
        % 必须在译码前进行。
        % 如果输入是 LLR: 
        %   PN=0 (不做改变) -> LLR不变
        %   PN=1 (翻转)     -> LLR符号取反
        % 公式: LLR_new = LLR_old * (1 - 2*PN)
        
        % 构造符号翻转掩码 (0->1, 1->-1)
        pn_sign = 1 - 2 * double(pn_seq(:)); 
        
        % 执行解扰
        derand_llr = codeword_part .* pn_sign;
        
        % D. 逆打孔 (De-puncturing)
        % 将接收到的2048位填入保留位置，被打孔的512位填0
        depunctured_llr(:) = 0; % 重置擦除位
        depunctured_llr(punct_pat) = derand_llr;
        
        % E. LDPC 译码
        % 使用新版 ldpcDecode 函数 (输入列向量 LLR)
        % 最大迭代次数设为 50
        decoded_bits_dbl = ldpcDecode(depunctured_llr, dec_obj, 50);
        
        % F. 存入输出流 (转为逻辑行向量)
        decoded_stream(idx_out : idx_out + K_INFO - 1) = logical(decoded_bits_dbl');
        
        % 更新索引
        idx_in = idx_in + block_step;
        idx_out = idx_out + K_INFO;
    end
end

% ---------------------------------------------------------
% 内部辅助函数：伪随机序列生成器 (Rx专用)
% ---------------------------------------------------------
function seq = generate_pn_sequence_rx(len)
    % 标准多项式: h(x) = x^8 + x^6 + x^4 + x^3 + x^2 + x + 1
    % 初始状态: 全1
    registers = true(1, 8); 
    seq = false(1, len);
    
    for k = 1:len
        out_bit = registers(8);
        seq(k) = out_bit;
        
        feedback = xor(registers(8), registers(6));
        feedback = xor(feedback, registers(4));
        feedback = xor(feedback, registers(3));
        feedback = xor(feedback, registers(2));
        feedback = xor(feedback, registers(1));
        
        registers = [feedback, registers(1:7)];
    end
end
