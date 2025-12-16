function [tx_frame_bits, frame_type] = frame_multiplexer(io_layer, remote_scid)
% FRAME_MULTIPLEXER 发送端帧调度器
% 功能：从 IO 子层的不同队列中提取 SDU，并调用 frame_generator 封装成帧
% 优先级：Expedited (含MAC指令) > Sequence Controlled (用户数据)
%
% 输出:
%   tx_frame_bits: 封装好的帧比特流 (如果无数据则为空)
%   frame_type: 'P-Frame', 'U-Frame', or 'None'

    tx_frame_bits = [];
    frame_type = 'None';
    
    % 1. 尝试从 IO 层提取数据 (IO 层内部已处理优先级)
    [sdu, has_data] = io_layer.extract_next_sdu(remote_scid);
    
    if ~has_data
        return; % 无数据发送
    end
    
    % 2. 准备帧头配置
    % 注意：这里需要获取 FOP 的 V(S) 序列号，为了解耦，
    % 我们假设 IO 层传出来的 SDU 已经包含了必要的元数据，或者在这里补全
    
    cfg.SCID = io_layer.Local_SCID; % 源 SCID
    cfg.PCID = 0; % 默认物理信道 0
    cfg.PortID = sdu.PortID;
    cfg.SourceDest = 0; % 0=Source
    
    % 关键字段设置
    if sdu.IsProtocol
        % --- P-Frame (MAC 指令 / PLCW) ---
        cfg.PDU_Type = 1; 
        cfg.QoS = 1;       % 指令必须是 Expedited
        cfg.SeqNo = 0;     % P-Frame 通常不使用 SeqNo (或者使用 Expedited Seq)
        frame_type = 'P-Frame';
    else
        % --- U-Frame (用户数据) ---
        cfg.PDU_Type = 0;
        % 假设目前只演示 Sequence Controlled
        cfg.QoS = 0; 
        % 注意：真实的 SeqNo 应该来自 FOP 状态机
        % 这里为了简化集成，暂时用 0 或由 FOP 模块外部注入
        % 实际架构中 multiplexer 应该和 FOP 紧密配合
        cfg.SeqNo = 0; 
        frame_type = 'U-Frame';
    end
    
    % 3. 生成帧
    % 自动计算长度
    tx_frame_bits = frame_generator(sdu.Payload, cfg);
end