% classdef Proximity1Receiver_timing < handle
%     % Proximity1Receiver (v3.2 - 硬判决同步修正版)
%     % 修复: 在CSM搜索阶段强制使用硬判决，避免高SNR下LLR幅度波动导致的虚假锁定
% 
%     properties (Constant)
%         ASM_BITS_HEX = 'FAF320';
%         CSM_BITS_HEX = '034776C7272895B0';
%         LDPC_CODED_LEN = 2048; 
%         LDPC_INFO_LEN  = 1024;
%     end
% 
%     properties
%         State; PhyBuffer; LinkBuffer; GlobalBitOffset; FramesFound;
%         LDPCDecoderCfg; PunctPattern; PN_Sequence; Pat_ASM; Pat_CSM;
%     end
% 
%     methods
%         function obj = Proximity1Receiver_timing()
%             obj.Pat_ASM = double(hex2bit_MSB(obj.ASM_BITS_HEX));
%             obj.Pat_CSM = double(hex2bit_MSB(obj.CSM_BITS_HEX));
%             obj.initLDPC();
%             obj.reset();
%         end
% 
%         function reset(obj)
%             obj.State = 'SEARCH_CSM';
%             obj.PhyBuffer = [];
%             obj.LinkBuffer = [];
%             obj.GlobalBitOffset = 0;
%             obj.FramesFound = 0;
%         end
% 
%         function initLDPC(obj)
%             current_path = fileparts(mfilename('fullpath'));
%             data_file = fullfile(current_path, '..', 'data', 'CCSDS_C2_matrix.mat');
%             if exist(data_file, 'file') ~= 2, error('找不到矩阵文件'); end
%             tmp = load(data_file);
%             obj.PunctPattern = tmp.puncture_pattern;
%             obj.LDPCDecoderCfg = ldpcDecoderConfig(logical(tmp.H));
%             obj.PN_Sequence = obj.generate_pn_seq(sum(obj.PunctPattern));
%         end
% 
%         function [frames, time_tags] = step(obj, new_llrs)
%             frames = {}; time_tags = [];
%             % 存入 LLR
%             obj.PhyBuffer = [obj.PhyBuffer; new_llrs(:)];
% 
%             while true
%                 switch obj.State
%                     case 'SEARCH_CSM'
%                         if length(obj.PhyBuffer) < 64 + obj.LDPC_CODED_LEN
%                             if length(obj.PhyBuffer) < 4096, break; end 
%                         end
% 
%                         % 搜索范围
%                         search_len = min(length(obj.PhyBuffer), 2000);
%                         search_segment = obj.PhyBuffer(1:search_len);
% 
%                         % [关键修正] 强制转换为硬判决进行同步搜索
%                         % LLR < 0 -> Bit 1 (double 1)
%                         % LLR >= 0 -> Bit 0 (double 0)
%                         % 这样阈值 '4' 就明确代表"允许错4个比特"
%                         search_hard = double(search_segment < 0);
% 
%                         % 阈值: 允许 64 bit 中错 4 bit (容错率 ~6%)
%                         csm_idx = frame_synchronizer(search_hard, obj.Pat_CSM, 4);
% 
%                         if ~isempty(csm_idx)
%                             % 锁定第一个
%                             lock_pos = csm_idx(1);
% 
%                             % 检查数据是否足够
%                             req_len = lock_pos + 64 + obj.LDPC_CODED_LEN - 1;
% 
%                             if length(obj.PhyBuffer) >= req_len
%                                 % 提取数据 (注意要提取原始 LLR，不是硬判决)
%                                 start_data = lock_pos + 64;
%                                 end_data = start_data + obj.LDPC_CODED_LEN - 1;
%                                 block_data = obj.PhyBuffer(start_data:end_data);
% 
%                                 % 译码
%                                 decoded_bits = obj.decode_one_block(block_data);
%                                 obj.LinkBuffer = [obj.LinkBuffer, decoded_bits];
% 
%                                 % 移除已用数据
%                                 obj.PhyBuffer(1:end_data) = [];
%                             else
%                                 break; % 等待
%                             end
%                         else
%                             % 没找到，丢弃旧数据
%                             keep_len = 63;
%                             if length(obj.PhyBuffer) > keep_len
%                                 obj.PhyBuffer(1:end-keep_len) = [];
%                             end
%                             break; 
%                         end
% 
%                     case 'ACCUMULATE_BLOCK'
%                         obj.State = 'SEARCH_CSM'; 
%                 end
%             end
% 
%             [frames, time_tags] = obj.process_link_layer();
%         end
% 
%         function info_bits = decode_one_block(obj, llr_in)
%             pn_sign = 1 - 2 * double(obj.PN_Sequence(:)); 
%             derand_llr = llr_in .* pn_sign;
%             full_len = length(obj.PunctPattern);
%             depunctured = zeros(full_len, 1);
%             depunctured(obj.PunctPattern) = derand_llr;
%             decoded = ldpcDecode(depunctured, obj.LDPCDecoderCfg, 50);
%             info_bits = logical(decoded');
%         end
% 
%         function [found_frames, found_tags] = process_link_layer(obj)
%             found_frames = {}; found_tags = [];
%             while true
%                 if length(obj.LinkBuffer) < 56, break; end
% 
%                 % ASM 搜索 (硬判决，容错0)
%                 asm_idx = frame_synchronizer(double(obj.LinkBuffer), obj.Pat_ASM, 2);
% 
%                 if isempty(asm_idx)
%                     keep = 23;
%                     if length(obj.LinkBuffer) > keep
%                         disc = length(obj.LinkBuffer) - keep;
%                         obj.LinkBuffer(1:disc) = [];
%                         obj.GlobalBitOffset = obj.GlobalBitOffset + disc;
%                     end
%                     break;
%                 end
% 
%                 first_asm = asm_idx(1);
%                 if first_asm > 1
%                     disc = first_asm - 1;
%                     obj.LinkBuffer(1:disc) = [];
%                     obj.GlobalBitOffset = obj.GlobalBitOffset + disc;
%                 end
% 
%                 payload_start = 25; 
%                 frame_extracted = false;
%                 search_limit = length(obj.LinkBuffer);
% 
%                 % 滑动 CRC 搜索
%                 for len = 40 : 8 : (search_limit - payload_start + 1)
%                     segment = obj.LinkBuffer(payload_start : payload_start + len - 1);
%                     [isValid, cleanData] = CRC32_check(segment);
% 
%                     if isValid
%                         found_frames{end+1} = cleanData;
%                         obj.FramesFound = obj.FramesFound + 1;
% 
%                         [header, ~] = frame_parser(cleanData);
%                         tag.SeqNo = header.SeqNo;
%                         tag.QoS = header.QoS;
%                         tag.LogicBitIndex = obj.GlobalBitOffset + 24; 
%                         found_tags = [found_tags; tag];
% 
%                         total_remove = 24 + len;
%                         obj.LinkBuffer(1:total_remove) = [];
%                         obj.GlobalBitOffset = obj.GlobalBitOffset + total_remove;
%                         frame_extracted = true;
%                         break; 
%                     end
%                 end
% 
%                 if ~frame_extracted
%                     if length(obj.LinkBuffer) > 4096 
%                         obj.LinkBuffer(1:24) = [];
%                         obj.GlobalBitOffset = obj.GlobalBitOffset + 24;
%                     else
%                         break; 
%                     end
%                 end
%             end
%         end
% 
%         function seq = generate_pn_seq(obj, len)
%             registers = true(1, 8); seq = false(1, len);
%             for k = 1:len
%                 out_bit = registers(8); seq(k) = out_bit;
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

classdef Proximity1Receiver_timing < handle
    % Proximity1Receiver (v5.0 - Final Fix for Convolutional Code)
    
    properties (Constant)
        ASM_BITS_HEX = 'FAF320';     
        CSM_BITS_HEX = '034776C7272895B0';
        LDPC_CODED_LEN = 2048; 
    end
    
    properties
        State; CodingType;
        PhyBuffer; LinkBuffer; GlobalBitOffset; FramesFound;
        LDPCDecoderCfg; PunctPattern; PN_Sequence; Pat_ASM; Pat_CSM; CSM_Threshold;
        ConvDecoderObj;
        IsFirstConvOutput; % [新增] 标记是否是卷积码的第一次输出
    end
    
    methods
        function obj = Proximity1Receiver_timing(coding_type)
            if nargin < 1, coding_type = 2; end 
            obj.CodingType = coding_type;
            
            obj.Pat_ASM = double(hex2bit_MSB(obj.ASM_BITS_HEX));
            obj.GlobalBitOffset = 0;
            obj.FramesFound = 0;
            obj.PhyBuffer = [];
            obj.LinkBuffer = [];
            
            if obj.CodingType == 2
                obj.Pat_CSM = double(hex2bit_MSB(obj.CSM_BITS_HEX));
                obj.CSM_Threshold = 15; 
                obj.initLDPC();
                obj.State = 'SEARCH_CSM';
            elseif obj.CodingType == 1
                % 卷积码初始化 (CCSDS K=7, Rate 1/2)
                % 使用 [171 133] (八进制)
                trellis = poly2trellis(7, [171 133]);
                obj.ConvDecoderObj = comm.ViterbiDecoder(...
                    'TrellisStructure', trellis, ...
                    'InputFormat', 'Unquantized', ...
                    'TracebackDepth', 35, ... % 35足够了
                    'TerminationMethod', 'Truncated'); 
                obj.State = 'STREAMING_CONV';
            else
                obj.State = 'BYPASS';
            end
        end
        
        function reset(obj)
            obj.PhyBuffer = [];
            obj.LinkBuffer = [];
            obj.GlobalBitOffset = 0;
            obj.FramesFound = 0;
            obj.IsFirstConvOutput = true;
            if ~isempty(obj.ConvDecoderObj), reset(obj.ConvDecoderObj); end
            if obj.CodingType == 2, obj.State = 'SEARCH_CSM'; else, obj.State = 'STREAMING_CONV'; end
        end
        
        function initLDPC(obj)
            current_path = fileparts(mfilename('fullpath'));
            data_file = fullfile(current_path, '..', 'data', 'CCSDS_C2_matrix.mat');
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
        
        function [frames, time_tags] = step(obj, new_llrs)
            frames = {}; time_tags = [];
            
            % 1. 存入 Buffer (强制列向量)
            obj.PhyBuffer = [obj.PhyBuffer; double(new_llrs(:))];
            
            if obj.CodingType == 2 % LDPC
                while true
                    switch obj.State
                        case 'SEARCH_CSM'
                            if length(obj.PhyBuffer) < 64 + obj.LDPC_CODED_LEN
                                if length(obj.PhyBuffer) < 4096, break; end 
                            end
                            search_hard = double(obj.PhyBuffer < 0);
                            csm_idx = frame_synchronizer(search_hard, obj.Pat_CSM, obj.CSM_Threshold);
                            if ~isempty(csm_idx)
                                lock_pos = csm_idx(1);
                                req_len = lock_pos + 64 + obj.LDPC_CODED_LEN - 1;
                                if length(obj.PhyBuffer) >= req_len
                                    block_data = obj.PhyBuffer(lock_pos+64 : lock_pos+64+obj.LDPC_CODED_LEN-1);
                                    decoded_bits = obj.decode_ldpc_block(block_data);
                                    obj.LinkBuffer = [obj.LinkBuffer, decoded_bits];
                                    obj.PhyBuffer(1:req_len) = []; 
                                else break; end
                            else
                                keep = 63;
                                if length(obj.PhyBuffer) > keep, obj.PhyBuffer(1:end-keep) = []; end
                                break; 
                            end
                        case 'ACCUMULATE_BLOCK', obj.State = 'SEARCH_CSM'; 
                    end
                end
                
            elseif obj.CodingType == 1 % Convolutional
                len = length(obj.PhyBuffer);
                num_pairs = floor(len / 2);
                
                if num_pairs > 0
                    proc_len = num_pairs * 2;
                    data_to_dec = obj.PhyBuffer(1:proc_len);
                    
                    % G2 反转恢复
                    data_to_dec(2:2:end) = -data_to_dec(2:2:end);
                    
                    % Viterbi 译码
                    decoded_bits = step(obj.ConvDecoderObj, data_to_dec);
                    bits_to_store = logical(decoded_bits');
                    
                    if obj.IsFirstConvOutput
                    % 丢弃前 35 位 (TracebackDepth)
                    % 注意: decoded_bits 长度可能小于 35 (虽然很少见)
                    TRACEBACK_DEPTH = 35; % 甚至可以设为 70 以防万一
                    
                        if length(bits_to_store) > TRACEBACK_DEPTH
                            bits_to_store = bits_to_store(TRACEBACK_DEPTH+1:end);
                            obj.IsFirstConvOutput = false; % 标记已处理
                        else
                            % 数据太少，全丢弃，标志位保持 true，等待下一波
                            bits_to_store = [];
                        end
                    end

                    % 存入 LinkBuffer (行向量)
                    obj.LinkBuffer = [obj.LinkBuffer, bits_to_store];
                    obj.PhyBuffer(1:proc_len) = [];
                end
                
            else % Uncoded
                obj.LinkBuffer = [obj.LinkBuffer, (new_llrs(:)' < 0)];
            end
            
            [frames, time_tags] = obj.process_link_layer();
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
        
        function [found_frames, found_tags] = process_link_layer(obj)
            found_frames = {}; found_tags = [];
            
            while true
                if length(obj.LinkBuffer) < 56, break; end
                
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

                    [isValid, cleanData] = CRC32_check(double(segment));
                    if isValid
                        found_frames{end+1} = cleanData;
                        obj.FramesFound = obj.FramesFound + 1;
                        try
                            [header, ~] = frame_parser(cleanData);
                            tag.SeqNo = header.SeqNo;
                            tag.QoS = header.QoS;
                            tag.LogicBitIndex = obj.GlobalBitOffset + 24; 
                            found_tags = [found_tags; tag];
                        catch; end
                        
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