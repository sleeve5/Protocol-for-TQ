classdef Proximity1Receiver_timing < handle
    % Proximity1Receiver (v3.2 - 硬判决同步修正版)
    % 修复: 在CSM搜索阶段强制使用硬判决，避免高SNR下LLR幅度波动导致的虚假锁定
    
    properties (Constant)
        ASM_BITS_HEX = 'FAF320';
        CSM_BITS_HEX = '034776C7272895B0';
        LDPC_CODED_LEN = 2048; 
        LDPC_INFO_LEN  = 1024;
    end
    
    properties
        State; PhyBuffer; LinkBuffer; GlobalBitOffset; FramesFound;
        LDPCDecoderCfg; PunctPattern; PN_Sequence; Pat_ASM; Pat_CSM;
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
            obj.GlobalBitOffset = 0;
            obj.FramesFound = 0;
        end
        
        function initLDPC(obj)
            current_path = fileparts(mfilename('fullpath'));
            data_file = fullfile(current_path, '..', 'data', 'CCSDS_C2_matrix.mat');
            if exist(data_file, 'file') ~= 2, error('找不到矩阵文件'); end
            tmp = load(data_file);
            obj.PunctPattern = tmp.puncture_pattern;
            obj.LDPCDecoderCfg = ldpcDecoderConfig(logical(tmp.H));
            obj.PN_Sequence = obj.generate_pn_seq(sum(obj.PunctPattern));
        end
        
        function [frames, time_tags] = step(obj, new_llrs)
            frames = {}; time_tags = [];
            % 存入 LLR
            obj.PhyBuffer = [obj.PhyBuffer; new_llrs(:)];
            
            while true
                switch obj.State
                    case 'SEARCH_CSM'
                        if length(obj.PhyBuffer) < 64 + obj.LDPC_CODED_LEN
                            if length(obj.PhyBuffer) < 4096, break; end 
                        end
                        
                        % 搜索范围
                        search_len = min(length(obj.PhyBuffer), 2000);
                        search_segment = obj.PhyBuffer(1:search_len);
                        
                        % [关键修正] 强制转换为硬判决进行同步搜索
                        % LLR < 0 -> Bit 1 (double 1)
                        % LLR >= 0 -> Bit 0 (double 0)
                        % 这样阈值 '4' 就明确代表"允许错4个比特"
                        search_hard = double(search_segment < 0);
                        
                        % 阈值: 允许 64 bit 中错 4 bit (容错率 ~6%)
                        csm_idx = frame_synchronizer(search_hard, obj.Pat_CSM, 4);
                        
                        if ~isempty(csm_idx)
                            % 锁定第一个
                            lock_pos = csm_idx(1);
                            
                            % 检查数据是否足够
                            req_len = lock_pos + 64 + obj.LDPC_CODED_LEN - 1;
                            
                            if length(obj.PhyBuffer) >= req_len
                                % 提取数据 (注意要提取原始 LLR，不是硬判决)
                                start_data = lock_pos + 64;
                                end_data = start_data + obj.LDPC_CODED_LEN - 1;
                                block_data = obj.PhyBuffer(start_data:end_data);
                                
                                % 译码
                                decoded_bits = obj.decode_one_block(block_data);
                                obj.LinkBuffer = [obj.LinkBuffer, decoded_bits];
                                
                                % 移除已用数据
                                obj.PhyBuffer(1:end_data) = [];
                            else
                                break; % 等待
                            end
                        else
                            % 没找到，丢弃旧数据
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
            
            [frames, time_tags] = obj.process_link_layer();
        end
        
        function info_bits = decode_one_block(obj, llr_in)
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
                
                % ASM 搜索 (硬判决，容错0)
                asm_idx = frame_synchronizer(double(obj.LinkBuffer), obj.Pat_ASM, 0);
                
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
                
                % 滑动 CRC 搜索
                for len = 40 : 8 : (search_limit - payload_start + 1)
                    segment = obj.LinkBuffer(payload_start : payload_start + len - 1);
                    [isValid, cleanData] = CRC32_check(segment);
                    
                    if isValid
                        found_frames{end+1} = cleanData;
                        obj.FramesFound = obj.FramesFound + 1;
                        
                        [header, ~] = frame_parser(cleanData);
                        tag.SeqNo = header.SeqNo;
                        tag.QoS = header.QoS;
                        tag.LogicBitIndex = obj.GlobalBitOffset + 24; 
                        found_tags = [found_tags; tag];
                        
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