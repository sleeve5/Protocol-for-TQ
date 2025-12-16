function [parsed_frame, payload] = frame_parser(rx_bits)
% FRAME_PARSER 解析 Proximity-1 Version-3 传送帧
%
% 输入:
%   rx_bits : 逻辑向量 (C&S层译码并去CRC后的数据)
%
% 输出:
%   parsed_frame : 包含头部字段的结构体
%   payload      : 剥离头部后的用户数据

    % 1. 长度检查 (Header 最小 5 字节 = 40 bits)
    if length(rx_bits) < 40
        warning('FrameParser: 输入数据过短，无法解析头部');
        parsed_frame = []; payload = [];
        return;
    end

    % 2. 提取头部 (前 40 bits)
    header_bits = rx_bits(1:40);
    
    % 3. 解析字段 (严格对应 CCSDS 211.0 Figure 3-3)
    % 注意: bi2de 默认是 right-msb，但通信协议通常是 left-msb (大端)
    
    % Bit 0-1: Version (必须为 2 / '10')
    parsed_frame.Version = bi2de(header_bits(1:2), 'left-msb');
    
    % Bit 2: QoS (0=Seq, 1=Expedited)
    parsed_frame.QoS = header_bits(3);
    
    % Bit 3: PDU Type (0=User Data, 1=Protocol/PLCW)
    parsed_frame.PDU_Type = header_bits(4);
    
    % Bit 4-5: DFC ID
    parsed_frame.DFC_ID = bi2de(header_bits(5:6), 'left-msb');
    
    % Bit 6-15: Spacecraft ID (10 bits)
    parsed_frame.SCID = bi2de(header_bits(7:16), 'left-msb');
    
    % Bit 16: PCID
    parsed_frame.PCID = header_bits(17);
    
    % Bit 17-19: Port ID (3 bits)
    parsed_frame.PortID = bi2de(header_bits(18:20), 'left-msb');
    
    % Bit 20: Source/Dest ID
    parsed_frame.SourceDest = header_bits(21);
    
    % Bit 21-31: Frame Length (11 bits)
    % Length Count C = Total Octets - 1
    len_count = bi2de(header_bits(22:32), 'left-msb');
    parsed_frame.Length_Cnt = len_count;
    total_bytes = len_count + 1;
    total_bits_expected = total_bytes * 8;
    
    % Bit 32-39: Frame Sequence Number (8 bits)
    parsed_frame.SeqNo = bi2de(header_bits(33:40), 'left-msb');
    
    % 4. 提取 Payload
    % 实际上 scs_receiver 输出的数据长度可能包含了填充
    % 我们可以利用 Header 里的 Length 字段来精确截取
    
    if length(rx_bits) >= total_bits_expected
        % 精确截取 (Header 40 bits 之后)
        payload = rx_bits(41 : total_bits_expected);
    else
        % 如果实际长度小于 Header 宣称的长度，说明出错了
        warning('FrameParser: 实际接收长度 (%d) 小于帧头定义长度 (%d)', ...
            length(rx_bits), total_bits_expected);
        payload = rx_bits(41:end); % 尽力而为
    end
end