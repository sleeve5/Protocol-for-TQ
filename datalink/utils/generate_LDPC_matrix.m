% --------------------------
% LDPC校验矩阵生成函数
% 功能: 生成 CCSDS Proximity-1 (Rate 1/2, k=1024) C2 LDPC 校验矩阵
%       并保存到本地文件 './data/CCSDS_C2_matrix.mat'
% --------------------------

clear; clc;
fprintf('正在计算 CCSDS C2 LDPC (k=1024, Rate 1/2) 校验矩阵...\n');

% 1. 基础参数
k = 1024;
M = 512; % 子矩阵大小

% 2. 准备基础子矩阵
I = speye(M);           % 单位矩阵
Z = sparse(M, M);       % 全零矩阵

% 3. 生成置换矩阵 Pi_1 到 Pi_8
fprintf('  > 计算置换矩阵 Pi_1 到 Pi_8...\n');
Pi = cell(1, 8);
for k_idx = 1:8
    Pi{k_idx} = generate_permutation_matrix(k_idx, M);
end

% 4. 构建 H_1/2 矩阵
fprintf('  > 组装 H 矩阵块...\n');
% Row 1: [0, 0, I, 0, I (+) Pi_1]
H_blk{1,1} = Z; H_blk{1,2} = Z; H_blk{1,3} = I; H_blk{1,4} = Z;
H_blk{1,5} = mat_gf2_add(I, Pi{1}); 

% Row 2: [I, I, 0, I, Pi_2 (+) Pi_3 (+) Pi_4]
H_blk{2,1} = I; H_blk{2,2} = I; H_blk{2,3} = Z; H_blk{2,4} = I;
H_blk{2,5} = mat_gf2_add(mat_gf2_add(Pi{2}, Pi{3}), Pi{4});

% Row 3: [I, Pi_5 (+) Pi_6, 0, Pi_7 (+) Pi_8, I]
H_blk{3,1} = I;
H_blk{3,2} = mat_gf2_add(Pi{5}, Pi{6});
H_blk{3,3} = Z;
H_blk{3,4} = mat_gf2_add(Pi{7}, Pi{8});
H_blk{3,5} = I;

% 组合为稀疏矩阵
H = cell2mat(H_blk);

% 5. 定义打孔模式 (Puncturing Pattern) ---
% 编码器输出长度 = 5*M = 2560 bits
% 传输长度 = 2048 bits
% 规则: 最后 M (512) 位被丢弃
puncture_pattern = [true(1, 4*M), false(1, M)];

% 6. 保存到文件
current_dir = fileparts(mfilename('fullpath'));
data_dir = fullfile(current_dir, '..', 'data');
if ~exist(data_dir, 'dir')
        mkdir(data_dir);
end
save_path = fullfile(data_dir, 'CCSDS_C2_matrix.mat');
save(save_path, 'H', 'puncture_pattern');

fprintf('成功！矩阵 H (%dx%d) 和打孔模式已保存至 "%s"\n', ...
    size(H,1), size(H,2), save_path);

% 辅助函数
function C = mat_gf2_add(A, B)
    C = mod(A + B, 2);
    C = sparse(C);
end

function P = generate_permutation_matrix(k, M)
    % 数据提取自 CCSDS 131.0-B-5 Table 7-3 & 7-4
    % 针对 M=512 (对应 tuple 的第3个值)
    % k | theta | phi(0) | phi(1) | phi(2) | phi(3)
    table_data = [
        1, 3, 108, 0,   0,   0;
        2, 0, 126, 375, 219, 312;
        3, 1, 238, 74,  16,  503;
        4, 2, 32,  45,  263, 388;
        5, 2, 96,  47,  415, 185;
        6, 3, 28,  0,   403, 7;
        7, 0, 59,  59,  184, 185;
        8, 1, 63,  102, 279, 328
    ];

    row = table_data(k, :);
    theta = row(2);
    phi_vals = row(3:6); 
    
    pi_i = zeros(1, M);
    for i = 0 : M-1
        term1 = mod(theta + floor(4*i/M), 4);
        j = floor(4*i/M); 
        phi_val = phi_vals(j + 1);
        term2 = mod(phi_val + i, M/4);
        pi_i(i+1) = (M/4) * term1 + term2;
    end
    
    rows = 1:M;
    cols = pi_i + 1;
    vals = ones(1, M);
    P = sparse(rows, cols, vals, M, M);
end
