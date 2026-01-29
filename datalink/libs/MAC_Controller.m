classdef MAC_Controller < handle
    % MAC_Controller: 介质访问控制子层 (修正版)
    % 适配: 3参数构造函数 (IsCaller, IO, FOP)
    
    properties
        State           % 当前状态
        IsCaller        % true=主叫(Caller), false=被叫(Responder)
        
        % 关联子层
        IO_Layer
        FOP_Layer
        
        % 会话参数
        Current_Remote_SCID 
        Hail_Wait_Duration = 5.0; % 默认超时时间 (秒)

        % --- [新增] 定时业务缓冲区 ---
        % 每一行存储: [Time, SeqNo, QoS]
        SENT_TIME_BUFFER      % 记录 Egress 时间
        RECEIVE_TIME_BUFFER   % 记录 Ingress 时间

    end
    
    methods
        % =================================================================
        % 构造函数 (修正点: 接受 3 个参数)
        % =================================================================
        function obj = MAC_Controller(is_caller, io_layer, fop_layer)
            obj.IsCaller = is_caller;
            obj.IO_Layer = io_layer;
            obj.FOP_Layer = fop_layer;
            obj.State = 'INACTIVE';
            obj.SENT_TIME_BUFFER = [];
            obj.RECEIVE_TIME_BUFFER = [];
        end
        
        % =================================================================
        % [Tx] 发起呼叫 (Hailing)
        % =================================================================
        function start_hailing(obj, remote_scid)
            if ~obj.IsCaller
                warning('MAC: 只有 Caller 才能发起呼叫。');
                return;
            end
            
            obj.Current_Remote_SCID = remote_scid;
            obj.State = 'HAILING';
            
            fprintf('[MAC] 进入 HAILING 状态，正在呼叫 SC-%d...\n', remote_scid);
            
            % 1. 构造指令 (SET TRANSMITTER/RECEIVER PARAMETERS)
            % 这里调用辅助函数生成指令比特
            dir_tx = obj.build_dummy_directive(); 
            dir_rx = obj.build_dummy_directive();
            
            % 2. 打包进 SPDU (Type 1)
            % 需要确保 build_SPDU 在路径中
            spdu_bits = build_SPDU({dir_tx, dir_rx});
            
            % 3. 发送 (通过 IO 层)
            obj.IO_Layer.send_directive(spdu_bits, remote_scid);
        end

        % =================================================================
        % [新增] 定时业务接口
        % =================================================================
        
        % [标准] 5.2.1 记录 Egress Time (发送端调用)
        % 触发时机：当 ASM 的最后一位离开物理层时
        function capture_egress_time(obj, time_val, seq_no, qos)
            entry = struct();
            entry.Time = time_val;
            entry.SeqNo = seq_no;
            entry.QoS = qos;
            
            % 存入缓冲区
            obj.SENT_TIME_BUFFER = [obj.SENT_TIME_BUFFER; entry];
        end
        
        % [标准] 5.2.1 记录 Ingress Time (接收端调用)
        % 触发时机：当 ASM 的最后一位到达物理层并被识别时
        function capture_ingress_time(obj, time_val, seq_no, qos)
            entry = struct();
            entry.Time = time_val;
            entry.SeqNo = seq_no;
            entry.QoS = qos;
            
            % 存入缓冲区
            obj.RECEIVE_TIME_BUFFER = [obj.RECEIVE_TIME_BUFFER; entry];
        end
        
        % [辅助] 获取用于 Time Correlation 的数据对
        function logs = get_timing_logs(obj, direction)
            if strcmp(direction, 'Tx')
                logs = obj.SENT_TIME_BUFFER;
            else
                logs = obj.RECEIVE_TIME_BUFFER;
            end
        end
        
        % =================================================================
        % [Rx] 处理接收到的 SPDU (来自 IO 层的通知)
        % =================================================================
        function process_received_spdu(obj, src_scid, spdu_payload)
            % 简单状态机逻辑
            
            switch obj.State
                case 'INACTIVE'
                    % 如果是 Responder，收到数据意味着 Caller 在呼叫
                    if ~obj.IsCaller
                        fprintf('[MAC] 收到来自 SC-%d 的连接请求。\n', src_scid);
                        fprintf('[MAC] 状态迁移: INACTIVE -> DATA_SERVICES\n');
                        obj.State = 'DATA_SERVICES';
                        obj.Current_Remote_SCID = src_scid;
                        
                        % 实际协议中这里应该回送应答 (Reply)
                    end
                    
                case 'HAILING'
                    % 如果是 Caller，收到数据意味着 Responder 应答了
                    if obj.IsCaller && src_scid == obj.Current_Remote_SCID
                        fprintf('[MAC] 收到 SC-%d 的 Hailing 应答。\n', src_scid);
                        fprintf('[MAC] 状态迁移: HAILING -> DATA_SERVICES\n');
                        obj.State = 'DATA_SERVICES';
                    end
                    
                case 'DATA_SERVICES'
                    fprintf('[MAC] 会话中收到 SPDU，执行指令...\n');
            end
        end
        
        % 内部辅助: 生成一个占位指令 (全1) 用于测试
        function bits = build_dummy_directive(obj)
            bits = true(1, 16); % 16 bits dummy
        end
    end
end