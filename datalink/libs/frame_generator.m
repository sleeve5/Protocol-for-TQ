function frame_bits = frame_generator(payload, header_config)
% FRAME_GENERATOR 构建 Proximity-1 Version-3 传送帧
%
% 输入:
%   payload       : 用户数据 (logical 向量, 必须是 8 的倍数)
%   header_config : 结构体，包含 SCID, QoS, SeqNo 等
% 输出:
%   frame_bits    : 完整的帧比特流 (Header + Payload)

    % 1. 计算长度字段 (Length Count C)
    % Frame Length = Header(5) + Payload(N)
    % C = Total_Bytes - 1
    payload_len_bits = length(payload);
    payload_len_bytes = ceil(payload_len_bits / 8);
    total_bytes = 5 + payload_len_bytes;
    frame_length_c = total_bytes - 1;
    
    if frame_length_c > 2047
        error('帧过长！Proximity-1 最大支持 2048 字节。');
    end

    % 2. 组装帧头 (40 bits) - 严格参照 Figure 3-3
    % Bit 0-1: Version ('10')
    ver_bits = [1 0]; 
    
    % Bit 2: QoS
    qos_bit = logical(header_config.QoS);
    
    % Bit 3: PDU Type
    pdu_type_bit = logical(header_config.PDU_Type);
    
    % Bit 4-5: DFC ID (假设 '11' User Defined)
    dfc_bits = [1 1]; 
    
    % Bit 6-15: SCID (10 bits)
    scid_bits = de2bi(header_config.SCID, 10, 'left-msb');
    
    % Bit 16: PCID
    pcid_bit = logical(header_config.PCID);
    
    % Bit 17-19: Port ID
    port_bits = de2bi(header_config.PortID, 3, 'left-msb');
    
    % Bit 20: Source/Dest ID
    sd_bit = logical(header_config.SourceDest);
    
    % Bit 21-31: Frame Length (11 bits)
    len_bits = de2bi(frame_length_c, 11, 'left-msb');
    
    % Bit 32-39: Sequence Number (8 bits)
    seq_bits = de2bi(header_config.SeqNo, 8, 'left-msb');
    
    % 拼接头
    header = [ver_bits, qos_bit, pdu_type_bit, dfc_bits, ...
              scid_bits, pcid_bit, port_bits, sd_bit, ...
              len_bits, seq_bits];
          
    % 3. 拼接 Payload
    frame_bits = logical([header, payload]);
end