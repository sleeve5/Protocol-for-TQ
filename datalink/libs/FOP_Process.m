% classdef FOP_Process < handle
%     % FOP_Process 发送端帧操作过程 (FOP-P) - Fixed v2
%     % 修复: process_PLCW 中删除队列元素时，同步回退 Resend_Idx 指针
% 
%     properties
%         V_S         % 下一个要发送的新序列号
%         NN_R        % 接收端已确认的序列号
%         Sent_Queue  % 已发送帧缓存 (用于重传)
% 
%         Resending   % 状态: 是否重传中
%         Resend_Idx  % 指针: 当前重传到队列的第几个
% 
%         PCID
% 
%         Transmission_Window = 64; 
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
%         % 1. 准备发送 (上层调用)
%         % =================================================================
%         function [frame_to_send, seq_assigned] = prepare_frame(obj, payload, frame_gen_func)
%             frame_to_send = [];
%             seq_assigned = -1;
% 
%             % --- A. 重传模式优先 ---
%             if obj.Resending
%                 % 检查指针是否越界
%                 if obj.Resend_Idx <= length(obj.Sent_Queue)
%                     % 取出旧帧重传
%                     item = obj.Sent_Queue{obj.Resend_Idx};
%                     frame_to_send = item.FrameBits;
%                     seq_assigned = item.SeqNo;
% 
%                     % 指针后移
%                     obj.Resend_Idx = obj.Resend_Idx + 1;
%                     return;
%                 else
%                     % 队列里的都重传完了，退出重传模式
%                     obj.Resending = false;
%                     % 继续往下走，看是否发新数据
%                 end
%             end
% 
%             % --- B. 发送新数据 ---
%             if ~isempty(payload)
%                 % 正在飞行中的帧数 (Outstanding Frames)
%                 % 计算模 256 差值: (V(S) - NN(R)) mod 256
%                 frames_in_flight = mod(obj.V_S - obj.NN_R, 256);
% 
%                 if frames_in_flight >= obj.Transmission_Window
%                     % 窗口已满！禁止发送新帧，强制等待 ACK
%                     fprintf('[FOP Warning] 发送窗口已满 (%d/%d). 暂停发送新数据.\n', ...
%                         frames_in_flight, obj.Transmission_Window);
%                     return; % 返回空帧
%                 end
% 
%                 % [窗口未满，允许发送]
%                 seq_assigned = obj.V_S;
% 
%                 % 配置帧头
%                 cfg.SCID = 100; % 默认示例
%                 cfg.PCID = obj.PCID;
%                 cfg.PortID = 0;
%                 cfg.SourceDest = 0;
%                 cfg.SeqNo = seq_assigned;
%                 cfg.QoS = 0;       
%                 cfg.PDU_Type = 0;  
% 
%                 % 生成
%                 frame_bits = frame_gen_func(payload, cfg);
% 
%                 % 存入队列
%                 entry.FrameBits = frame_bits;
%                 entry.SeqNo = seq_assigned;
%                 obj.Sent_Queue{end+1} = entry;
% 
%                 % 更新 V(S)
%                 obj.V_S = mod(obj.V_S + 1, 256);
% 
%                 frame_to_send = frame_bits;
%             end
%         end
% 
%         % =================================================================
%         % 2. 处理 ACK/NACK (接收端反馈)
%         % =================================================================
%         function process_PLCW(obj, plcw_bits)
%             % 解析 PLCW
%             retx_flag = plcw_bits(3);
%             N_R = bi2de(plcw_bits(9:16), 'left-msb');
% 
%             % --- A. 处理确认 (ACK) ---
%             % 计算确认了多少个帧 (模256差值)
%             diff = mod(N_R - obj.NN_R, 256);
% 
%             if diff > 0
%                 % fprintf('[FOP Debug] ACK 确认 %d 帧 (QueueLen: %d -> %d)\n', ...
%                 %     diff, length(obj.Sent_Queue), length(obj.Sent_Queue)-diff);
% 
%                 if diff <= length(obj.Sent_Queue)
%                     % 移除已确认的帧
%                     obj.Sent_Queue(1:diff) = [];
% 
%                     % [关键修复] 如果正在重传，指针也必须回退！
%                     % 比如指针指在第2个，现在第1个被删了，那原来的第2个就变成了第1个
%                     if obj.Resending
%                         obj.Resend_Idx = max(1, obj.Resend_Idx - diff);
%                     end
%                 else
%                     % 异常情况：ACK 了还没发的帧？重置
%                     warning('FOP: ACK 越界，重置队列');
%                     obj.Sent_Queue = {};
%                     obj.Resend_Idx = 1;
%                 end
% 
%                 obj.NN_R = N_R;
%             end
% 
%             % --- B. 处理重传请求 (NACK) ---
%             if retx_flag
%                 % 收到 NACK，必须立即重置指针，从队列头开始重传
%                 obj.Resending = true;
%                 obj.Resend_Idx = 1; 
%             end
%         end
%     end
% end


classdef FOP_Process < handle
    % FOP_Process 发送端帧操作过程 (v3.0 - 支持超时重传)
    % 
    % 新增特性: SYNCH_TIMER
    % 作用: 防止由于 ACK 丢失导致的死锁。
    % 逻辑: 
    %   1. 只要 Sent_Queue 不为空，计时器就开始倒数。
    %   2. 收到有效 ACK，重置计时器。
    %   3. 倒数至 0 (超时)，触发自动重传。
    
    properties
        V_S         % 发送序列号
        NN_R        % 确认序列号
        Sent_Queue  % 发送队列
        
        Resending   % 重传状态
        Resend_Idx  % 重传指针
        
        PCID
        Transmission_Window = 64; 
        
        % --- [新增] 定时器相关 ---
        SYNCH_TIMER          % 当前倒计时数值 (0 表示停止)
        TIMEOUT_THRESHOLD    % 超时阈值 (单位: 仿真步数 Step)
    end
    
    methods
        function obj = FOP_Process(pcid)
            obj.PCID = pcid;
            % 默认超时设为 5 个仿真步长 (假设 RTT 约为 1-2 步)
            obj.TIMEOUT_THRESHOLD = 5; 
            obj.reset();
        end
        
        function reset(obj)
            obj.V_S = 0;
            obj.NN_R = 0;
            obj.Sent_Queue = {};
            obj.Resending = false;
            obj.Resend_Idx = 1;
            obj.SYNCH_TIMER = 0; % 0 = Inactive
        end
        
        % =================================================================
        % [新增] 时钟滴答 (外部循环每一步调用一次)
        % =================================================================
        function timeout_triggered = tick(obj)
            timeout_triggered = false;
            
            % 只有当队列里有未确认数据时，计时器才工作
            if ~isempty(obj.Sent_Queue)
                if obj.SYNCH_TIMER > 0
                    obj.SYNCH_TIMER = obj.SYNCH_TIMER - 1;
                    
                    if obj.SYNCH_TIMER == 0
                        % --- 触发超时 ---
                        fprintf('[FOP Alert] ⚠️ SYNCH_TIMER 超时！未收到 ACK。\n');
                        fprintf('[FOP Action] 假定 ACK 丢失，强制启动重传 (Go-Back-N)。\n');
                        
                        % 动作：强制进入重传模式
                        obj.Resending = true;
                        obj.Resend_Idx = 1; 
                        
                        % 重置计时器，给重传一些时间
                        obj.SYNCH_TIMER = obj.TIMEOUT_THRESHOLD;
                        timeout_triggered = true;
                    end
                else
                    % 队列不为空但计时器为0？说明刚发了数据，启动计时
                    % (或者复位后重新启动)
                    obj.SYNCH_TIMER = obj.TIMEOUT_THRESHOLD;
                end
            else
                % 队列为空，停止计时
                obj.SYNCH_TIMER = 0;
            end
        end
        
        % =================================================================
        % 1. 准备发送
        % =================================================================
        function [frame_to_send, seq_assigned] = prepare_frame(obj, payload, frame_gen_func)
            frame_to_send = [];
            seq_assigned = -1;
            
            % A. 重传模式
            if obj.Resending
                if obj.Resend_Idx <= length(obj.Sent_Queue)
                    item = obj.Sent_Queue{obj.Resend_Idx};
                    frame_to_send = item.FrameBits;
                    seq_assigned = item.SeqNo;
                    obj.Resend_Idx = obj.Resend_Idx + 1;
                    
                    % [计时器逻辑] 重传也算发送，保持计时器运行
                    if obj.SYNCH_TIMER == 0, obj.SYNCH_TIMER = obj.TIMEOUT_THRESHOLD; end
                    return;
                else
                    obj.Resending = false;
                end
            end
            
            % B. 新数据模式
            if ~isempty(payload)
                frames_in_flight = mod(obj.V_S - obj.NN_R, 256);
                if frames_in_flight >= obj.Transmission_Window
                    return; % 窗口满
                end
                
                seq_assigned = obj.V_S;
                
                % 构造帧
                cfg.SCID = 100; cfg.PCID = obj.PCID; cfg.PortID = 0; 
                cfg.SourceDest = 0; cfg.SeqNo = seq_assigned; 
                cfg.QoS = 0; cfg.PDU_Type = 0;  
                
                frame_bits = frame_gen_func(payload, cfg);
                
                % 入队
                entry.FrameBits = frame_bits;
                entry.SeqNo = seq_assigned;
                obj.Sent_Queue{end+1} = entry;
                
                obj.V_S = mod(obj.V_S + 1, 256);
                frame_to_send = frame_bits;
                
                % [计时器逻辑] 发送了新数据，如果计时器没跑，启动它
                if obj.SYNCH_TIMER == 0
                    obj.SYNCH_TIMER = obj.TIMEOUT_THRESHOLD;
                end
            end
        end
        
        % =================================================================
        % 2. 处理 ACK/NACK
        % =================================================================
        function process_PLCW(obj, plcw_bits)
            if isempty(plcw_bits), return; end % 空输入保护
            
            retx_flag = plcw_bits(3);
            N_R = bi2de(plcw_bits(9:16), 'left-msb');
            
            % A. ACK 处理
            diff = mod(N_R - obj.NN_R, 256);
            if diff > 0
                if diff <= length(obj.Sent_Queue)
                    obj.Sent_Queue(1:diff) = [];
                    if obj.Resending
                        obj.Resend_Idx = max(1, obj.Resend_Idx - diff);
                    end
                    
                    % [计时器逻辑] 收到有效 ACK，重置计时器 (喂狗)
                    % 如果队列还有数据，重置为最大值；如果空了，归零。
                    if ~isempty(obj.Sent_Queue)
                        obj.SYNCH_TIMER = obj.TIMEOUT_THRESHOLD;
                    else
                        obj.SYNCH_TIMER = 0;
                    end
                else
                    obj.Sent_Queue = {};
                    obj.Resend_Idx = 1;
                end
                obj.NN_R = N_R;
            end
            
            % B. NACK 处理
            if retx_flag
                obj.Resending = true;
                obj.Resend_Idx = 1; 
                % 收到 NACK 也算一种响应，重置计时器防止双重触发
                obj.SYNCH_TIMER = obj.TIMEOUT_THRESHOLD;
            end
        end
    end
end