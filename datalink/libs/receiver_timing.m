% --------------------------
% 接收主控逻辑 (Receiver)
% 功能: 物理层同步 -> LDPC译码 -> ASM同步 -> 滑动CRC搜索与提取
% 输入：
%   rx_soft_bits - 接收到的软信息流 (LLR)
%   sim_params   - 仿真参数 (CodingType等)
%   io_layer_obj - 
% 输出：
%   recovered_frames - 成功通过 CRC 校验的帧集合
%   rx_time_tags     -结构体数组 (.SeqNo, .BitIndex)
% --------------------------

function [recovered_frames, rx_time_tags] = receiver_timing(rx_soft_bits, sim_params, io_layer_obj)
% RECEIVER Proximity-1 批处理接收机 (支持定时业务)
%
% 输入:
%   rx_soft_bits : 接收到的 LLR 软信息
%   sim_params   : 仿真参数
%   io_layer_obj : (可选) IO子层对象，用于数据上交
%
% 输出:
%   recovered_frames : 成功提取的帧 (Cell Array)
%   rx_time_tags     : 时间标签结构体数组 [.SeqNo, .QoS, .LogicBitIndex]

    recovered_frames = {};
    rx_time_tags = [];
    
    % --- 1. 标准参数 ---
    ASM_HEX = 'FAF320';
    CSM_HEX = '034776C7272895B0';
    asm_bits = hex2bit_MSB(ASM_HEX);
    csm_bits = hex2bit_MSB(CSM_HEX);
    
    decoded_stream = [];

    % --- 2. 物理层处理 (CSM + LDPC) ---
    switch sim_params.CodingType
        case 2 % LDPC
            % A. 物理层同步
            csm_indices = frame_synchronizer(rx_soft_bits, csm_bits, 4);
            if isempty(csm_indices), return; end
            
            lock_pos = csm_indices(1);
            
            % B. 数据提取
            BLOCK_LEN = 2112; 
            valid_len = length(rx_soft_bits) - lock_pos + 1;
            num_blocks = floor(valid_len / BLOCK_LEN);
            
            if num_blocks < 1, return; end
            
            aligned_rx = rx_soft_bits(lock_pos : lock_pos + num_blocks*BLOCK_LEN - 1);
            
            % C. 译码
            decoded_stream = ldpc_decoder(aligned_rx);
            
        case 0 % Uncoded
            decoded_stream = rx_soft_bits < 0; 
            
        otherwise
            error('未实现的编码类型');
    end
    
    if isempty(decoded_stream), return; end

    % --- 3. 数据链路层处理 (ASM + Sliding CRC) ---
    
    % A. 搜索所有 ASM 位置
    asm_indices = frame_synchronizer(double(decoded_stream), asm_bits, 0);
    
    if isempty(asm_indices)
        % warning('SCS_RX: 未找到 ASM 帧头');
        return;
    end
    
    total_bits = length(decoded_stream);
    
    % B. 遍历每个 ASM，尝试提取帧
    for i = 1:length(asm_indices)
        start_idx = asm_indices(i);
        payload_start = start_idx + 24; % 跳过 ASM
        
        if i < length(asm_indices)
            search_limit = asm_indices(i+1) - 1;
        else
            search_limit = total_bits;
        end
        
        % C. 滑动 CRC 搜索
        potential_segment = decoded_stream(payload_start : search_limit);
        max_len = length(potential_segment);
        
        % 最小帧长: 8 bit data + 32 bit CRC = 40 bits
        for len = 40 : 8 : max_len 
            current_try = potential_segment(1:len);
            
            [isValid, clean_frame] = CRC32_check(current_try);
            
            if isValid
                recovered_frames{end+1} = clean_frame;
                
                % =========================================================
                % [关键新增] 捕获时间标签信息 (Ingress Time Tagging Info)
                % =========================================================
                
                % 1. 解析帧头获取 SeqNo 和 QoS
                % 这里的 clean_frame 包含 Header，不含 CRC
                [header, payload] = frame_parser(clean_frame);
                
                % 2. 计算 ASM 结束位置的逻辑索引
                % start_idx 是 ASM 第1位，长度24
                % End Index = start_idx + 24 - 1
                asm_end_idx = start_idx + 23;
                
                % 3. 记录标签
                tag.SeqNo = header.SeqNo;
                tag.QoS = header.QoS;
                tag.LogicBitIndex = asm_end_idx;
                
                rx_time_tags = [rx_time_tags; tag];
                
                % =========================================================
                
                % 如果有 IO 层对象，上交数据
                if nargin >= 3 && ~isempty(io_layer_obj)
                    io_layer_obj.receive_frame_data(header, payload);
                end
                
                break; % 找到一个有效帧后跳出滑动搜索，处理下一个 ASM
            end
        end
    end
end