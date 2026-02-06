% --------------------------
% 发送主控逻辑函数 (Transmitter - Final Version)
% 功能：
%   实现邻近-1同步与编码子层的发送端控制逻辑，负责将离散的数据传送帧转换为物理层所需的连续比特流。
%   集成功能：帧封装、CRC校验、流控制、LDPC/卷积编码、时间标签捕获。
%
% 输入参数：
%   frame_queue - 单元数组 (Cell Array)：待发送的传送帧队列。
%   sim_params  - 结构体 (Struct)：配置参数 (CodingType, AcqSeqLen, etc.)
%
% 输出参数：
%   encoded_symbol_stream - 逻辑向量：最终物理层符号流。
%   time_tags             - 结构体数组：[.SeqNo, .BitIndex, .QoS]
% --------------------------

function [encoded_symbol_stream, time_tags] = scs_transmitter_timing(frame_queue, sim_params)
    % 1. 初始化与参数校验
    if nargin < 2, sim_params = struct(); end
    if ~isfield(sim_params, 'CodingType'), sim_params.CodingType = 0; end
    if ~isfield(sim_params, 'AcqSeqLen'), sim_params.AcqSeqLen = 1024; end 
    if ~isfield(sim_params, 'TailSeqLen'), sim_params.TailSeqLen = 256; end
    if ~isfield(sim_params, 'InterFrameGap'), sim_params.InterFrameGap = 64; end

    buffer_idx = 1;
    stream_buffer = cell(1, 100); 

    time_tags = [];
    current_bit_count = 0; 

    ASM_HEX = 'FAF320'; % 24 bits (Link Layer ASM)

    % 2. 插入捕获序列 (Acquisition Sequence)
    if sim_params.AcqSeqLen > 0
        fprintf('[Tx] 1. 生成捕获序列 (%d bits)...\n', sim_params.AcqSeqLen);
        seq = generate_idle_sequence(sim_params.AcqSeqLen);
        stream_buffer{buffer_idx} = seq;
        buffer_idx = buffer_idx + 1;
        current_bit_count = current_bit_count + length(seq);
    end

    % 3. 处理数据帧 (PLTU Generation)
    num_frames = length(frame_queue);
    
    if num_frames > 0
        fprintf('[Tx] 2. 开始处理 %d 个数据帧...\n', num_frames);
        
        for i = 1:num_frames
            current_frame = frame_queue{i};
            
            % 强制字节对齐
            len_bits = length(current_frame);
            rem_bits = mod(len_bits, 8);
            if rem_bits ~= 0
                pad_len = 8 - rem_bits;
                fprintf('     [警告] 帧 #%d 补零 %d 位。\n', i, pad_len);
                current_frame = [current_frame, false(1, pad_len)];
            end

            % 解析 Header 获取元数据 (用于 Time Tag)
            if length(current_frame) >= 40
                seq_bits = current_frame(33:40);
                seq_no = bi2de(double(seq_bits), 'left-msb');
                qos_bit = current_frame(3);
                qos_val = double(qos_bit);
            else
                seq_no = -1; qos_val = -1; 
            end

            % 组装 PLTU (ASM + Frame + CRC)
            [crc_code, ~] = CRC32(current_frame); 
            
            % 使用 build_PLTU (默认 ASM='FAF320')
            % 如果 build_PLTU 支持第三个参数 ASM_HEX，可以传入
            pltu_bits = build_PLTU(current_frame, crc_code);
            
            % 捕捉 Egress Time (ASM 结束时刻)
            % ASM 长度固定为 24
            asm_end_index = current_bit_count + 24;
            
            % 记录标签
            tag.SeqNo = seq_no;
            tag.QoS = qos_val;
            tag.BitIndex = asm_end_index; 
            time_tags = [time_tags; tag];

            % 更新流
            stream_buffer{buffer_idx} = pltu_bits;
            buffer_idx = buffer_idx + 1;
            current_bit_count = current_bit_count + length(pltu_bits);

            % 插入帧间空闲填充
            if (i < num_frames) && (sim_params.InterFrameGap > 0)
                gap = generate_idle_sequence(sim_params.InterFrameGap);
                stream_buffer{buffer_idx} = gap;
                buffer_idx = buffer_idx + 1;
                current_bit_count = current_bit_count + length(gap);
            end
        end
    else
        % Keep-Alive
        fprintf('[Tx] 2. 无数据帧，插入空闲序列...\n');
        stream_buffer{buffer_idx} = generate_idle_sequence(1024);
        buffer_idx = buffer_idx + 1;
    end

    % 4. 插入尾序列
    if sim_params.TailSeqLen > 0
        fprintf('[Tx] 3. 插入尾序列 (%d bits)...\n', sim_params.TailSeqLen);
        stream_buffer{buffer_idx} = generate_idle_sequence(sim_params.TailSeqLen);
        buffer_idx = buffer_idx + 1;
    end
    
    % 5. 合并流
    raw_bit_stream = [stream_buffer{1:buffer_idx-1}];

    % 6. 信道编码调度 (包含 Padding 和 Encoding)
    fprintf('[Tx] 4. 进入信道编码层 (Type: %d)...\n', sim_params.CodingType);
    
    switch sim_params.CodingType
        case 0 % Uncoded
            encoded_symbol_stream = raw_bit_stream;
            
        case 1 % Convolutional Code
            % 直接调用卷积编码器 (流式，无需 Padding)
            encoded_symbol_stream = convolutional_encoder(raw_bit_stream);
            
        case 2 % LDPC Code
            % 执行 LDPC 对齐 (Padding)
            BLOCK_SIZE_K = 1024;
            current_len = length(raw_bit_stream);
            remainder = mod(current_len, BLOCK_SIZE_K);
        
            if remainder ~= 0
                padding_len = BLOCK_SIZE_K - remainder;
                fprintf('[Tx] 3.1 [LDPC对齐] 数据流非整块(%d)，追加 %d bits 填充数据。\n', current_len, padding_len);
                padding_seq = generate_idle_sequence(padding_len);
                raw_bit_stream = [raw_bit_stream, padding_seq];
            end
            
            % 调用 LDPC 编码器
            encoded_symbol_stream = ldpc_encoder(raw_bit_stream);
            
        otherwise
            error('SCS: Unknown CodingType %d', sim_params.CodingType);
    end
    
    fprintf('[Tx] --- 发送处理完成. 总符号数: %d ---\n', length(encoded_symbol_stream));
end