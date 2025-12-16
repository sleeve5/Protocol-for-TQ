% --------------------------
% 光电检测器（PD）函数
% 功能：对远端与本地载波信号进行混频处理，输出基带信号及功率谱
% 输入参数：
%   remote_signal  - 远端信号
%   local_signal   - 本地信号
%   params         - 结构体参数，必须包含：
%       .fs           - 系统采样率 (Hz)，用于功率谱计算
%
% 输出参数：
%   signal_mix     - PD输出信号（混频后取实部，即基带信号）
% --------------------------

function signal_mix = PD(remote_signal, local_signal, params)

signal_mix = real(remote_signal.*conj(local_signal));
fs = params.fs;

% figure;
% [pxx1, f1] = pwelch(signal_mix(10000:end), 2048, 512, 2048, fs);
% plot(f1, 10*log10(pxx1/max(pxx1)), 'b');
% 
% xlabel('频率 (Hz)'); ylabel('幅度 (dB)');
% title('经过PD的信号功率谱密度');

end

