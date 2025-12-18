% --------------------------
% 发送主控逻辑函数 (Transmitter)
% 功能：
%   实现邻近-1同步与编码子层的发送端控制逻辑，负责将离散的数据传送帧转换为物理层所需的连续比特流。
%   主要完成以下任务：
%   1. 时序控制：按顺序插入捕获序列、帧间空闲填充和尾序列。
%   2. 协议封装：调用CRC和PLTU组装函数，完成数据链路层封装。
%   3. 数据整形：执行强制字节对齐（补0）和LDPC块长度对齐（补空闲序列）。
%   4. 编码调度：根据配置参数将数据流送入信道编码器。
%
% 输入参数：
%   frame_queue - 单元数组 (Cell Array)：待发送的传送帧队列。
%                 每个元素必须是一个逻辑向量 (logical row vector)，代表一个原始数据帧。
%   sim_params  - 结构体 (Struct)：仿真与链路配置参数，包含以下字段：
%       .CodingType    - 整数：编码类型 (0:无编码, 1:卷积编码, 2:LDPC编码)。
%       .AcqSeqLen     - 整数：捕获序列长度 (bit)，用于接收机锁相。
%       .TailSeqLen    - 整数：尾序列长度 (bit)，用于结束传输平滑。
%       .InterFrameGap - 整数：帧间空闲填充长度 (bit)，模拟非连续传输。
%
% 输出参数：
%   encoded_symbol_stream - 逻辑向量 (logical)：
%                           经过封装、对齐和信道编码后的最终物理层符号流。
%   time_tags             - 结构体数组，包含 [.SeqNo, .BitIndex, .QoS]
% --------------------------

function [encoded_symbol_stream, time_tags] = scs_transmitter_timing(frame_queue, sim_params)
    % 1. 初始化与参数校验
    % 如果未提供参数结构体，初始化为空结构体
    if nargin < 2
        sim_params = struct();
    end
    
    % 设置默认参数
    if ~isfield(sim_params, 'CodingType'), sim_params.CodingType = 0; end      % 默认无编码
    if ~isfield(sim_params, 'AcqSeqLen'), sim_params.AcqSeqLen = 128 * 8; end  % 默认128字节捕获序列
    if ~isfield(sim_params, 'TailSeqLen'), sim_params.TailSeqLen = 64 * 8; end % 默认64字节尾序列
    if ~isfield(sim_params, 'InterFrameGap'), sim_params.InterFrameGap = 32; end % 默认32bit间隔

    buffer_idx = 1;
    stream_buffer = cell(1, 100); 

    % 用于记录时间标签的临时变量
    time_tags = [];
    current_bit_count = 0; % 追踪当前流的总长度

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
            
            % 如果输入帧长度不是8的倍数，强制字节对齐，在末尾补0 
            len_bits = length(current_frame);
            rem_bits = mod(len_bits, 8);
            
            if rem_bits ~= 0
                pad_len = 8 - rem_bits;
                fprintf('     [警告] 帧 #%d 长度(%d)非字节对齐，自动补 %d 个零。\n', i, len_bits, pad_len);
                % 补 false (0) 以对齐字节边界
                current_frame = [current_frame, false(1, pad_len)];
            end

            % --- [新增] 关键逻辑：解析 Header 获取元数据 ---
            % 只有拿到 SeqNo 和 QoS，才能生成标准的时间标签
            if length(current_frame) >= 40
                % 解析 SeqNo (Bit 32-39)
                seq_bits = current_frame(33:40);
                seq_no = bi2de(double(seq_bits), 'left-msb');
                % 解析 QoS (Bit 2)
                qos_bit = current_frame(3);
                qos_val = double(qos_bit);
            else
                seq_no = -1; qos_val = -1; % 无效帧
            end

            % 组装邻近链路传输单元 (PLTU)
            % 结构：ASM (24bit) + 传送帧 + CRC (32bit)
            % 计算 CRC 校验码
            [crc_code, ~] = CRC32(current_frame); 
            
            % 拼接生成 PLTU
            pltu_bits = build_PLTU(current_frame, crc_code);
            
            % --- [新增] 捕捉 Egress Time (ASM 结束时刻) ---
            % PLTU 结构: ASM(24) + Frame + CRC
            % ASM 位于 PLTU 最前端。
            % ASM 结束位置(绝对索引) = 当前流总长 + 24
            asm_end_index = current_bit_count + 24;
            
            % 记录标签
            tag.SeqNo = seq_no;
            tag.QoS = qos_val;
            tag.BitIndex = asm_end_index; % 这是逻辑索引，物理层需除以符号率
            time_tags = [time_tags; tag];

            % 更新流
            stream_buffer{buffer_idx} = pltu_bits;
            buffer_idx = buffer_idx + 1;
            current_bit_count = current_bit_count + length(pltu_bits);

            % 插入帧间空闲填充 (Inter-frame Gap)
            if (i < num_frames) && (sim_params.InterFrameGap > 0)
                gap = generate_idle_sequence(sim_params.InterFrameGap);
                stream_buffer{buffer_idx} = gap;
                buffer_idx = buffer_idx + 1;
                current_bit_count = current_bit_count + length(gap);
            end
        end
    else
        % 保持链路，若无数据发送，必须发送空闲序列以维持链路物理层锁定状态。
        fprintf('[Tx] 2. 无数据帧，插入保持(Keep-Alive)空闲序列...\n');
        stream_buffer{buffer_idx} = generate_idle_sequence(1024);
        buffer_idx = buffer_idx + 1;
    end

    % 4. 插入尾序列
    if sim_params.TailSeqLen > 0
        fprintf('[Tx] 3. 插入尾序列 (%d bits)...\n', sim_params.TailSeqLen);
        stream_buffer{buffer_idx} = generate_idle_sequence(sim_params.TailSeqLen);
        buffer_idx = buffer_idx + 1;
    end
    
    % 5. 数据流合并与对齐 (Streaming & Alignment)
    raw_bit_stream = [stream_buffer{1:buffer_idx-1}];

    % LDPC编码块长度对齐，输入长度必须固定为 1024 的倍数
    if sim_params.CodingType == 2 % LDPC 编码模式
        BLOCK_SIZE_K = 1024;
        current_len = length(raw_bit_stream);
        remainder = mod(current_len, BLOCK_SIZE_K);
        
        if remainder ~= 0
            padding_len = BLOCK_SIZE_K - remainder;
            fprintf('[Tx] 3.1 [LDPC对齐] 数据流非整块(%d)，追加 %d bits 填充数据。\n', current_len, padding_len);
            
            % 生成填充序列并追加
            padding_seq = generate_idle_sequence(padding_len);
            raw_bit_stream = [raw_bit_stream, padding_seq];
        end
    end

    % 6. 信道编码
    fprintf('[Tx] 4. 进入信道编码层 (Type: %d)...\n', sim_params.CodingType);
    encoded_symbol_stream = channel_encoder_dispatcher(raw_bit_stream, sim_params);
    
    fprintf('[Tx] --- 发送处理完成. 总符号数: %d ---\n', length(encoded_symbol_stream));
end

% --------------------------
% 信道编码调度函数 (Internal Helper)
% 功能：根据配置参数分发数据流到具体的信道编码器实现。
% 输入参数：
%   in_stream - 待编码的比特流 (logical)
%   params    - 包含 .CodingType 的配置结构体
% 输出参数：
%   out_stream - 编码后的符号流 (logical)
% --------------------------

function out_stream = channel_encoder_dispatcher(in_stream, params)
    switch params.CodingType
        case 0 % 无编码
            out_stream = in_stream;
            
        case 1 % 卷积编码
            % out_stream = convolutional_encode(in_stream); % 待实现
            out_stream = in_stream; 
            
        case 2 % LDPC 编码
            out_stream = ldpc_encoder(in_stream);
            
        otherwise
            error('未知的编码类型: %d', params.CodingType);
    end
end
