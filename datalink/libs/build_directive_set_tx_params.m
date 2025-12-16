function bits = build_directive_set_tx_params()
% 构造 SET TRANSMITTER PARAMETERS 指令 (16 bits)
% 参照 Annex B1.2 Figure B-2

    % Directive Type (3 bits): 000
    type = [0 0 0];
    
    % Freq (3 bits): 000 (默认)
    freq = [0 0 0];
    
    % Encoding (2 bits): 00 (LDPC Rate 1/2, 需根据 B1.2.4 修改)
    % 假设标准中 00=LDPC
    enc = [0 0]; 
    
    % Modulation (1 bit): 1 (PSK)
    mod = 1;
    
    % Rate (4 bits): 0000 (占位)
    rate = [0 0 0 0];
    
    % Mode (3 bits): 001 (Proximity-1 Protocol)
    mode = [0 0 1];
    
    % 拼接 (LSB to MSB 定义? 标准 Figure B-2 是位图)
    % 通常按网络序(大端)发送：
    % Type(15-13), Freq(12-10), Enc(9-8), Mod(7), Rate(6-3), Mode(2-0)
    bits = logical([type, freq, enc, mod, rate, mode]);
end