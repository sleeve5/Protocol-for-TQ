%% Proximity-1 会话建立仿真 (Hailing) - 17万公里长延迟场景
% 场景: Alice (Sat-1) 主动呼叫 Bob (Sat-2)
% 流程: Inactive -> Alice发送Hail指令 -> 长延迟 -> Bob接收并应答 -> 长延迟 -> Alice收到 -> 链路建立

clc; clear; close all;
addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('=======================================================\n');
fprintf('    Proximity-1 长距离会话建立仿真 (Hailing)\n');
fprintf('    距离: 170,000 km | 单向光速延迟: ~0.57 sec\n');
fprintf('=======================================================\n');

%% 1. 初始化节点 (Alice & Bob)
% 定义 SCID
SCID_ALICE = 10;
SCID_BOB   = 20;

% --- Alice (Initiator) ---
io_alice  = IO_Sublayer(SCID_ALICE);
io_alice.init_link(SCID_BOB); % <--- Alice 知道要呼叫 Bob，初始化队列
fop_alice = FOP_Process(0);
mac_alice = MAC_Controller(true, io_alice, fop_alice); 

% --- Bob (Responder) ---
io_bob  = IO_Sublayer(SCID_BOB);
% [关键修正] Bob 也需要初始化通往 Alice 的链路，否则无法回复
io_bob.init_link(SCID_ALICE); % <--- 添加这一行！
fop_bob = FOP_Process(0);
mac_bob = MAC_Controller(false, io_bob, fop_bob);

% 建立连接引用 (为了让 IO 层能回调 MAC)
% 在实际代码中建议用 addlistener，这里简化处理，手动赋值句柄
% (假设你修改了 IO_Sublayer 增加了 mac_ref 属性，或者通过全局/上层调度)
% 这里我们通过主脚本调度来模拟回调

%% 2. 物理层与参数配置
% 距离参数
distance_km = 170000;
c = 3e8;
delay_sec = (distance_km * 1000) / c; 
fprintf('[System] 计算物理延迟: %.4f 秒\n', delay_sec);

% 仿真参数
sim_params.CodingType = 2; % LDPC
sim_params.AcqSeqLen  = 1024; % 长捕获序列
sim_params.TailSeqLen = 256;
sim_params.InterFrameGap = 64;

% 设置 MAC 超时 (必须 > 2 * delay_sec)
mac_alice.Hail_Wait_Duration = 3.0; % 设为 3秒，足够往返
fprintf('[Alice] Hail Wait Duration 设置为: %.1f 秒\n', mac_alice.Hail_Wait_Duration);

%% 3. 仿真开始：Alice 发起呼叫
fprintf('\n--- [Step 1] Alice 发起 Hailing ---\n');
mac_alice.start_hailing(SCID_BOB);

% 此时 Alice 的 IO 队列里应该有一条 Expedited P-Frame
[tx_frame_bits, type] = frame_multiplexer(io_alice, SCID_BOB);

if strcmp(type, 'P-Frame')
    fprintf('[Alice Tx] 成功生成 Hailing P-Frame (%d bits)\n', length(tx_frame_bits));
else
    error('Alice 未能生成呼叫帧！');
end

%% 4. 物理层传输 (Forward Link: Alice -> Bob)
fprintf('\n--- [Step 2] 正向链路传输 (Alice -> Bob) ---\n');

% 1. C&S 发送
tx_stream = scs_transmitter({tx_frame_bits}, sim_params);

% 2. 物理信道 (BPSK + AWGN + Delay)
fprintf('[Channel] 信号正在穿越 17万公里深空...\n');
tx_signal = 1 - 2*double(tx_stream);
% 模拟信噪比 (Hailing 时通常用低速率或高功率，假设链路较好)
rx_signal = awgn(tx_signal, 10, 'measured'); 
rx_llr = 2 * rx_signal; % 简化 LLR

% 3. 延迟模拟 (模拟时间流逝)
pause(0.5); % 这里的 pause 只是为了演示效果，实际仿真中是逻辑延迟
fprintf('[Timer] + %.4f sec (光速延迟)\n', delay_sec);

%% 5. Bob 接收与处理
fprintf('\n--- [Step 3] Bob 接收与处理 ---\n');

% 1. C&S 接收
% 注意：这里我们手动模拟 receiver 的 IO 回调
recovered_frames = receiver(rx_llr, sim_params, []); 

if isempty(recovered_frames)
    error('Bob 物理层解调失败！');
end

rx_bits = recovered_frames{1};
[header, payload] = frame_parser(rx_bits);

fprintf('[Bob Rx] 收到帧: SCID=%d, PDU_Type=%d\n', header.SCID, header.PDU_Type);

% 2. IO 层分发
if header.PDU_Type == 1
    % 3. MAC 层处理 (Bob 响应呼叫)
    % 模拟 Bob 的 MAC 收到通知
    fprintf('[Bob MAC] 识别到 SET TRANSMITTER PARAMETERS 指令。\n');
    mac_bob.process_received_spdu(header.SCID, payload);
    
    if strcmp(mac_bob.State, 'DATA_SERVICES')
        fprintf('[Bob] 状态变更为 DATA_SERVICES。准备发送应答。\n');
        
        % Bob 生成应答 (这里简单模拟发送一个 Status Report 或数据)
        % 实际协议应回复 PLCW 或 Status
        resp_payload = hex2bit_MSB('FFFF'); % 简单的应答数据
        io_bob.send_user_data(resp_payload, SCID_ALICE, 0, 1); % 发送 Expedited 应答
    end
end

%% 6. 反向链路传输 (Return Link: Bob -> Alice)
fprintf('\n--- [Step 4] 反向链路传输 (Bob -> Alice) ---\n');

% 1. Bob 生成应答帧
[resp_frame_bits, r_type] = frame_multiplexer(io_bob, SCID_ALICE);
fprintf('[Bob Tx] 生成应答帧 (%s)\n', r_type);

% 2. 物理传输
resp_stream = scs_transmitter({resp_frame_bits}, sim_params);
resp_signal = 1 - 2*double(resp_stream);
rx_resp_llr = 2 * awgn(resp_signal, 10, 'measured');

fprintf('[Channel] 信号正在返回 Earth (17万公里)...\n');
fprintf('[Timer] + %.4f sec\n', delay_sec);

%% 7. Alice 接收应答
fprintf('\n--- [Step 5] Alice 接收应答 ---\n');

alice_rx_frames = receiver(rx_resp_llr, sim_params, []);
if ~isempty(alice_rx_frames)
    [h_alice, p_alice] = frame_parser(alice_rx_frames{1});
    fprintf('[Alice Rx] 收到来自 SC-%d 的帧。\n', h_alice.SCID);
    
    % Alice MAC 确认连接
    if strcmp(mac_alice.State, 'HAILING')
        fprintf('[Alice MAC] 收到 Bob 的响应！\n');
        mac_alice.State = 'DATA_SERVICES';
        fprintf('[Alice] 状态变更为 DATA_SERVICES。\n');
    end
end

%% 8. 结论
fprintf('\n=======================================================\n');
if strcmp(mac_alice.State, 'DATA_SERVICES') && strcmp(mac_bob.State, 'DATA_SERVICES')
    fprintf('✅ SUCCESS: 深空链路会话建立成功！(RTT > 1s)\n');
else
    fprintf('❌ FAILED: 会话建立失败。\n');
end
fprintf('=======================================================\n');