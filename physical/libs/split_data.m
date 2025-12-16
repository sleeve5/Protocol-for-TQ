function [num_groups, group_data] = split_data(original_data, group_size)
    data_len = length(original_data);
    num_groups = ceil(data_len / group_size);
    group_data = zeros(group_size, num_groups);
    
    for i = 1:num_groups
        start_idx = (i-1)*group_size + 1;
        end_idx = min(i*group_size, data_len);
        group_data(1:(end_idx-start_idx+1), i) = original_data(start_idx:end_idx);
    end
end
