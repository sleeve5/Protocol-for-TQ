% --------------------------
% PLTU组装函数
% 功能描述：组装邻近链路传输单元（PLTU：ASM + 传送帧 + CRC-32）
% 输入参数：
%   frame_data  - 逻辑向量（logical）：邻近空间链路传送帧（bit流）
%   crc32_code  - 逻辑向量（logical）：根据帧数据生成的4字节crc码
% 输出参数：
%   PLTU        - 逻辑向量（logical）：完整PLTU的bit流（行向量）
% --------------------------

function [PLTU] = build_PLTU(frame_data, crc_code)
    % 1. 标准固定参数定义
    ASM_HEX = 'FAF320';              % ASM固定序列（24bit）
    MAX_FRAME_LEN_BYTE = 2048;       % 传送帧最大长度（2048字节）
    
    % 2. 校验与统一输入维度
    % 校验传送帧数据类型
    if ~islogical(frame_data)
        error('BUILD_PLTU:TypeMismatch', '输入参数 frame_data 必须为逻辑向量（logical）！');
    end

    % 统一输入为行向量
    if iscolumn(frame_data)
        frame_data = frame_data';
    end
    if iscolumn(crc_code)
        crc_code = crc_code';
    end

    % 校验传送帧长度
    frame_len_bit = length(frame_data);
    if mod(frame_len_bit, 8) ~= 0
        error('BUILD_PLTU:LengthAlignment', '邻近空间链路传送帧长度必须为整数字节（bit流长度为8的整数倍）！');
    end
    frame_len_byte = frame_len_bit / 8;
  
    % 校验传送帧最大长度（不超过2048字节）
    if frame_len_byte > MAX_FRAME_LEN_BYTE
        error('BUILD_PLTU:MaxLengthExceeded', '传送帧长度超出标准上限！标准最大%d字节，当前为%d字节', MAX_FRAME_LEN_BYTE, frame_len_byte);
    end
    
    % 3. ASM生成
    ASM_bit = hex2bit_MSB(ASM_HEX);
    
    % 4. 组装PLTU（ASM + 传送帧 + CRC-32）
    PLTU = [ASM_bit, frame_data, crc_code];
end

