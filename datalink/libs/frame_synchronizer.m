% --------------------------
% 通用帧同步/相关器函数
% 功能：在接收流中搜索指定的同步标记（Marker），支持硬/软判决。
% 输入参数：
%   rx_stream - 数据流 (double, 0/1 或 LLR)
%   target_pattern - 想要搜索的目标序列 (logical 向量, 如 CSM 或 ASM)
%   threshold - 判决门限
% 输出参数：
%   indices - 匹配的起始位置
% --------------------------

function indices = frame_synchronizer(rx_stream, target_pattern, threshold)
    
    L = length(target_pattern);
    N = length(rx_stream);
    
    if N < L, indices = []; return; end
    
    % 确保输入格式
    rx_stream = double(rx_stream(:)');
    target_pattern = double(target_pattern(:)');

    % 自动判断模式
    is_soft = any(rx_stream < 0) || any(rx_stream > 1);
    
    if ~is_soft
        % --- 硬判决模式 (Hamming Distance) ---
        % 映射: 0->-1, 1->+1
        pat_bi = 2*target_pattern - 1;
        rx_bi  = 2*rx_stream - 1;
        
        % 相关计算
        corr = conv(rx_bi, flip(pat_bi), 'valid');
        
        % 转换回误码数
        errors = (L - corr) / 2;
        indices = find(abs(errors) <= threshold);
        
    else
        % --- 软判决模式 (LLR Correlation) ---
        % 映射: 0->+1, 1->-1 (适配 LLR)
        pat_sign = zeros(size(target_pattern));
        pat_sign(target_pattern==0) = 1;
        pat_sign(target_pattern==1) = -1;
        
        % 相关计算
        corr = conv(rx_stream, flip(pat_sign), 'valid');
        
        % 简单阈值判决
        indices = find(corr > threshold);
    end
end
