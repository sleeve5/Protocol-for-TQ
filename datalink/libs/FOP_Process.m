% classdef FOP_Process < handle
%     % FOP_Process 发送端帧操作过程 (FOP-P)
%     % 对应标准: CCSDS 211.0-B-6 Section 7.2
%     % 功能：
%     %   1. 维护 V(S) 发送序列号
%     %   2. 缓存已发出的帧 (Sent Queue) 以备重传
%     %   3. 处理接收到的 PLCW，清除已确认的帧
%     %   4. 决定下一个动作：发新帧 / 重传
% 
%     properties
%         % --- 状态变量 (Section 7.2.2) ---
%         V_S         % Value of Next Sequence Controlled Frame to be Sent
%         NN_R        % Acknowledged Sequence Number (来自 PLCW)
% 
%         % --- 队列 ---
%         % 这里简化：SentQueue 存储结构体 {FrameBits, SeqNo}
%         Sent_Queue  
% 
%         % --- 控制 ---
%         Resending   % 标志位：是否处于重传模式
%         Resend_Idx  % 重传指针 (指向 Queue 中的索引)
% 
%         % --- 配置 ---
%         PCID
%     end
% 
%     methods
%         function obj = FOP_Process(pcid)
%             obj.PCID = pcid;
%             obj.reset();
%         end
% 
%         function reset(obj)
%             obj.V_S = 0;
%             obj.NN_R = 0;
%             obj.Sent_Queue = {};
%             obj.Resending = false;
%             obj.Resend_Idx = 1;
%         end
% 
%         % =================================================================
%         % 动作 1: 准备发送一个新帧 (上层调用)
%         % =================================================================
%         function [frame_to_send, seq_assigned] = prepare_frame(obj, payload, frame_gen_func)
%             % 输入: payload (数据), frame_gen_func (frame_generator函数句柄)
%             % 输出: 封装好 Header 的完整帧
% 
%             % 1. 如果处于重传模式，优先重传！
%             if obj.Resending
%                 if obj.Resend_Idx <= length(obj.Sent_Queue)
%                     fprintf('[FOP] 正在重传 SentQueue 索引 %d (Seq %d)...\n', ...
%                         obj.Resend_Idx, obj.Sent_Queue{obj.Resend_Idx}.SeqNo);
% 
%                     frame_to_send = obj.Sent_Queue{obj.Resend_Idx}.FrameBits;
%                     seq_assigned = obj.Sent_Queue{obj.Resend_Idx}.SeqNo;
% 
%                     obj.Resend_Idx = obj.Resend_Idx + 1;
% 
%                     % 如果重传完了队列，退出重传模式
%                     if obj.Resend_Idx > length(obj.Sent_Queue)
%                         obj.Resending = false;
%                     end
%                     return;
%                 else
%                     obj.Resending = false;
%                 end
%             end
% 
%             % 2. 发送新帧 (Normal Mode)
%             seq_assigned = obj.V_S;
% 
%             % 构造 Header 配置
%             cfg.SCID = 100; % 示例
%             cfg.PCID = obj.PCID;
%             cfg.PortID = 0;
%             cfg.SourceDest = 0; % Source
%             cfg.SeqNo = seq_assigned;
%             cfg.QoS = 0;       % Sequence Controlled
%             cfg.PDU_Type = 0;  % User Data
% 
%             % 生成帧
%             frame_bits = frame_gen_func(payload, cfg);
% 
%             % 3. 存入 Sent Queue (备份以备重传)
%             entry.FrameBits = frame_bits;
%             entry.SeqNo = seq_assigned;
%             obj.Sent_Queue{end+1} = entry;
% 
%             % 4. 更新 V(S)
%             obj.V_S = mod(obj.V_S + 1, 256);
% 
%             frame_to_send = frame_bits;
%         end
% 
%         % =================================================================
%         % 动作 2: 处理接收到的 PLCW (ACK/NACK)
%         % =================================================================
%         function process_PLCW(obj, plcw_bits)
%             % 解析 PLCW (16 bits)
%             % 假设 plcw_bits 是 logical 向量
% 
%             % 提取字段 (参考 build_PLCW)
%             retx_flag = plcw_bits(3);
%             % Report Value (N(R)) 在最后 8 位
%             report_val = bi2de(plcw_bits(9:16), 'left-msb');
% 
%             N_R = report_val;
% 
%             % 1. 确认帧 (ACK Processing)
%             % 如果 N(R) > NN(R)，说明接收方收到了新数据
%             % 注意：因为是模256，计算差值要小心
%             diff = mod(N_R - obj.NN_R, 256);
% 
%             if diff > 0
%                 fprintf('[FOP] 收到 ACK: N(R)=%d. 确认了 %d 个帧。\n', N_R, diff);
% 
%                 % 从队列头部移除 diff 个帧
%                 if diff <= length(obj.Sent_Queue)
%                     obj.Sent_Queue(1:diff) = [];
%                 else
%                     warning('FOP: ACK 确认数超过队列长度，可能逻辑异常');
%                     obj.Sent_Queue = {};
%                 end
% 
%                 % 更新 NN(R)
%                 obj.NN_R = N_R;
%             end
% 
%             % 2. 重传请求 (NACK Processing)
%             if retx_flag
%                 fprintf('[FOP] 收到重传请求 (Retransmit Flag=1)!\n');
%                 fprintf('[FOP] Go-Back-N: 从 Seq %d 开始重传 %d 个帧。\n', ...
%                     obj.NN_R, length(obj.Sent_Queue));
% 
%                 % 触发重传模式
%                 obj.Resending = true;
%                 obj.Resend_Idx = 1; % 重置指针，从队列头(最早未确认的)开始
%             end
%         end
%     end
% end

classdef FOP_Process < handle
    % FOP_Process 发送端帧操作过程 (FOP-P) - Fixed v2
    % 修复: process_PLCW 中删除队列元素时，同步回退 Resend_Idx 指针
    
    properties
        V_S         % 下一个要发送的新序列号
        NN_R        % 接收端已确认的序列号
        Sent_Queue  % 已发送帧缓存 (用于重传)
        
        Resending   % 状态: 是否重传中
        Resend_Idx  % 指针: 当前重传到队列的第几个
        
        PCID
    end
    
    methods
        function obj = FOP_Process(pcid)
            obj.PCID = pcid;
            obj.reset();
        end
        
        function reset(obj)
            obj.V_S = 0;
            obj.NN_R = 0;
            obj.Sent_Queue = {};
            obj.Resending = false;
            obj.Resend_Idx = 1;
        end
        
        % =================================================================
        % 1. 准备发送 (上层调用)
        % =================================================================
        function [frame_to_send, seq_assigned] = prepare_frame(obj, payload, frame_gen_func)
            frame_to_send = [];
            seq_assigned = -1;
            
            % --- A. 重传模式优先 ---
            if obj.Resending
                % 检查指针是否越界
                if obj.Resend_Idx <= length(obj.Sent_Queue)
                    % 取出旧帧重传
                    item = obj.Sent_Queue{obj.Resend_Idx};
                    frame_to_send = item.FrameBits;
                    seq_assigned = item.SeqNo;
                    
                    % 指针后移
                    obj.Resend_Idx = obj.Resend_Idx + 1;
                    return;
                else
                    % 队列里的都重传完了，退出重传模式
                    obj.Resending = false;
                    % 继续往下走，看是否发新数据
                end
            end
            
            % --- B. 发送新数据 ---
            if ~isempty(payload)
                seq_assigned = obj.V_S;
                
                % 配置帧头
                cfg.SCID = 100; % 默认示例
                cfg.PCID = obj.PCID;
                cfg.PortID = 0;
                cfg.SourceDest = 0;
                cfg.SeqNo = seq_assigned;
                cfg.QoS = 0;       
                cfg.PDU_Type = 0;  
                
                % 生成
                frame_bits = frame_gen_func(payload, cfg);
                
                % 存入队列
                entry.FrameBits = frame_bits;
                entry.SeqNo = seq_assigned;
                obj.Sent_Queue{end+1} = entry;
                
                % 更新 V(S)
                obj.V_S = mod(obj.V_S + 1, 256);
                
                frame_to_send = frame_bits;
            end
        end
        
        % =================================================================
        % 2. 处理 ACK/NACK (接收端反馈)
        % =================================================================
        function process_PLCW(obj, plcw_bits)
            % 解析 PLCW
            retx_flag = plcw_bits(3);
            N_R = bi2de(plcw_bits(9:16), 'left-msb');
            
            % --- A. 处理确认 (ACK) ---
            % 计算确认了多少个帧 (模256差值)
            diff = mod(N_R - obj.NN_R, 256);
            
            if diff > 0
                % fprintf('[FOP Debug] ACK 确认 %d 帧 (QueueLen: %d -> %d)\n', ...
                %     diff, length(obj.Sent_Queue), length(obj.Sent_Queue)-diff);
                
                if diff <= length(obj.Sent_Queue)
                    % 移除已确认的帧
                    obj.Sent_Queue(1:diff) = [];
                    
                    % [关键修复] 如果正在重传，指针也必须回退！
                    % 比如指针指在第2个，现在第1个被删了，那原来的第2个就变成了第1个
                    if obj.Resending
                        obj.Resend_Idx = max(1, obj.Resend_Idx - diff);
                    end
                else
                    % 异常情况：ACK 了还没发的帧？重置
                    warning('FOP: ACK 越界，重置队列');
                    obj.Sent_Queue = {};
                    obj.Resend_Idx = 1;
                end
                
                obj.NN_R = N_R;
            end
            
            % --- B. 处理重传请求 (NACK) ---
            if retx_flag
                % 收到 NACK，必须立即重置指针，从队列头开始重传
                obj.Resending = true;
                obj.Resend_Idx = 1; 
            end
        end
    end
end