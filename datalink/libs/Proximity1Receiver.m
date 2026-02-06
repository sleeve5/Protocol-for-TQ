% classdef Proximity1Receiver < handle
%     % Proximity1Receiver 基于状态机的流式接收机
%     % 支持: 
%     %   - CodingType 1: Convolutional (K=7, Rate 1/2) + Viterbi 译码
%     %   - CodingType 2: LDPC (C2, Rate 1/2) + CSM 同步
% 
%     properties (Constant)
%         % 协议常量
% 
%         ASM_BITS_HEX = 'FAF320';
%         CSM_BITS_HEX = '034776C7272895B0';
% 
%         LDPC_CODED_LEN = 2048; % 打孔后的长度
%     end
% 
%     properties
%         % --- 状态机 ---
%         State           
%         CodingType      % 1=Conv, 2=LDPC
% 
%         % --- 缓冲区 ---
%         PhyBuffer       
%         LinkBuffer      
%         GlobalBitOffset 
% 
%         % --- LDPC 相关对象 ---
%         LDPCDecoderCfg  
%         PunctPattern    
%         PN_Sequence     
%         Pat_CSM         
%         CSM_Threshold
% 
%         % --- 卷积码相关对象 ---
%         ConvDecoderObj
% 
%         % --- 通用 ---
%         Pat_ASM         
%         FramesFound     
%     end
% 
%     methods
%         % =================================================================
%         % 构造函数：初始化
%         % =================================================================
%         function obj = Proximity1Receiver()
%             if nargin < 1, coding_type = 2; end % 默认为 LDPC
%             obj.CodingType = coding_type;
% 
%             obj.Pat_ASM = double(hex2bit_MSB(obj.ASM_BITS_HEX));
%             obj.GlobalBitOffset = 0;
%             obj.FramesFound = 0;
%             obj.PhyBuffer = [];
%             obj.LinkBuffer = [];
% 
%             if obj.CodingType == 2
%                 % --- LDPC 初始化 ---
%                 obj.Pat_CSM = double(hex2bit_MSB(obj.CSM_BITS_HEX));
%                 obj.CSM_Threshold = 15; 
%                 obj.initLDPC();
%                 obj.State = 'SEARCH_CSM';
% 
%             elseif obj.CodingType == 1
%                 % --- 卷积码 初始化 ---
%                 % CCSDS K=7, Rate 1/2, G1=171, G2=133
%                 trellis = poly2trellis(7, [171 133]);
% 
%                 % 使用 Unquantized 输入 (LLR)
%                 obj.ConvDecoderObj = comm.ViterbiDecoder(...
%                     'TrellisStructure', trellis, ...
%                     'InputFormat', 'Unquantized', ...
%                     'TracebackDepth', 35, ... % 5*K
%                     'TerminationMethod', 'Truncated');
% 
%                 obj.State = 'STREAMING_CONV';
%             else
%                 % 无编码或不支持
%                 obj.State = 'BYPASS';
%             end
%         end
% 
%         function reset(obj)
%             if obj.CodingType == 2
%                 obj.State = 'SEARCH_CSM';
%             else
%                 obj.State = 'STREAMING_CONV';
%             end
%             obj.PhyBuffer = [];
%             obj.LinkBuffer = [];
%             obj.GlobalBitOffset = 0;
%             obj.FramesFound = 0;
%             if ~isempty(obj.ConvDecoderObj), reset(obj.ConvDecoderObj); end
%         end
% 
%         % 内部加载逻辑 (替代 load_ldpc_config)
%         function initLDPC(obj)
%             % 定位数据文件 (相对于当前类文件的位置)
%             % 假设目录结构: libs/Proximity1Receiver.m, data/CCSDS_C2_matrix.mat
%             current_path = fileparts(mfilename('fullpath'));
%             data_file = fullfile(current_path, '..', 'data', 'CCSDS_C2_matrix.mat');
% 
%             if exist(data_file, 'file') ~= 2
%                 error('Proximity1Receiver: 找不到矩阵文件 %s。请先运行 utils/generate_LDPC_matrix.m', data_file);
%             end
% 
%             % 加载数据
%             tmp = load(data_file);
% 
%             % 保存打孔模式
%             obj.PunctPattern = tmp.puncture_pattern;
% 
%             % 初始化译码器对象 (注意: 必须转为 logical)
%             H_logical = logical(tmp.H);
%             obj.LDPCDecoderCfg = ldpcDecoderConfig(H_logical);
% 
%             % 预计算 PN 序列
%             len_coded = sum(obj.PunctPattern); % 应该 = 2048
%             obj.PN_Sequence = obj.generate_pn_seq(len_coded);
%         end
% 
%         % =================================================================
%         % 主处理函数：输入一段波形，输出提取到的帧
%         % =================================================================
%         function frames = step(obj, new_llrs)
%             frames = {};
% 
%             % 1. 将新数据推入物理层缓冲 (确保列向量)
%             obj.PhyBuffer = [obj.PhyBuffer; new_llrs(:)];
% 
%             % 2. 物理层状态机循环
%             while true
%                 switch obj.State
%                     case 'SEARCH_CSM'
%                         % 缓冲区是否有足够数据做一次相关? 
%                         if length(obj.PhyBuffer) < 64 + obj.LDPC_CODED_LEN
%                             % 数据不够解出一个完整的块，先等等
%                             % 实际上只要 > 64 就可以搜，但为了逻辑简单，我们等够一个块再搜
%                             if length(obj.PhyBuffer) < 2500 % 稍微多一点余量
%                                 break; 
%                             end
%                         end
% 
%                         % 执行 CSM 搜索 (只搜前段，提高效率)
%                         % 使用你写好的 frame_synchronizer
%                         % 搜索范围: 前 1000 个点足矣
%                         search_len = length(obj.PhyBuffer);
%                         search_segment = obj.PhyBuffer(1:search_len);
% 
%                         % 注意: frame_synchronizer 需要 double 输入
%                         % 软判决搜索，阈值 20 (经验值)
%                         csm_idx = frame_synchronizer(search_segment, obj.Pat_CSM, 20);
% 
%                         if ~isempty(csm_idx)
%                             % 找到了！锁定第一个 CSM
%                             lock_pos = csm_idx(1);
% 
%                             % 丢弃 CSM 及其之前的数据 (同步)
%                             % 保留 CSM 之后的数据用于解码
%                             % 下一个状态需要的数据起点:
%                             start_data = lock_pos + 64;
% 
%                             % 检查 buffer 是否够长
%                             if length(obj.PhyBuffer) >= start_data
%                                 obj.PhyBuffer = obj.PhyBuffer(start_data:end);
%                                 obj.State = 'ACCUMULATE_BLOCK';
%                             else
%                                 % CSM 在末尾，切完就没了，状态迁移，等下一次数据进来
%                                 obj.PhyBuffer = []; 
%                                 obj.State = 'ACCUMULATE_BLOCK';
%                             end
%                         else
%                             % 没找到，丢弃一部分旧数据防止 buffer 无限增长
%                             % 每次丢弃 500 个点，滑动窗口
%                             discard_len = 500;
%                             if length(obj.PhyBuffer) > discard_len
%                                 obj.PhyBuffer(1:discard_len) = [];
%                             end
%                             break; % 退出循环，等新数据
%                         end
% 
%                     case 'ACCUMULATE_BLOCK'
%                         % 等待凑够 2048 个 LLR
%                         if length(obj.PhyBuffer) >= obj.LDPC_CODED_LEN
%                             % 提取一个块
%                             block_data = obj.PhyBuffer(1:obj.LDPC_CODED_LEN);
% 
%                             % 从缓冲移除
%                             obj.PhyBuffer(1:obj.LDPC_CODED_LEN) = [];
% 
%                             % 执行译码
%                             decoded_bits = obj.decode_one_block(block_data);
% 
%                             % 将译码结果推入链路层缓冲
%                             obj.LinkBuffer = [obj.LinkBuffer, decoded_bits];
% 
%                             % 状态迁移：解完一个块后，通常后面紧接着就是下一个 CSM
%                             % 所以切回 SEARCH_CSM 状态去验证并锁定下一个块
%                             obj.State = 'SEARCH_CSM';
%                         else
%                             break; % 数据不够，等
%                         end
%                 end
%             end
% 
%             % 3. 链路层处理 (处理 LinkBuffer)
%             new_frames = obj.process_link_layer();
%             frames = [frames, new_frames];
%         end
% 
%         % =================================================================
%         % 内部核心算法
%         % =================================================================
% 
%         function info_bits = decode_one_block(obj, llr_in)
%             % 单块 LDPC 译码流程 (逻辑同 ldpc_decoder.m)
% 
%             % 1. 去随机化 (LLR 翻转)
%             % pn_seq 是 0/1，转换成 +1/-1: 0->+1, 1->-1
%             pn_sign = 1 - 2 * double(obj.PN_Sequence(:)); 
%             derand_llr = llr_in .* pn_sign;
% 
%             % 2. 逆打孔
%             full_len = length(obj.PunctPattern);
%             depunctured = zeros(full_len, 1);
%             depunctured(obj.PunctPattern) = derand_llr;
% 
%             % 3. 译码
%             decoded = ldpcDecode(depunctured, obj.LDPCDecoderCfg, 50);
%             info_bits = logical(decoded');
%         end
% 
%         function found_frames = process_link_layer(obj)
%             % 在 LinkBuffer 中寻找 ASM 并提取帧
%             found_frames = {};
% 
%             while true
%                 % 缓冲区太短，做不了任何事
%                 if length(obj.LinkBuffer) < (24 + 32 + 8) % ASM+CRC+MinData
%                     break;
%                 end
% 
%                 % 搜索 ASM
%                 bits_dbl = double(obj.LinkBuffer);
%                 asm_idx = frame_synchronizer(bits_dbl, obj.Pat_ASM, 0);
% 
%                 if isempty(asm_idx)
%                     % 没找到 ASM，保留最后 23 位，丢弃前面
%                     keep = 23;
%                     if length(obj.LinkBuffer) > keep
%                         obj.LinkBuffer = obj.LinkBuffer(end-keep+1:end);
%                     end
%                     break;
%                 end
% 
%                 % 找到了 ASM (取第一个)
%                 first_asm = asm_idx(1);
% 
%                 % 丢弃 ASM 之前的垃圾数据
%                 if first_asm > 1
%                     obj.LinkBuffer(1:first_asm-1) = [];
%                     % 更新: ASM 现在在位置 1
%                 end
% 
%                 % 尝试提取帧 (滑动 CRC)
%                 payload_start = 25; % ASM(24) 之后
%                 search_limit = length(obj.LinkBuffer);
% 
%                 frame_extracted = false;
% 
%                 % 最小帧长 (32 CRC + 8 Data)
%                 % 步长 8 (字节对齐)
%                 for len = 40 : 8 : (search_limit - payload_start + 1)
%                     segment = obj.LinkBuffer(payload_start : payload_start + len - 1);
% 
%                     % 快速 CRC 校验
%                     [isValid, cleanData] = CRC32_check(segment);
% 
%                     if isValid
%                         % 成功提取！
%                         found_frames{end+1} = cleanData;
%                         obj.FramesFound = obj.FramesFound + 1;
% 
%                         % 从缓冲中移除这一整帧 (包括 ASM 和 CRC)
%                         % 注意：这里直接移除 ASM+Frame+CRC
%                         % 剩下的数据可能是 Idle，也可能是下一个 ASM
%                         total_remove = 24 + len;
%                         obj.LinkBuffer(1:total_remove) = [];
% 
%                         frame_extracted = true;
%                         break; 
%                     end
%                 end
% 
%                 if ~frame_extracted
%                     % 找到了 ASM 但没找到匹配的 CRC
%                     % 可能是假 ASM，或者数据还没传完(跨次了)
% 
%                     % 如果缓冲区非常长(例如超过2个LDPC块)还没找到CRC，说明是假 ASM，丢弃它
%                     if length(obj.LinkBuffer) > 2048*2 
%                         obj.LinkBuffer(1:24) = []; 
%                     else
%                         break; % 等待更多数据
%                     end
%                 end
%             end
%         end
% 
%         function seq = generate_pn_seq(obj, len)
%             % PN 生成器 (同 ldpc_decoder)
%             registers = true(1, 8); 
%             seq = false(1, len);
%             for k = 1:len
%                 out_bit = registers(8);
%                 seq(k) = out_bit;
%                 feedback = xor(registers(8), registers(6));
%                 feedback = xor(feedback, registers(4));
%                 feedback = xor(feedback, registers(3));
%                 feedback = xor(feedback, registers(2));
%                 feedback = xor(feedback, registers(1));
%                 registers = [feedback, registers(1:7)];
%             end
%         end
%     end
% end

classdef Proximity1Receiver < handle
    % Proximity1Receiver 基于状态机的流式接收机 (v4.0 - 全协议栈支持)
    % 支持: 
    %   - CodingType 2: LDPC (C2, Rate 1/2) + CSM 同步
    %   - CodingType 1: Convolutional (K=7, Rate 1/2) + Viterbi 译码
    
    properties (Constant)
        ASM_BITS_HEX = 'FAF320';     % 24-bit ASM
        CSM_BITS_HEX = '034776C7272895B0';
        LDPC_CODED_LEN = 2048; 
    end
    
    properties
        % --- 状态机 ---
        State           
        CodingType      % 1=Conv, 2=LDPC
        
        % --- 缓冲区 ---
        PhyBuffer       
        LinkBuffer      
        GlobalBitOffset 
        
        % --- LDPC 相关对象 ---
        LDPCDecoderCfg  
        PunctPattern    
        PN_Sequence     
        Pat_CSM         
        CSM_Threshold
        
        % --- 卷积码相关对象 ---
        ConvDecoderObj
        
        % --- 通用 ---
        Pat_ASM         
        FramesFound     
    end
    
    methods
        function obj = Proximity1Receiver(coding_type)
            if nargin < 1, coding_type = 2; end % 默认为 LDPC
            obj.CodingType = coding_type;
            
            obj.Pat_ASM = double(hex2bit_MSB(obj.ASM_BITS_HEX));
            obj.GlobalBitOffset = 0;
            obj.FramesFound = 0;
            obj.PhyBuffer = [];
            obj.LinkBuffer = [];
            
            if obj.CodingType == 2
                % --- LDPC 初始化 ---
                obj.Pat_CSM = double(hex2bit_MSB(obj.CSM_BITS_HEX));
                obj.CSM_Threshold = 15; 
                obj.initLDPC();
                obj.State = 'SEARCH_CSM';
                
            elseif obj.CodingType == 1
                % --- 卷积码 初始化 ---
                % CCSDS K=7, Rate 1/2, G1=171, G2=133
                trellis = poly2trellis(7, [171 133]);
                
                % 使用 Unquantized 输入 (LLR)
                obj.ConvDecoderObj = comm.ViterbiDecoder(...
                    'TrellisStructure', trellis, ...
                    'InputFormat', 'Unquantized', ...
                    'TracebackDepth', 35, ... % 5*K
                    'TerminationMethod', 'Truncated');
                
                obj.State = 'STREAMING_CONV';
            else
                % 无编码或不支持
                obj.State = 'BYPASS';
            end
        end
        
        function reset(obj)
            if obj.CodingType == 2
                obj.State = 'SEARCH_CSM';
            else
                obj.State = 'STREAMING_CONV';
            end
            obj.PhyBuffer = [];
            obj.LinkBuffer = [];
            obj.GlobalBitOffset = 0;
            obj.FramesFound = 0;
            if ~isempty(obj.ConvDecoderObj), reset(obj.ConvDecoderObj); end
        end
        
        function initLDPC(obj)
            current_path = fileparts(mfilename('fullpath'));
            data_file = fullfile(current_path, '..', 'data', 'CCSDS_C2_matrix.mat');
            
            % 自动生成逻辑
            if exist(data_file, 'file') ~= 2
                utils_dir = fullfile(current_path, '..', 'utils');
                addpath(utils_dir);
                try generate_ccsds_c2_matrix(); catch; end
            end
            
            tmp = load(data_file);
            obj.PunctPattern = tmp.puncture_pattern;
            obj.LDPCDecoderCfg = ldpcDecoderConfig(logical(tmp.H));
            obj.PN_Sequence = obj.generate_pn_seq(sum(obj.PunctPattern));
        end
        
        % =================================================================
        % 主处理函数
        % =================================================================
        function frames = step(obj, new_llrs)
            frames = {};
            
            if obj.CodingType == 2 
                % =======================
                % LDPC 处理逻辑 (Block)
                % =======================
                obj.PhyBuffer = [obj.PhyBuffer; new_llrs(:)];
                
                while true
                    switch obj.State
                        case 'SEARCH_CSM'
                            if length(obj.PhyBuffer) < 64 + obj.LDPC_CODED_LEN
                                if length(obj.PhyBuffer) < 4096, break; end 
                            end
                            
                            search_len = length(obj.PhyBuffer);
                            search_hard = double(obj.PhyBuffer < 0);
                            csm_idx = frame_synchronizer(search_hard, obj.Pat_CSM, obj.CSM_Threshold);
                            
                            if ~isempty(csm_idx)
                                lock_pos = csm_idx(1);
                                req_len = lock_pos + 64 + obj.LDPC_CODED_LEN - 1;
                                
                                if length(obj.PhyBuffer) >= req_len
                                    start_data = lock_pos + 64;
                                    end_data = start_data + obj.LDPC_CODED_LEN - 1;
                                    block_data = obj.PhyBuffer(start_data:end_data);
                                    
                                    decoded_bits = obj.decode_ldpc_block(block_data);
                                    obj.LinkBuffer = [obj.LinkBuffer, decoded_bits];
                                    obj.PhyBuffer(1:end_data) = [];
                                else
                                    break; 
                                end
                            else
                                keep_len = 63;
                                if length(obj.PhyBuffer) > keep_len
                                    obj.PhyBuffer(1:end-keep_len) = [];
                                end
                                break; 
                            end
                        case 'ACCUMULATE_BLOCK'
                            obj.State = 'SEARCH_CSM'; 
                    end
                end
                
            elseif obj.CodingType == 1
                obj.PhyBuffer = [obj.PhyBuffer; new_llrs(:)];
                len = length(obj.PhyBuffer);
                num_pairs = floor(len / 2);
                
                if num_pairs > 0
                    proc_len = num_pairs * 2;
                    % ✅ 调用你的外部 decoder
                    decoded_bits = convolutional_decoder(obj.PhyBuffer(1:proc_len), false);
                    
                    obj.LinkBuffer = [obj.LinkBuffer, decoded_bits];
                    obj.PhyBuffer(1:proc_len) = [];
                end
                
            else
                % Uncoded Bypass
                hard_bits = new_llrs(:)' < 0;
                obj.LinkBuffer = [obj.LinkBuffer, hard_bits];
            end
            
            % =======================
            % 公共链路层处理
            % =======================
            frames = obj.process_link_layer();
        end
        
        function info_bits = decode_ldpc_block(obj, llr_in)
            pn_sign = 1 - 2 * double(obj.PN_Sequence(:)); 
            derand_llr = llr_in .* pn_sign;
            full_len = length(obj.PunctPattern);
            depunctured = zeros(full_len, 1);
            depunctured(obj.PunctPattern) = derand_llr;
            decoded = ldpcDecode(depunctured, obj.LDPCDecoderCfg, 50);
            info_bits = logical(decoded');
        end
        
        function found_frames = process_link_layer(obj)
            found_frames = {};
            while true
                if length(obj.LinkBuffer) < 56, break; end
                
                % ASM 搜索 (容错1位)
                asm_idx = frame_synchronizer(double(obj.LinkBuffer), obj.Pat_ASM, 1);
                
                if isempty(asm_idx)
                    keep = 23;
                    if length(obj.LinkBuffer) > keep
                        disc = length(obj.LinkBuffer) - keep;
                        obj.LinkBuffer(1:disc) = [];
                        obj.GlobalBitOffset = obj.GlobalBitOffset + disc;
                    end
                    break;
                end
                
                first_asm = asm_idx(1);
                if first_asm > 1
                    disc = first_asm - 1;
                    obj.LinkBuffer(1:disc) = [];
                    obj.GlobalBitOffset = obj.GlobalBitOffset + disc;
                end
                
                payload_start = 25; 
                frame_extracted = false;
                search_limit = length(obj.LinkBuffer);
                
                for len = 40 : 8 : (search_limit - payload_start + 1)
                    segment = obj.LinkBuffer(payload_start : payload_start + len - 1);
                    [isValid, cleanData] = CRC32_check(segment);
                    if isValid
                        found_frames{end+1} = cleanData;
                        obj.FramesFound = obj.FramesFound + 1;
                        
                        total_remove = 24 + len;
                        obj.LinkBuffer(1:total_remove) = [];
                        obj.GlobalBitOffset = obj.GlobalBitOffset + total_remove;
                        frame_extracted = true;
                        break; 
                    end
                end
                
                if ~frame_extracted
                    if length(obj.LinkBuffer) > 4096 
                        obj.LinkBuffer(1:24) = [];
                        obj.GlobalBitOffset = obj.GlobalBitOffset + 24;
                    else
                        break; 
                    end
                end
            end
        end

        function seq = generate_pn_seq(obj, len)
            registers = true(1, 8); seq = false(1, len);
            for k = 1:len
                out_bit = registers(8); seq(k) = out_bit;
                feedback = xor(registers(8), registers(6));
                feedback = xor(feedback, registers(4));
                feedback = xor(feedback, registers(3));
                feedback = xor(feedback, registers(2));
                feedback = xor(feedback, registers(1));
                registers = [feedback, registers(1:7)];
            end
        end
    end
end