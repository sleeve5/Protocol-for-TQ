% --------------------------
% CRC编码函数
% 功能：计算输入二进制序列的CRC校验码，并输出编码后的完整数据（数据+CRC）。
% 输入参数：
%   input_data_bin   - 待计算的原始数据（logical或double类型，MSB优先）
% 输出参数：
%   crc_checksum_bin - 计算得到的CRC校验码（logical类型行向量）
%   encodedData      - 原始数据附加CRC校验码后的完整序列（logical类型行向量）
% --------------------------

function [crc_checksum_bin, encodedData] = CRC32(input_data_bin)
    % 1. CRC 算法参数配置
    CRC_POLY_HEX = '00A00805';      % 生成多项式 G(x) 系数 (32位)
    CRC_DEGREE = 32;
    INITIAL_STATE_HEX = '00000000'; % 初始值 0 (32位填充)

    % 2. 构造 N+1 阶多项式向量
    % 构造完整的 N+1 阶多项式：[X^N, X^(N-1), ..., X^0]，最高次项 X^N 总是 1
    poly_prime_vector_row = hex2bit_MSB(CRC_POLY_HEX); % 得到 MSB 优先的行向量
    CRC_POLY_VECTOR = logical([true, poly_prime_vector_row]);
    
    % 3. 初始状态：转换为 32 位二进制列向量
    INITIAL_CONDITIONS_BIN = hex2bit_MSB(INITIAL_STATE_HEX)'; 

    % 4. 实例化 CRC 对象
    crcGen = comm.CRCGenerator( ...
        'Polynomial', CRC_POLY_VECTOR, ... 
        'InitialConditions', INITIAL_CONDITIONS_BIN, ...
        'DirectMethod', true);     % 最终异或值
    
    % 5. 输入数据预处理
    % 统一转换为 logical 列向量
    if ~iscolumn(input_data_bin)
        input_data_bin = input_data_bin(:);
    end
    if ~islogical(input_data_bin)
        input_data_bin = logical(input_data_bin);
    end
    
    % 6. CRC 生成与提取
    % 使用 CRC 生成器计算编码数据（原始数据 + 校验码），输出为列向量
    encodedData_col = crcGen(input_data_bin); 
    
    % 提取 CRC 校验码 (BIN)
    crc_checksum_bin_col = encodedData_col(end - CRC_DEGREE + 1 : end);

    % 7. 格式化输出行向量
    crc_checksum_bin = crc_checksum_bin_col';
    encodedData = encodedData_col';
end

