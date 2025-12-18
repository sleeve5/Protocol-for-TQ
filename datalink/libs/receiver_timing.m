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

    % --- 1. 标准参数 ---
    ASM_HEX = 'FAF320';
    CSM_HEX = '034776C7272895B0';
    asm_bits = hex2bit_MSB(ASM_HEX);
    csm_bits = hex2bit_MSB(CSM_HEX);
    ASM_MAX_ERRORS = 0; % 建议0
    CSM_THRESHOLD = 20; % 建议20
    decoded_stream = [];

    recovered_frames = {};
    rx_time_tags = [];

    % --- 2. 物理层处理 (CSM + LDPC) ---
    switch sim_params.CodingType
        case 2 % LDPC
            % A. 物理层同步
            fprintf('\n[RX] 2.1 尝试进行 CSM 软同步 (LDPC 块同步)...\n');

            csm_indices = frame_synchronizer(rx_soft_bits, csm_bits, CSM_THRESHOLD);

            if isempty(csm_indices)
                warning('[RX FAIL] 🚨 故障点 1：未找到 CSM (阈值 %d)。LDPC 译码流程终止。', CSM_THRESHOLD);
                return;
            end

            lock_pos = csm_indices(1);
            fprintf('    [RX SUCCESS] CSM 同步成功 @ 索引 %d。\n', lock_pos);

            % B. 数据提取
            BLOCK_LEN = 2112; 
            valid_len = length(rx_soft_bits) - lock_pos + 1;
            num_blocks = floor(valid_len / BLOCK_LEN);
            
            if num_blocks < 1
                warning('[RX FAIL] 警告：CSM 之后数据流不足一个完整的 LDPC 块 (%d bits)，终止。', BLOCK_LEN);
                return; 
            end
            
            aligned_rx = rx_soft_bits(lock_pos : lock_pos + num_blocks*BLOCK_LEN - 1);
            fprintf('    准备对 %d 个 LDPC 码块 (%d bits) 进行译码...\n', num_blocks, length(aligned_rx));

            % C. 译码
            decoded_stream = ldpc_decoder(aligned_rx);
            
            if isempty(decoded_stream) || all(decoded_stream==0) || all(decoded_stream==1)
                warning('[RX FAIL] 🚨 故障点 2：LDPC 译码结果异常 (可能 LLR 极性错误或信噪比过低)，退出帧同步。');
                return; 
            end
            
            fprintf('    [RX SUCCESS] LDPC 译码完成。信息比特总长: %d bits。\n', length(decoded_stream));

        case 0 % Uncoded
            decoded_stream = rx_soft_bits < 0; 
            
        otherwise
            error('未实现的编码类型');
    end
    
    if isempty(decoded_stream), return; end

    % --- 3. 数据链路层处理 (ASM + Sliding CRC) ---
    % 这里的 decoded_stream 是 "ASM + Frame + CRC + Idle + ASM ..." 的混合流
    fprintf('\n[RX] 3.1 尝试进行 ASM 硬同步...\n');
    % A. 搜索所有 ASM 位置
    asm_indices = frame_synchronizer(double(decoded_stream), asm_bits, ASM_MAX_ERRORS);
    
    if isempty(asm_indices)
        warning('[RX FAIL] 🚨 故障点 3：未找到 ASM 帧头 (允许 %d 误码)。帧提取终止。', ASM_MAX_ERRORS);
        return;
    end

    fprintf('    [RX SUCCESS] 找到 %d 个潜在 ASM 帧头。\n', length(asm_indices));

    % B. 遍历每个 ASM，尝试提取后续的 PLTU
    total_bits = length(decoded_stream);
    
    for i = 1:length(asm_indices)
        start_idx = asm_indices(i);
        payload_start = start_idx + 24; % 跳过 ASM
        
        % 确定搜索的最大范围 (不能超过下一个 ASM 或流的末尾)
        if i < length(asm_indices)
            search_limit = asm_indices(i+1) - 1;
        else
            search_limit = total_bits;
        end
        
        % C. 滑动 CRC 搜索 (Sliding Search)
        % Proximity-1 帧长通常是字节(8 bits)对齐的
        % 我们从最小帧长开始试，直到搜索限制
        
        found_frame = false;
        min_frame_len = 8; % 最小1字节
        
        % 提取出"潜在的最大数据段"
        potential_segment = decoded_stream(payload_start : search_limit);
        max_len = length(potential_segment);
        
        % 步长为 8 bits (1字节)
        for len = 32+8 : 8 : max_len 
            % len 是 [Frame + CRC] 的总长度
            % 所以最小长度应该是 CRC(32) + 1 byte
            
            current_try = potential_segment(1:len);
            
            % 调用 CRC 校验
            [isValid, clean_frame] = CRC32_check(current_try);
            
            % if isValid
            %     % D. 校验通过！
            %     % fprintf('    [RX] 发现有效帧 @ ASM#%d, 长度 %d bits\n', i, length(clean_frame));
            %     recovered_frames{end+1} = clean_frame;
            %     found_frame = true;
            %     break; % 找到一个就可以停止了 (假设ASM之间只有一个帧)
            % end
            if isValid
                recovered_frames{end+1} = clean_frame;
                
                % --- [新增] 记录时间标签 ---
                % 解析帧头获取 SeqNo
                [header, payload] = frame_parser(clean_frame);
                
                % 标准 5.2.2: "trailing edge of the last bit of the ASM"
                % ASM 长度 24，所以结束位置 = start_idx + 24 - 1
                asm_end_idx = start_idx + 23; 
                
                tag.SeqNo = header.SeqNo;
                
                % 注意：这里的 asm_end_idx 是在"译码后比特流"中的索引
                % 我们需要将其转换为"接收到的物理层符号流"中的大致时间
                % 在仿真中，我们可以简单地返回这个逻辑索引，
                % 或者假设 物理时间 = 逻辑索引 / 数据速率 (忽略处理延迟)
                tag.LogicBitIndex = asm_end_idx;
                
                rx_time_tags = [rx_time_tags; tag];

                % [新增集成] 如果传入了 IO 对象，则进行上层分发
                if nargin >= 3 && ~isempty(io_layer_obj)
                    % 解析帧头
                    [header, payload] = frame_parser(clean_frame);
                    % 上交数据
                    io_layer_obj.receive_frame_data(header, payload);
                end
                
                break; 
            end
            
        end
        
        if ~found_frame
            % 如果遍历完了都没通过，说明这个 ASM 后面可能只是噪声或者帧出错了
            % fprintf('    [RX] ASM#%d 后未找到有效 CRC，跳过。\n', i);
        end
    end
    if isempty(recovered_frames)
        fprintf('[RX FAIL] 🚨 故障点 4：成功同步 ASM，但在所有 ASM 后续的滑动 CRC 搜索中，未能找到有效帧。\n');
    else
        fprintf('[RX SUCCESS] 最终成功恢复 %d 个有效帧。\n', length(recovered_frames));
    end
end
