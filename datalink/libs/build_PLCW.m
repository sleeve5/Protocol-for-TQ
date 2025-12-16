function plcw_bits = build_PLCW(farm_state)
% BUILD_PLCW 生成 Proximity-1 PLCW (Proximity Link Control Word)
% 对应标准: CCSDS 211.0-B-6 Annex B (Fixed-Length SPDU)
%
% 输入 farm_state 结构体:
%   .V_R          : (0-255) 期望接收的下一个序列号
%   .Exp_Counter  : (0-7) 加速帧计数器
%   .PCID         : (0-1) 物理信道ID
%   .Retransmit   : (bool) 是否请求重传
%
% 输出:
%   plcw_bits     : 1x16 logical 向量

    % 1. Report Value (8 bits) -> V(R)
    % Bit 15-8 (Low byte in diagram, but usually transmitted MSB first in stream)
    % 标准 Figure 3-5 定义位序：Bit 15 是 Report Value 的 LSB。
    % 这里我们按照网络字节序（大端）生成：
    % Format(1) + Type(1) + Retx(1) + PCID(1) + Res(1) + Exp(3) + Report(8)
    
    % Bit 0: SPDU Format ID = 1 (Fixed Length)
    b_format = true;
    
    % Bit 1: SPDU Type ID = 0 (PLCW)
    b_type = false;
    
    % Bit 2: Retransmit Flag
    b_retx = logical(farm_state.Retransmit);
    
    % Bit 3: PCID
    b_pcid = logical(farm_state.PCID);
    
    % Bit 4: Reserved (0)
    b_res = false;
    
    % Bit 5-7: Expedited Frame Counter
    b_exp = de2bi(farm_state.Exp_Counter, 3, 'left-msb');
    
    % Bit 8-15: Report Value (V(R))
    b_report = de2bi(farm_state.V_R, 8, 'left-msb');
    
    % 拼接 (共 16 bits)
    % 放入 Payload 时通常需要补齐到字节，这里正好2字节
    plcw_bits = [b_format, b_type, b_retx, b_pcid, b_res, b_exp, b_report];
end