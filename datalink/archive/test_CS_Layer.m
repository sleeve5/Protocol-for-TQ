%% Proximity-1 全流程闭环仿真测试 (Tx -> Channel -> Rx)
% 功能：验证从数据链路层到物理层再回到数据链路层的完整通信过程
% 核心验证点：LDPC 纠错能力 + CRC 帧完整性校验

clc; clear; close all;

% =========================================================================
% 1. 环境初始化
% =========================================================================
% 获取当前脚本所在路径，并递归添加子文件夹 (libs, data, utils)
current_path = fileparts(mfilename('fullpath'));
if isempty(current_path), current_path = pwd; end
addpath(genpath(current_path));

fprintf('=======================================================\n');
fprintf('    Proximity-1 协议C&S子层仿真\n');
fprintf('=======================================================\n');
% fprintf('[System] 项目根目录: %s\n', current_path);

% =========================================================================
% 2. 发射端 (Transmitter)
% =========================================================================
fprintf('\n[1] 发射端: 生成数据帧与编码...\n');

% --- A. 构造测试数据 (Transfer Frames) ---
% 生成 3 个不同长度的随机帧，模拟变长帧传输
% 注意: 长度建议为 8 的倍数 (字节对齐)，否则发射机会打印补零警告
frames_tx = {};
frames_tx{1} = randi([0 1], 1, 160) > 0.5;  % 短帧 (20 bytes)
frames_tx{2} = randi([0 1], 1, 800) > 0.5;  % 中帧 (100 bytes)
frames_tx{3} = randi([0 1], 1, 2040) > 0.5; % 长帧 (255 bytes)
frames_tx{4} = randi([0 1], 1, 1600) > 0.5; % 长帧 (255 bytes)
frames_tx{5} = randi([0 1], 1, 240) > 0.5; % 长帧 (255 bytes)
frames_tx{6} = randi([0 1], 1, 80) > 0.5; % 长帧 (255 bytes)

fprintf('    生成 %d 个测试帧，长度分别为: %d, %d, %d, %d, %d, %dbits\n', ...
    length(frames_tx), length(frames_tx{1}), length(frames_tx{2}), length(frames_tx{3}), length(frames_tx{4}), length(frames_tx{5}), length(frames_tx{6}));

% --- B. 发射参数配置 ---
sim_params.CodingType = 2;        % 2 = LDPC (C2, Rate 1/2)
sim_params.AcqSeqLen  = 128;      % 捕获序列长度
sim_params.TailSeqLen = 128;      % 尾序列长度
sim_params.InterFrameGap = 64;    % 帧间隙

% --- C. 执行发射处理 ---
try
    % 调用发射主函数 (返回物理层比特流)
    tx_bits = scs_transmitter(frames_tx, sim_params);
    fprintf('    [Tx Success] 发射比特流生成完毕，物理层总长度: %d bits\n', length(tx_bits));
catch ME
    error('发射机运行失败: %s', ME.message);
end

% =========================================================================
% 3. 信道模拟 (Channel)
% =========================================================================
fprintf('\n[2] 信道: BPSK 调制与 AWGN 噪声...\n');

% --- A. 设置信噪比 (Eb/N0) ---
% Proximity-1 LDPC (Rate 1/2) 理论门限极低。
% 设置 4.0 dB 以确保无误码；若设置 1.5 dB 可能会看到丢帧。
EbN0_dB = 1.5; 
code_rate = 1/2; 

% --- B. 计算噪声参数 ---
% Es/N0 = Eb/N0 + 10*log10(Rate)
EsN0_dB = EbN0_dB + 10*log10(code_rate);
snr_linear = 10^(EsN0_dB/10);
% 对于实数 BPSK，噪声方差 sigma^2 = 1 / (2*SNR)
noise_var = 1 / (2 * snr_linear); 
sigma = sqrt(noise_var);

% --- C. 调制与加噪 ---
% BPSK 映射: 0 -> +1, 1 -> -1
tx_signal = 1 - 2 * double(tx_bits); 

% 锁定随机种子以便复现
rng(123); 
noise = sigma * randn(size(tx_signal));
rx_signal = tx_signal + noise;

fprintf('    设置 Eb/N0: %.2f dB\n', EbN0_dB);
fprintf('    计算噪声 Sigma: %.4f\n', sigma);

% --- D. 软信息计算 (LLR) ---
% LLR = 2 * y / sigma^2 (正值代表0，负值代表1)
rx_llr = (2 * rx_signal) / (sigma^2);

% =========================================================================
% 4. 接收端 (Receiver)
% =========================================================================
fprintf('\n[3] 接收端: 解码校验提取...\n');
% fprintf('    (步骤包含: CSM同步 -> LDPC译码 -> ASM同步 -> 滑动CRC校验 -> 提取)\n');

try
    % 调用接收主函数
    % 返回值应该是通过了 CRC 校验的帧列表 (Cell Array)
    frames_rx = receiver(rx_llr, sim_params);
    
    num_rx = length(frames_rx);
    if num_rx == 0
        warning('接收端未能恢复出任何有效数据帧 (可能是信噪比过低或同步失败)。');
    else
        fprintf('    [Rx Success] 接收处理完成，成功提取并校验通过 %d 个帧。\n', num_rx);
    end
catch ME
    disp(ME.stack(1));
    error('接收机运行失败: %s', ME.message);
end

% =========================================================================
% 5. 最终验证 (Final Verification)
% =========================================================================
fprintf('\n[4] 数据完整性对比...\n');

if isempty(frames_rx)
    fprintf('FAILURE: 链路中断，无数据输出。\n');
    return;
end

% 统计变量
pass_count = 0;
total_sent = length(frames_tx);
total_rcvd = length(frames_rx);

min_len = min(total_sent, total_rcvd);

for i = 1:min_len
    tx_f = frames_tx{i};
    rx_f = frames_rx{i};
    
    % 检查长度和内容
    if isequal(tx_f, rx_f)
        fprintf('    [Pass] Frame #%d: 内容完全一致 (长度 %d bits)\n', i, length(rx_f));
        pass_count = pass_count + 1;
    else
        fprintf('    [Fail] Frame #%d: 内容不匹配!\n', i);
        % 调试信息
        fprintf('           发送长度: %d, 接收长度: %d\n', length(tx_f), length(rx_f));
        diff_bits = sum(tx_f ~= rx_f(1:min(end, length(tx_f))));
        fprintf('           误码数: %d\n', diff_bits);
    end
end

if total_rcvd < total_sent
    fprintf('    [Warn] 丢失了 %d 个帧 (发送 %d, 接收 %d)\n', ...
        total_sent - total_rcvd, total_sent, total_rcvd);
elseif total_rcvd > total_sent
    fprintf('    [Warn] 接收到了额外的帧 (可能是噪声被误判为帧，极罕见)\n');
end

fprintf('\n-------------------------------------------------------\n');
if pass_count == total_sent
    % fprintf('✅ 测试结论: SUCCESS - 所有数据帧均完美恢复！\n');
else
    fprintf('❌ 测试结论: FAILURE - 存在丢帧或误码。\n');
end
fprintf('-------------------------------------------------------\n');