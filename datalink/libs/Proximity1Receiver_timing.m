classdef Proximity1Receiver_timing < handle
    % Proximity1Receiver 基于状态机的流式接收机 (v2.0 - 支持定时业务)
    
    properties (Constant)
        ASM_BITS_HEX = 'FAF320';
        CSM_BITS_HEX = '034776C7272895B0';
        
        LDPC_CODED_LEN = 2048; 
        LDPC_INFO_LEN  = 1024;
    end
    
    properties
        % --- 状态机 ---
        State           
        
        % --- 缓冲区 ---
        PhyBuffer       
        LinkBuffer      
        
        % --- [新增] 时序追踪 ---
        GlobalBitOffset % 记录 LinkBuffer(1) 对应全局比特流的索引位置
        
        % --- 计数器 ---
        FramesFound     
        
        % --- 核心对象 ---
        LDPCDecoderCfg  
        PunctPattern    
        PN_Sequence     
        
        % --- 缓存 Pattern ---
        Pat_ASM         
        Pat_CSM         
    end
    
    methods
        function obj = Proximity1Receiver_timing()
            obj.Pat_ASM = double(hex2bit_MSB(obj.ASM_BITS_HEX));
            obj.Pat_CSM = double(hex2bit_MSB(obj.CSM_BITS_HEX));
            obj.initLDPC();
            obj.reset();
        end
        
        function reset(obj)
            obj.State = 'SEARCH_CSM';
            obj.PhyBuffer = [];
            obj.LinkBuffer = [];
            obj.GlobalBitOffset = 0; % [新增] 重置计数器
            obj.FramesFound = 0;
        end
        
        function initLDPC(obj)
            % (保持不变，省略以节省篇幅，请保留原有的加载逻辑)
            current_path = fileparts(mfilename('fullpath'));
            data_file = fullfile(current_path, '..', 'data', 'CCSDS_C2_matrix.mat');
            if exist(data_file, 'file') ~= 2
                 error('Proximity1Receiver: 找不到矩阵文件');
            end
            tmp = load(data_file);
            obj.PunctPattern = tmp.puncture_pattern;
            H_logical = logical(tmp.H);
            obj.LDPCDecoderCfg = ldpcDecoderConfig(H_logical);
            len_coded = sum(obj.PunctPattern); 
            obj.PN_Sequence = obj.generate_pn_seq(len_coded);
        end
        
        % =================================================================
        % 主处理函数 (接口修改: 增加 time_tags 输出)
        % =================================================================
        function [frames, time_tags] = step(obj, new_llrs)
            frames = {};
            time_tags = []; % 结构体数组: .SeqNo, .BitIndex
            
            % 1. 物理层缓冲
            obj.PhyBuffer = [obj.PhyBuffer; new_llrs(:)];
            
            % 2. 物理层状态机
            while true
                switch obj.State
                    case 'SEARCH_CSM'
                        if length(obj.PhyBuffer) < 64 + obj.LDPC_CODED_LEN
                            if length(obj.PhyBuffer) < 3000, break; end 
                        end
                        
                        search_len = min(length(obj.PhyBuffer), 1000);
                        csm_idx = frame_synchronizer(obj.PhyBuffer(1:search_len), obj.Pat_CSM, 20);
                        
                        if ~isempty(csm_idx)
                            lock_pos = csm_idx(1);
                            start_data = lock_pos + 64;
                            
                            if length(obj.PhyBuffer) >= start_data
                                obj.PhyBuffer = obj.PhyBuffer(start_data:end);
                                obj.State = 'ACCUMULATE_BLOCK';
                            else
                                obj.PhyBuffer = []; 
                                obj.State = 'ACCUMULATE_BLOCK';
                            end
                        else
                            discard_len = 500;
                            if length(obj.PhyBuffer) > discard_len
                                obj.PhyBuffer(1:discard_len) = [];
                            end
                            break; 
                        end
                        
                    case 'ACCUMULATE_BLOCK'
                        if length(obj.PhyBuffer) >= obj.LDPC_CODED_LEN
                            block_data = obj.PhyBuffer(1:obj.LDPC_CODED_LEN);
                            obj.PhyBuffer(1:obj.LDPC_CODED_LEN) = [];
                            
                            decoded_bits = obj.decode_one_block(block_data);
                            obj.LinkBuffer = [obj.LinkBuffer, decoded_bits];
                            
                            obj.State = 'SEARCH_CSM';
                        else
                            break; 
                        end
                end
            end
            
            % 3. 链路层处理 (返回帧和时间标签)
            [new_frames, new_tags] = obj.process_link_layer();
            
            frames = [frames, new_frames];
            if ~isempty(new_tags)
                time_tags = [time_tags; new_tags];
            end
        end
        
        function info_bits = decode_one_block(obj, llr_in)
            % (保持不变)
            pn_sign = 1 - 2 * double(obj.PN_Sequence(:)); 
            derand_llr = llr_in .* pn_sign;
            full_len = length(obj.PunctPattern);
            depunctured = zeros(full_len, 1);
            depunctured(obj.PunctPattern) = derand_llr;
            decoded = ldpcDecode(depunctured, obj.LDPCDecoderCfg, 50);
            info_bits = logical(decoded');
        end
        
        % =================================================================
        % 链路层处理 (核心修改: 维护 Offset 和计算 Index)
        % =================================================================
        function [found_frames, found_tags] = process_link_layer(obj)
            found_frames = {};
            found_tags = [];
            
            while true
                if length(obj.LinkBuffer) < (24 + 32 + 8) 
                    break;
                end
                
                % 搜索 ASM
                bits_dbl = double(obj.LinkBuffer);
                asm_idx = frame_synchronizer(bits_dbl, obj.Pat_ASM, 0);
                
                if isempty(asm_idx)
                    % 丢弃数据前，必须更新 Offset
                    keep = 23;
                    if length(obj.LinkBuffer) > keep
                        discard_count = length(obj.LinkBuffer) - keep;
                        obj.LinkBuffer(1:discard_count) = [];
                        
                        % [更新] 全局位移累加
                        obj.GlobalBitOffset = obj.GlobalBitOffset + discard_count;
                    end
                    break;
                end
                
                first_asm = asm_idx(1);
                
                % 丢弃 ASM 之前的垃圾数据
                if first_asm > 1
                    discard_count = first_asm - 1;
                    obj.LinkBuffer(1:discard_count) = [];
                    obj.GlobalBitOffset = obj.GlobalBitOffset + discard_count;
                end
                
                % 提取帧
                payload_start = 25; 
                search_limit = length(obj.LinkBuffer);
                frame_extracted = false;
                
                for len = 40 : 8 : (search_limit - payload_start + 1)
                    segment = obj.LinkBuffer(payload_start : payload_start + len - 1);
                    [isValid, cleanData] = CRC32_check(segment);
                    
                    if isValid
                        found_frames{end+1} = cleanData;
                        obj.FramesFound = obj.FramesFound + 1;
                        
                        % --- [新增] 计算时间标签 ---
                        % 获取 SeqNo
                        [header, ~] = frame_parser(cleanData);
                        
                        % 计算 ASM 结束位置的全局索引
                        % 当前 Buffer 头部就是 ASM (因为前面垃圾已丢)
                        % ASM 长度 24。
                        % 绝对索引 = 当前Offset + 24
                        asm_end_global_idx = obj.GlobalBitOffset + 24;
                        
                        tag.SeqNo = header.SeqNo;
                        tag.LogicBitIndex = asm_end_global_idx;
                        found_tags = [found_tags; tag];
                        
                        % 移除已提取的数据
                        total_remove = 24 + len;
                        obj.LinkBuffer(1:total_remove) = [];
                        obj.GlobalBitOffset = obj.GlobalBitOffset + total_remove;
                        
                        frame_extracted = true;
                        break; 
                    end
                end
                
                if ~frame_extracted
                    if length(obj.LinkBuffer) > 2048*2 
                        % 强制丢弃错误的 ASM
                        obj.LinkBuffer(1:24) = [];
                        obj.GlobalBitOffset = obj.GlobalBitOffset + 24;
                    else
                        break; 
                    end
                end
            end
        end
        
        function seq = generate_pn_seq(obj, len)
            % (保持不变)
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