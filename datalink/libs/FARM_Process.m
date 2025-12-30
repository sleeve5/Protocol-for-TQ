classdef FARM_Process < handle
    % FARM_Process 接收端帧接收与报告机制 (Strict Standard Version)
    % 严格遵循: CCSDS 211.0-B-6 Section 7.3.1 (FARM-P State Table)
    
    properties
        % --- 内部变量 (7.3.2) ---
        V_R             % 期望的下一个序列号 (0-255)
        Exp_Counter     % 加速帧计数器 (0-7)
        Retransmit_Flag % R(S): 是否请求重传
        
        % --- 配置 ---
        PCID            % 绑定的物理信道
    end
    
    methods
        function obj = FARM_Process(pcid)
            obj.PCID = pcid;
            obj.reset();
        end
        
        % 对应事件 RE0: Initialization
        function reset(obj)
            obj.V_R = 0;
            obj.Exp_Counter = 0;
            obj.Retransmit_Flag = false; % R(S) = false
        end
        
        % =================================================================
        % 核心处理函数: process_frame
        % 输入: frame_header (结构体)
        % 输出: 
        %   accept:   是否将数据上交给 I/O 子层
        %   plcw_req: 是否置位 NEED_PLCW (触发发送 ACK)
        % =================================================================
        function [accept, plcw_req] = process_frame(obj, frame_header)
            
            accept = false;
            plcw_req = false; % 默认不触发，除非标准明确要求
            
            % 0. 校验 PCID (隐式条件)
            if frame_header.PCID ~= obj.PCID
                return; % 忽略非本信道帧
            end
            
            % --- 特殊处理: SET V(R) 指令 (Event RE2) ---
            % 这一步通常需要在外部解析 P-Frame 后调用 obj.force_set_vr(val)
            % 但如果 P-Frame 传进来，我们需要在这里识别
            if frame_header.PDU_Type == 1
                % P-Frame 包含指令。
                % 注意：标准规定 P-Frame 也是通过 Expedited 服务传输的
                % 具体的指令解析应在 MAC 层或 Directive Decoder 完成
                % 这里我们仅处理作为 "Valid Expedited Frame" (Event RE3) 的部分
            end

            % =============================================================
            % 1. 加速服务 (Expedited Service) -> Event RE3
            % =============================================================
            if frame_header.QoS == 1 
                % 动作: Accept, Increment EXP Counter
                accept = true;
                obj.Exp_Counter = mod(obj.Exp_Counter + 1, 8);
                
                % 标准 RE3 中并未要求 设置 NEED_PLCW = true
                plcw_req = false; 
                
            % =============================================================
            % 2. 序列控制服务 (Sequence Controlled Service)
            % =============================================================
            else 
                N_S = frame_header.SeqNo;
                diff = mod(N_S - obj.V_R, 256);
                
                if diff == 0
                    % --- Event RE4: Sequence Frame 'in-sequence' ---
                    % 条件: N(S) == V(R)
                    % 动作: Accept, R(S)=false, Inc V(R), NEED_PLCW=true
                    accept = true;
                    obj.Retransmit_Flag = false;
                    obj.V_R = mod(obj.V_R + 1, 256);
                    plcw_req = true; % 必须发送 ACK
                    
                elseif diff < 128
                    % --- Event RE5: Sequence Frame 'gap detected' ---
                    % 条件: N(S) > V(R) (在窗口内)
                    % 动作: Discard, R(S)=true, NEED_PLCW=true
                    accept = false;
                    obj.Retransmit_Flag = true;
                    plcw_req = true; % 必须发送 NACK
                    
                    fprintf('[FARM Strict] 丢包: 期望 %d, 收到 %d. 触发重传请求.\n', obj.V_R, N_S);
                    
                else
                    % --- Event RE6: Sequence Frame 'already received' ---
                    % 条件: N(S) < V(R) (即重复帧)
                    % 动作: Discard
                    % [注意] 标准在此处没有要求 NEED_PLCW = true！
                    % 意味着接收机保持沉默，等待发送方超时查询或下一帧到来
                    accept = false;
                    plcw_req = false; % 严格遵循标准: 不立即回 ACK
                    
                    fprintf('[FARM Strict] 重复帧: %d. 丢弃 (保持沉默).\n', N_S);
                end
            end
        end
        
        % =================================================================
        % [新增] Event RE2: Valid 'SET V(R)' directive arrives
        % 该函数应由 MAC 层解析指令后调用
        % =================================================================
        function execute_set_vr(obj, new_vr_value)
            % 动作: R(S)=false, Set V(R), NEED_PLCW=true
            obj.Retransmit_Flag = false;
            obj.V_R = new_vr_value;
            
            % 这里虽然函数不能直接返回 plcw_req，但应当通知 MAC 层
            fprintf('[FARM Strict] 执行 SET V(R) -> %d. 状态重置.\n', new_vr_value);
        end
        
        % =================================================================
        % 辅助: 获取 PLCW 数据
        % =================================================================
        function bits = get_PLCW(obj)
            state.V_R = obj.V_R;
            state.Exp_Counter = obj.Exp_Counter;
            state.PCID = obj.PCID;
            state.Retransmit = obj.Retransmit_Flag;
            bits = build_PLCW(state);
        end
    end
end