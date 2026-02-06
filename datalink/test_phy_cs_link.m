%% Step 1: 物理与编码层链路测试 (含延迟与噪声)
% 目标: 验证接收机能否在长延迟(噪声填充)后正确锁定 CSM 并提取数据

clc; clear; close all;
clear functions; 
addpath(genpath(fileparts(mfilename('fullpath'))));

fprintf('=== [Step 1] 物理与编码层连通性测试 ===\n');

% 1. 配置
PHY_RATE = 100e3;
DISTANCE = 170000 * 1000; % 17万公里
DELAY_SEC = 0;

sim_params.CodingType = 1; 
sim_params.AcqSeqLen = 256; % 增加捕获序列长度
sim_params.TailSeqLen = 256;
sim_params.InterFrameGap = 64;

% 2. 生成一帧数据
payload = randi([0 1], 1, 800) > 0.5;
cfg.SCID = 10; cfg.PCID = 0; cfg.PortID = 0; 
cfg.SourceDest = 0; cfg.SeqNo = 0; cfg.QoS = 0; cfg.PDU_Type = 0;
tx_frame = frame_generator(payload, cfg);

% 3. 发射
[tx_bits, ~] = scs_transmitter_timing({tx_frame}, sim_params);
fprintf('发射长度: %d bits\n', length(tx_bits));

% 4. 信道 (含延迟噪声填充)
tx_sym = 1 - 2*double(tx_bits);
SNR_dB = 100; % 高信噪比，专注测同步逻辑
sigma = sqrt(1 / (2 * 10^((SNR_dB - 3)/10)));
rx_sym = tx_sym + sigma * randn(size(tx_sym));
rx_llr_pure = 2 * rx_sym / sigma^2;
% [关键修改]
% 在信道部分，手动增加尾部填充
padding_zeros = zeros(1, 200); % 200 个 0 (LLR)
rx_llr_pure = [rx_llr_pure, padding_zeros];

% [关键] 构造延迟噪声 (必须是高斯噪声，不能是0)
delay_bits = round(DELAY_SEC * PHY_RATE);
fprintf('模拟延迟: %.4f s (%d bits)\n', DELAY_SEC, delay_bits);

delay_noise = (2/sigma^2) * (sigma * randn(1, delay_bits));

rx_llr_total = rx_llr_pure;

% 5. 接收 (流式)
rx = Proximity1Receiver_timing();
chunk_size = 512;
n_chunks = ceil(length(rx_llr_total)/chunk_size);
frames_out = {};

fprintf('开始接收处理 (共 %d chunks)...\n', n_chunks);
for k = 1:n_chunks
    s = (k-1)*chunk_size+1; 
    e = min(k*chunk_size, length(rx_llr_total));
    [f, ~] = rx.step(rx_llr_total(s:e));
    if ~isempty(f), frames_out = [frames_out, f]; end
    flush_zeros = zeros(1, 100); 
    fprintf('Rx LLR Mean: %.4f, Max: %.4f, Min: %.4f\n', mean(rx_llr_total), max(rx_llr_total), min(rx_llr_total));
    [f_last, ~] = rx.step(flush_zeros);
    if ~isempty(f_last), frames_out = [frames_out, f_last]; end
end

% 6. 验证
if isempty(frames_out)
    fprintf('❌ 失败: 未提取到帧。\n');
    % [调试] 查看 LinkBuffer 前 64 位
    if length(rx.LinkBuffer) > 64
        disp('LinkBuffer Top 64 bits:');
        disp(rx.LinkBuffer(1:64)'); 
        
        % 检查是否是反相的 ASM (FAF320 -> 050CDF)
        % F(1111) -> 0(0000), A(1010) -> 5(0101)...
    else
        disp('LinkBuffer 为空或太短！');
    end
else
    [~, rx_payload] = frame_parser(frames_out{1});
    if isequal(rx_payload, payload)
        fprintf('✅ 成功: 在长延迟后正确提取数据！\n');
    else
        fprintf('❌ 失败: 数据内容不匹配。\n');
    end
end

% ... 接收循环结束 ...

% 6. 验证与深度调试
if isempty(frames_out)
    fprintf('❌ 失败: 未提取到帧。\n');
    
    % --- [新增] 深度调试 ---
    fprintf('\n=== 深度调试模式 ===\n');
    
    % 1. 获取发送端的真值 (Frame + CRC)
    [crc_val, ~] = CRC32(tx_frame);
    truth_data = [tx_frame, crc_val];
    
    % 2. 在 LinkBuffer 中寻找这段真值
    % Rx Buffer 可能包含 ASM，我们先搜 ASM
    asm_pattern = hex2bit_MSB('FAF320');
    
    % 将 LinkBuffer 转为 double
    link_buf = double(rx.LinkBuffer);
    
    % 暴力搜索 ASM
    asm_pos = strfind(link_buf, double(asm_pattern));
    
    if isempty(asm_pos)
        fprintf('Debug: LinkBuffer 中根本没找到 ASM！Viterbi 译码可能全错。\n');
        disp('LinkBuffer 前 100 位:');
        disp(link_buf(1:min(end,100)));
    else
        fprintf('Debug: 在 LinkBuffer 索引 %d 找到了 ASM。\n', asm_pos(1));
        
        % 提取 ASM 后的数据
        start_idx = asm_pos(1) + 24;
        len_needed = length(truth_data);
        
        if length(link_buf) >= start_idx + len_needed - 1
            rx_segment = link_buf(start_idx : start_idx + len_needed - 1);
            
            % 比对
            diffs = sum(rx_segment ~= double(truth_data));
            if diffs == 0
                fprintf('Debug: 数据完全匹配！(Diff=0)。\n');
                fprintf('       结论: 接收机的 CRC 校验函数可能有问题，或者滑动窗口步长跳过了这个位置。\n');
                
                % 手动调用 CRC 检查
                [isValid, ~] = CRC32_check(rx_segment);
                if isValid
                    fprintf('       手动调用 CRC32_check 返回 TRUE。奇怪...\n');
                else
                    fprintf('       手动调用 CRC32_check 返回 FALSE。CRC 校验器有问题。\n');
                end
            else
                fprintf('Debug: 数据不匹配！有 %d 个误码。\n', diffs);
                fprintf('Tx (前32): %s\n', num2str(double(truth_data(1:32))));
                fprintf('Rx (前32): %s\n', num2str(rx_segment(1:32)));
                
                % 看看是不是移位了？
                % 尝试前后移位对比...
            end
        else
            fprintf('Debug: 数据被截断。LinkBuffer 长度不足。\n');
        end
    end
else
    % ... 成功 ...

    disp("成功");
end
% 
% % 打印发送的完整帧 (包括 CRC)
% % 我们需要手动算一下带 CRC 的帧
% [crc_val, ~] = CRC32(tx_frame);
% tx_pltu_payload = [tx_frame, crc_val]; % 不含 ASM
% fprintf('[Debug] Tx Payload+CRC (First 32 bits): %s\n', ...
%     num2str(double(tx_pltu_payload(1:32))));
% 
% % 手动计算 Rx 数据的 CRC
% [~, calc_crc] = CRC32(rx_segment(1:end-32));
% recv_crc = rx_segment(end-31:end);
% if isequal(calc_crc, recv_crc)
%     disp('手动 CRC 校验通过！问题出在 CRC32_check 函数。');
% else
%     disp('手动 CRC 校验失败。数据确实错了。');
%     % 打印最后 64 位对比
%     disp('Tx Tail:'); disp(truth_data(end-63:end));
%     disp('Rx Tail:'); disp(rx_segment(end-63:end));
% end