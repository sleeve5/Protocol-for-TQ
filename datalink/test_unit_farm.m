%% FARM-P (接收端逻辑) 单元测试
clc; clear; close all;
addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('=== FARM-P 逻辑单元测试 ===\n');

% 初始化 FARM 进程 (监听 PCID=0)
farm = FARM_Process(0);
fprintf('[Init] V(R) = %d\n', farm.V_R);

%% 场景 1: 正常接收 (0 -> 1 -> 2)
fprintf('\n--- 场景 1: 正常顺序接收 ---\n');
seqs = [0, 1, 2];
for s = seqs
    header.SeqNo = s;
    header.PCID = 0;
    header.QoS = 0; % Sequence Controlled
    
    [accept, ~] = farm.process_frame(header);
    
    if accept
        fprintf('  Frame Seq %d: 接收成功 (V(R) 更新为 %d)\n', s, farm.V_R);
    else
        fprintf('  Frame Seq %d: 被拒绝\n', s);
    end
end

% 检查生成的 PLCW
plcw_bits = farm.get_PLCW();
% 简单解析打印 (这里简化，实际可用 parse_PLCW)
% Report Value (Last 8 bits)
report_val = bi2de(plcw_bits(9:16), 'left-msb');
retx_flag = plcw_bits(3);
fprintf('  [PLCW] Report V(R)=%d, Retransmit=%d (预期: 3, 0)\n', report_val, retx_flag);


%% 场景 2: 丢帧模拟 (期望 3, 来了 5)
fprintf('\n--- 场景 2: 丢帧模拟 (跳过 3, 4) ---\n');
header.SeqNo = 5;
[accept, ~] = farm.process_frame(header);

if ~accept
    fprintf('  Frame Seq 5: 被拒绝 (符合预期)\n');
else
    error('错误：Frame 5 应该被拒绝！');
end

% 检查 PLCW 是否请求重传
plcw_bits = farm.get_PLCW();
retx_flag = plcw_bits(3);
if retx_flag
    fprintf('  [PLCW] Retransmit Flag = 1 (成功触发重传请求)\n');
else
    error('错误：未触发重传标志！');
end


%% 场景 3: 重复帧模拟 (重发了旧的 2)
fprintf('\n--- 场景 3: 重复帧模拟 (收到旧帧 2) ---\n');
header.SeqNo = 2;
[accept, ~] = farm.process_frame(header);

if ~accept
    fprintf('  Frame Seq 2: 被丢弃 (符合预期，V(R)=%d 未变)\n', farm.V_R);
else
    error('错误：重复帧应该被丢弃！');
end