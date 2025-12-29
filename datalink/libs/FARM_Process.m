classdef FARM_Process < handle
    % FARM_Process 接收端帧接收与报告机制 (FARM-P)
    % 对应标准: CCSDS 211.0-B-6 Section 7.3
    
    properties
        % 状态变量 (Section 7.3.2)
        V_R         % Receiver Frame Sequence Number (期望的下一个序号)
        Exp_Counter % Expedited Frame Counter
        Retransmit_Flag % R(S) 是否需要重传
        
        % 配置
        PCID        % 绑定的物理信道
    end
    
    methods
        function obj = FARM_Process(pcid)
            obj.PCID = pcid;
            obj.reset();
        end
        
        function reset(obj)
            obj.V_R = 0;
            obj.Exp_Counter = 0;
            obj.Retransmit_Flag = false;
        end
        
        % 核心处理函数：输入解析后的帧头，输出处理结果
        function [accept, plcw_req] = process_frame(obj, frame_header)
            % accept: 是否接收该帧数据
            % plcw_req: 是否需要立即发送 PLCW (通常都需要)
            
            accept = false;
            plcw_req = true; % 收到 Sequence Controlled 帧通常触发 PLCW
            
            % 1. 检查 PCID 是否匹配
            if frame_header.PCID ~= obj.PCID
                % 不是发给我的，忽略
                return; 
            end
            
            % 2. 区分 QoS 类型
            if frame_header.QoS == 1 
                % --- Expedited Service (加速帧) ---
                % 不检查序列号，直接接收
                obj.Exp_Counter = mod(obj.Exp_Counter + 1, 8);
                accept = true;
                % 加速帧不强制改变 ARQ 状态，但可能触发 PLCW 更新计数
                
            else 
                % --- Sequence Controlled Service (序列控制帧) ---
                N_S = frame_header.SeqNo; % 发送来的序号
                
                % 计算差值 (Modulo 256)
                diff = mod(N_S - obj.V_R, 256);
                
                if diff == 0
                    % [情况 A]: 序号匹配 (In-Sequence)
                    % 接收成功，窗口滑动
                    accept = true;
                    obj.V_R = mod(obj.V_R + 1, 256);
                    obj.Retransmit_Flag = false; % 清除重传标志
                    
                elseif diff < 128
                    % [情况 B]: 序号跳变 (Gap Detected / 丢帧)
                    % 比如期望 5，来了 7。说明 5,6 丢了。
                    % 拒绝接收 7，并要求重传
                    accept = false;
                    obj.Retransmit_Flag = true;
                    fprintf('[FARM] 检测到丢帧! 期望 %d, 收到 %d. 请求重传.\n', obj.V_R, N_S);
                    
                else
                    % [情况 C]: 序号重复 (Duplicate / 迟到)
                    % 比如期望 5，来了 3。说明 ACK 丢了，发送端重发了旧数据。
                    % 拒绝接收（去重），但回送 ACK 告诉它"我已经到5了"
                    accept = false;
                    % Retransmit_Flag 保持不变或置否? 标准 RE6: 丢弃帧，不改变 R(S)
                    fprintf('[FARM] 检测到重复帧 %d. 丢弃.\n', N_S);
                end
            end
        end
        
        % 获取当前的 PLCW 比特
        function bits = get_PLCW(obj)
            state.V_R = obj.V_R;
            state.Exp_Counter = obj.Exp_Counter;
            state.PCID = obj.PCID;
            state.Retransmit = obj.Retransmit_Flag;
            
            bits = build_PLCW(state);
        end
    end
end