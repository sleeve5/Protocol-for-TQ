% --------------------------
% LDPC 编码函数
% 功能： 1. 切分数据 (1024 bits) -> 2. 编码 -> 3. 打孔 -> 4. 随机化 -> 5. 加 CSM
% 输入参数: 
%   input_bits    -逻辑向量, 必须是 1024 的整数倍
% 输出参数
%   tx_stream     -物理层比特流
% --------------------------

function tx_stream = ldpc_encoder(input_bits)
    % 1. 持久化变量
    persistent enc_obj punct_pat pn_seq csm_bits;
    addpath(genpath('.\data'));
    
    % 2. 初始化
    if isempty(enc_obj)
        % 配置参数
        config_file = 'CCSDS_C2_matrix.mat';
        CSM_HEX = '034776C7272895B0';
        
        % 检查文件
        if exist(config_file, 'file') ~= 2
            error('LDPC 错误: 未找到 "%s"。请先运行脚本 utils/generate_LDPC_matrix.m 生成矩阵。', config_file);
        end
        
        % 加载配置
        % fprintf('[LDPC] 正在初始化编码器 (加载本地矩阵)...\n');
        data = load(config_file);
        
        % 实例化系统对象
        enc_obj = comm.LDPCEncoder('ParityCheckMatrix', data.H);
        punct_pat = data.puncture_pattern;
        
        % 预计算随机化序列 (长度为打孔后的长度 2048)
        code_len = sum(punct_pat); 
        pn_seq = generate_pn_sequence(code_len);
        
        % 预计算 CSM
        csm_bits = hex2bit_MSB(CSM_HEX); 
    end

    % 运行时常量
    K_INFO = 1024;
    
    % 输入校验
    if iscolumn(input_bits), input_bits = input_bits'; end % 强转行向量
    
    total_len = length(input_bits);
    if mod(total_len, K_INFO) ~= 0
        error('LDPC 输入错误: 数据长度 %d 不是 %d 的倍数。请检查 scs_transmitter 的填充逻辑。', total_len, K_INFO);
    end
    
    num_blocks = total_len / K_INFO;
    
    % 计算输出长度: (64 CSM + 2048 Data) * N
    block_out_len = 64 + length(pn_seq);
    tx_stream = false(1, num_blocks * block_out_len);
    
    % 3 批量处理
    idx_in = 1;
    idx_out = 1;
    
    for i = 1:num_blocks
        % A. 提取信息位
        chunk_bits = input_bits(idx_in : idx_in + K_INFO - 1)';
        
        % B. LDPC 编码 (输出 2560 bits)
        full_codeword = step(enc_obj, chunk_bits)'; 
        
        % C. 打孔 (保留前 2048 bits)
        coded_bits = full_codeword(punct_pat);
        
        % D. 随机化 (XOR)
        % 从码块第一个比特开始异或
        randomized_bits = xor(coded_bits, pn_seq);
        
        % E. 插入 CSM (Prepend)
        tx_stream(idx_out : idx_out + block_out_len - 1) = [csm_bits, randomized_bits];
        
        % 更新索引
        idx_in = idx_in + K_INFO;
        idx_out = idx_out + block_out_len;
    end
end

% 伪随机序列生成器
function seq = generate_pn_sequence(len)
    % h(x) = x^8 + x^6 + x^4 + x^3 + x^2 + x + 1
    % 初始状态: 全1
    registers = true(1, 8); 
    seq = false(1, len);
    
    for k = 1:len
        % 输出位: Reg(8)
        out_bit = registers(8);
        seq(k) = out_bit;
        
        % 反馈计算
        feedback = xor(registers(8), registers(6));
        feedback = xor(feedback, registers(4));
        feedback = xor(feedback, registers(3));
        feedback = xor(feedback, registers(2));
        feedback = xor(feedback, registers(1));
        
        % 移位
        registers = [feedback, registers(1:7)];
    end
end
