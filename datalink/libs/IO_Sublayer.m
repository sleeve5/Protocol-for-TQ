classdef IO_Sublayer < handle
    % IO_Sublayer: 输入/输出子层
    % 场景适配：3卫星组网，长延迟环境
    
    properties
        % --- 发送队列 (按目标 SCID 分类) ---
        % 结构: Map 或 结构体数组，Key=Remote_SCID
        % Value.Expedited: 加速队列
        % Value.SeqCtrl:   序列控制队列
        Queues
        
        % --- 本地配置 ---
        Local_SCID
    end
    
    methods
        function obj = IO_Sublayer(local_scid)
            obj.Local_SCID = local_scid;
            obj.Queues = containers.Map('KeyType', 'double', 'ValueType', 'any');
        end
        
        % [Tx] 初始化针对某个目标卫星的队列
        function init_link(obj, remote_scid)
            if ~isKey(obj.Queues, remote_scid)
                q.Expedited = {};
                q.SeqCtrl = {};
                obj.Queues(remote_scid) = q;
            end
        end
        
        % [Tx] 上层应用发送数据 (User Data -> U-Frame Payload)
        function send_user_data(obj, payload, remote_scid, port_id, qos)
            if ~isKey(obj.Queues, remote_scid)
                error('IO: 未知的目标卫星 SCID %d，请先建立链接。', remote_scid);
            end
            
            % 封装 SDU
            sdu.Payload = payload;
            sdu.PortID = port_id;
            sdu.IsProtocol = false; % U-Frame
            sdu.RemoteSCID = remote_scid;
            
            q = obj.Queues(remote_scid);
            if qos == 1 % Expedited (加速服务)
                q.Expedited{end+1} = sdu;
            else % Sequence Controlled (可靠服务)
                q.SeqCtrl{end+1} = sdu;
            end
            obj.Queues(remote_scid) = q;
        end
        
        % [Tx] MAC 层发送指令 (Directive -> P-Frame Payload)
        function send_directive(obj, directive_bits, remote_scid)
            if ~isKey(obj.Queues, remote_scid)
                % 如果是 Hailing 阶段，可能还没建好队列，强制初始化
                obj.init_link(remote_scid);
            end
            
            spdu.Payload = directive_bits;
            spdu.PortID = 0; 
            spdu.IsProtocol = true; % P-Frame (PDU Type=1)
            spdu.RemoteSCID = remote_scid;
            
            % 指令总是放入加速队列
            q = obj.Queues(remote_scid);
            q.Expedited{end+1} = spdu;
            obj.Queues(remote_scid) = q;
        end
        
        % [Tx] 供 Frame Sublayer 提取数据 (多路复用)
        % Frame Sublayer 需要指定它当前服务的是哪个目标卫星
        function [sdu, has_data] = extract_next_sdu(obj, remote_scid)
            has_data = false;
            sdu = [];
            
            if ~isKey(obj.Queues, remote_scid), return; end
            
            q = obj.Queues(remote_scid);
            
            % 优先级策略: 
            % 1. 加速队列 (含指令) 优先
            if ~isempty(q.Expedited)
                sdu = q.Expedited{1};
                q.Expedited(1) = [];
                has_data = true;
            % 2. 序列控制队列
            elseif ~isempty(q.SeqCtrl)
                sdu = q.SeqCtrl{1};
                q.SeqCtrl(1) = [];
                has_data = true;
            end
            
            obj.Queues(remote_scid) = q;
        end
        
        % [Rx] 接收数据分发
        function receive_frame_data(obj, header, payload)
            % 检查 SCID (标准 4.1.2.2 c)
            % 这里的 header.SCID 是 Source SCID (发送方)
            src_scid = header.SCID;
            
            if header.PDU_Type == 1
                % P-Frame -> 转交给 MAC 层处理 (指令/报告)
                % 这里通常通过事件或回调通知 MAC
                notify_mac_layer(obj, src_scid, payload);
            else
                % U-Frame -> 投递到指定端口
                port = header.PortID;
                fprintf('[IO Rx] 收到来自 Sat-%d 的数据 (Port %d, Len %d)\n', ...
                    src_scid, port, length(payload));
            end
        end
        
        function notify_mac_layer(obj, src_scid, payload)
            % 实际工程中这里会触发 Event
            fprintf('[IO Rx] 收到来自 Sat-%d 的 MAC 指令，转交解析...\n', src_scid);
        end
    end
end