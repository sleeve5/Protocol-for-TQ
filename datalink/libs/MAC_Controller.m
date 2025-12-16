classdef MAC_Controller < handle
    % MAC_Controller: 介质访问控制子层
    % 场景适配：处理长延迟链路的建立 (Hailing)
    
    properties
        State           % 'INACTIVE', 'HAILING', 'DATA_SERVICES'
        Local_SCID
        Current_Remote_SCID % 当前正在通信的目标
        
        % MIB 参数 (基于 17万km 场景调整)
        % RTT ≈ 1.14s，为了稳健，超时建议设为 3-5秒
        Hail_Wait_Duration = 5;  % 秒
        Comm_Change_Wait   = 5;  % 秒
        
        % 子层引用
        IO_Layer
    end
    
    methods
        function obj = MAC_Controller(local_scid, io_layer)
            obj.Local_SCID = local_scid;
            obj.IO_Layer = io_layer;
            obj.State = 'INACTIVE';
        end
        
        % [Tx] 发起呼叫 (Hailing) - 建立会话
        function start_hailing(obj, remote_scid)
            obj.Current_Remote_SCID = remote_scid;
            obj.State = 'HAILING';
            
            fprintf('[MAC] 正在呼叫卫星 Sat-%d (预计 RTT > 1.2s)...\n', remote_scid);
            
            % 1. 构造 SET TRANSMITTER PARAMETERS 指令 (Annex B1.2)
            % 这里简化为比特流生成
            dir_tx = build_directive_set_tx_params();
            
            % 2. 构造 SET RECEIVER PARAMETERS 指令 (Annex B1.4)
            dir_rx = build_directive_set_rx_params();
            
            % 3. 打包进 SPDU (Type 1)
            spdu_bits = build_SPDU({dir_tx, dir_rx});
            
            % 4. 发送 (必须是 Expedited 队列)
            % 呼叫帧通常是 P-Frame
            obj.IO_Layer.send_directive(spdu_bits, remote_scid);
            
            fprintf('[MAC] Hailing P-Frame 已放入发送队列。\n');
            % 此处应启动定时器等待 Hail_Wait_Duration
        end
        
        % [Rx] 处理接收到的指令
        function process_received_spdu(obj, src_scid, spdu_payload)
            % 解析 SPDU
            % 这里简化逻辑：如果是 Hailing 请求，则回送应答
            
            fprintf('[MAC] 解析来自 Sat-%d 的 SPDU...\n', src_scid);
            
            if strcmp(obj.State, 'INACTIVE')
                % 收到呼叫，转入 Active
                fprintf('[MAC] 收到 Hailing 请求，接受会话。\n');
                obj.State = 'DATA_SERVICES';
                obj.Current_Remote_SCID = src_scid;
                
                % 发送应答 (Report 或 数据)
                % 标准中通常回送 Status Report 或 PLCW 确认
                % 这里简单回送一个 "Connection OK" 的指令
                % obj.IO_Layer.send_directive(..., src_scid);
            elseif strcmp(obj.State, 'HAILING') && src_scid == obj.Current_Remote_SCID
                % 收到呼叫应答
                fprintf('[MAC] 收到 Hailing 应答，链路建立成功！\n');
                obj.State = 'DATA_SERVICES';
            end
        end
    end
end