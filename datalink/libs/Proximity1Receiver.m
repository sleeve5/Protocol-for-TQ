classdef Proximity1Receiver < handle
    % Proximity1Receiver 基于状态机的流式接收机 (自包含修正版)
    % 修复：移除对不存在的 load_ldpc_config 的依赖，直接在内部加载矩阵
    
    properties (Constant)
        % 协议常量
        % CSM = 034776C7272895B0 (64 bit)
        CSM_BITS = logical([0 0 0 0 0 0 1 1 0 1 0 0 0 1 1 1 0 1 1 1 0 1 1 0 1 1 0 0 0 1 1 1 0 0 1 0 0 1 1 1 0 0 1 0 1 0 0 0 1 0 0 1 0 1 0 1 1 0 1 1 0 0 0 0]); 
        % 注意：上面的CSM可能有误，建议直接用 hex2bit 生成
        % 此处为了方便，我们在构造函数里用 hex2bit_MSB 重新赋值
        
        ASM_BITS_HEX = 'FAF320';
        CSM_BITS_HEX = '034776C7272895B0';
        
        LDPC_CODED_LEN = 2048; % 打孔后的长度
        LDPC_INFO_LEN  = 1024;
    end
    
    properties
        % --- 状态机状态 ---
        State           % 'SEARCH_CSM' 或 'ACCUMULATE_BLOCK'
        
        % --- 缓冲区 ---
        PhyBuffer       % 物理层输入缓冲 (存 LLR)
        LinkBuffer      % 链路层比特缓冲 (存译码后的 0/1)
        
        % --- 计数器 ---
        FramesFound     % 成功计数
        
        % --- 核心对象 (内部维护) ---
        LDPCDecoderCfg  % ldpcDecoderConfig 对象
        PunctPattern    % 打孔模式 logical 向量
        PN_Sequence     % 接收端去随机化序列
        
        % --- 缓存的 Pattern ---
        Pat_ASM         % ASM 比特序列 (double)
        Pat_CSM         % CSM 比特序列 (double)
    end
    
    methods
        % =================================================================
        % 构造函数：初始化
        % =================================================================
        function obj = Proximity1Receiver()
            % 1. 初始化常量
            obj.Pat_ASM = double(hex2bit_MSB(obj.ASM_BITS_HEX));
            obj.Pat_CSM = double(hex2bit_MSB(obj.CSM_BITS_HEX));
            
            % 2. 加载并初始化 LDPC 核心
            obj.initLDPC();
            
            % 3. 重置状态
            obj.reset();
        end
        
        function reset(obj)
            obj.State = 'SEARCH_CSM';
            obj.PhyBuffer = [];
            obj.LinkBuffer = [];
            obj.FramesFound = 0;
        end
        
        % 内部加载逻辑 (替代 load_ldpc_config)
        function initLDPC(obj)
            % 定位数据文件 (相对于当前类文件的位置)
            % 假设目录结构: libs/Proximity1Receiver.m, data/CCSDS_C2_matrix.mat
            current_path = fileparts(mfilename('fullpath'));
            data_file = fullfile(current_path, '..', 'data', 'CCSDS_C2_matrix.mat');
            
            if exist(data_file, 'file') ~= 2
                error('Proximity1Receiver: 找不到矩阵文件 %s。请先运行 utils/generate_LDPC_matrix.m', data_file);
            end
            
            % 加载数据
            tmp = load(data_file);
            
            % 保存打孔模式
            obj.PunctPattern = tmp.puncture_pattern;
            
            % 初始化译码器对象 (注意: 必须转为 logical)
            H_logical = logical(tmp.H);
            obj.LDPCDecoderCfg = ldpcDecoderConfig(H_logical);
            
            % 预计算 PN 序列
            len_coded = sum(obj.PunctPattern); % 应该 = 2048
            obj.PN_Sequence = obj.generate_pn_seq(len_coded);
        end
        
        % =================================================================
        % 主处理函数：输入一段波形，输出提取到的帧
        % =================================================================
        function frames = step(obj, new_llrs)
            frames = {};
            
            % 1. 将新数据推入物理层缓冲 (确保列向量)
            obj.PhyBuffer = [obj.PhyBuffer; new_llrs(:)];
            
            % 2. 物理层状态机循环
            while true
                switch obj.State
                    case 'SEARCH_CSM'
                        % 缓冲区是否有足够数据做一次相关? 
                        if length(obj.PhyBuffer) < 64 + obj.LDPC_CODED_LEN
                            % 数据不够解出一个完整的块，先等等
                            % 实际上只要 > 64 就可以搜，但为了逻辑简单，我们等够一个块再搜
                            if length(obj.PhyBuffer) < 2500 % 稍微多一点余量
                                break; 
                            end
                        end
                        
                        % 执行 CSM 搜索 (只搜前段，提高效率)
                        % 使用你写好的 frame_synchronizer
                        % 搜索范围: 前 1000 个点足矣
                        search_len = min(length(obj.PhyBuffer), 1000);
                        search_segment = obj.PhyBuffer(1:search_len);
                        
                        % 注意: frame_synchronizer 需要 double 输入
                        % 软判决搜索，阈值 20 (经验值)
                        csm_idx = frame_synchronizer(search_segment, obj.Pat_CSM, 20);
                        
                        if ~isempty(csm_idx)
                            % 找到了！锁定第一个 CSM
                            lock_pos = csm_idx(1);
                            
                            % 丢弃 CSM 及其之前的数据 (同步)
                            % 保留 CSM 之后的数据用于解码
                            % 下一个状态需要的数据起点:
                            start_data = lock_pos + 64;
                            
                            % 检查 buffer 是否够长
                            if length(obj.PhyBuffer) >= start_data
                                obj.PhyBuffer = obj.PhyBuffer(start_data:end);
                                obj.State = 'ACCUMULATE_BLOCK';
                            else
                                % CSM 在末尾，切完就没了，状态迁移，等下一次数据进来
                                obj.PhyBuffer = []; 
                                obj.State = 'ACCUMULATE_BLOCK';
                            end
                        else
                            % 没找到，丢弃一部分旧数据防止 buffer 无限增长
                            % 每次丢弃 500 个点，滑动窗口
                            discard_len = 500;
                            if length(obj.PhyBuffer) > discard_len
                                obj.PhyBuffer(1:discard_len) = [];
                            end
                            break; % 退出循环，等新数据
                        end
                        
                    case 'ACCUMULATE_BLOCK'
                        % 等待凑够 2048 个 LLR
                        if length(obj.PhyBuffer) >= obj.LDPC_CODED_LEN
                            % 提取一个块
                            block_data = obj.PhyBuffer(1:obj.LDPC_CODED_LEN);
                            
                            % 从缓冲移除
                            obj.PhyBuffer(1:obj.LDPC_CODED_LEN) = [];
                            
                            % 执行译码
                            decoded_bits = obj.decode_one_block(block_data);
                            
                            % 将译码结果推入链路层缓冲
                            obj.LinkBuffer = [obj.LinkBuffer, decoded_bits];
                            
                            % 状态迁移：解完一个块后，通常后面紧接着就是下一个 CSM
                            % 所以切回 SEARCH_CSM 状态去验证并锁定下一个块
                            obj.State = 'SEARCH_CSM';
                        else
                            break; % 数据不够，等
                        end
                end
            end
            
            % 3. 链路层处理 (处理 LinkBuffer)
            new_frames = obj.process_link_layer();
            frames = [frames, new_frames];
        end
        
        % =================================================================
        % 内部核心算法
        % =================================================================
        
        function info_bits = decode_one_block(obj, llr_in)
            % 单块 LDPC 译码流程 (逻辑同 ldpc_decoder.m)
            
            % 1. 去随机化 (LLR 翻转)
            % pn_seq 是 0/1，转换成 +1/-1: 0->+1, 1->-1
            pn_sign = 1 - 2 * double(obj.PN_Sequence(:)); 
            derand_llr = llr_in .* pn_sign;
            
            % 2. 逆打孔
            full_len = length(obj.PunctPattern);
            depunctured = zeros(full_len, 1);
            depunctured(obj.PunctPattern) = derand_llr;
            
            % 3. 译码
            decoded = ldpcDecode(depunctured, obj.LDPCDecoderCfg, 50);
            info_bits = logical(decoded');
        end
        
        function found_frames = process_link_layer(obj)
            % 在 LinkBuffer 中寻找 ASM 并提取帧
            found_frames = {};
            
            while true
                % 缓冲区太短，做不了任何事
                if length(obj.LinkBuffer) < (24 + 32 + 8) % ASM+CRC+MinData
                    break;
                end
                
                % 搜索 ASM
                bits_dbl = double(obj.LinkBuffer);
                asm_idx = frame_synchronizer(bits_dbl, obj.Pat_ASM, 0);
                
                if isempty(asm_idx)
                    % 没找到 ASM，保留最后 23 位，丢弃前面
                    keep = 23;
                    if length(obj.LinkBuffer) > keep
                        obj.LinkBuffer = obj.LinkBuffer(end-keep+1:end);
                    end
                    break;
                end
                
                % 找到了 ASM (取第一个)
                first_asm = asm_idx(1);
                
                % 丢弃 ASM 之前的垃圾数据
                if first_asm > 1
                    obj.LinkBuffer(1:first_asm-1) = [];
                    % 更新: ASM 现在在位置 1
                end
                
                % 尝试提取帧 (滑动 CRC)
                payload_start = 25; % ASM(24) 之后
                search_limit = length(obj.LinkBuffer);
                
                frame_extracted = false;
                
                % 最小帧长 (32 CRC + 8 Data)
                % 步长 8 (字节对齐)
                for len = 40 : 8 : (search_limit - payload_start + 1)
                    segment = obj.LinkBuffer(payload_start : payload_start + len - 1);
                    
                    % 快速 CRC 校验
                    [isValid, cleanData] = CRC32_check(segment);
                    
                    if isValid
                        % 成功提取！
                        found_frames{end+1} = cleanData;
                        obj.FramesFound = obj.FramesFound + 1;
                        
                        % 从缓冲中移除这一整帧 (包括 ASM 和 CRC)
                        % 注意：这里直接移除 ASM+Frame+CRC
                        % 剩下的数据可能是 Idle，也可能是下一个 ASM
                        total_remove = 24 + len;
                        obj.LinkBuffer(1:total_remove) = [];
                        
                        frame_extracted = true;
                        break; 
                    end
                end
                
                if ~frame_extracted
                    % 找到了 ASM 但没找到匹配的 CRC
                    % 可能是假 ASM，或者数据还没传完(跨次了)
                    
                    % 如果缓冲区非常长(例如超过2个LDPC块)还没找到CRC，说明是假 ASM，丢弃它
                    if length(obj.LinkBuffer) > 2048*2 
                        obj.LinkBuffer(1:24) = []; 
                    else
                        break; % 等待更多数据
                    end
                end
            end
        end
        
        function seq = generate_pn_seq(obj, len)
            % PN 生成器 (同 ldpc_decoder)
            registers = true(1, 8); 
            seq = false(1, len);
            for k = 1:len
                out_bit = registers(8);
                seq(k) = out_bit;
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