function [positions, fps] = color_tracker(params, res_path, bSaveImage)

% [positions, fps] = color_tracker(params)

% parameters
padding = params.padding;
output_sigma_factor = params.output_sigma_factor;
sigma = params.sigma;
lambda = params.lambda;
learning_rate = params.learning_rate;
compression_learning_rate = params.compression_learning_rate;
non_compressed_features = params.non_compressed_features;
compressed_features = params.compressed_features;
num_compressed_dim = params.num_compressed_dim;

video_path = params.video_path;
% video_name = params.video_name;
img_files = params.img_files;
pos = floor(params.init_pos);
target_sz = floor(params.wsize);

% visualization = params.visualization;

num_frames = numel(img_files);

% load the normalized Color Name matrix
temp = load('w2crs');
w2c = temp.w2crs;

use_dimensionality_reduction = ~isempty(compressed_features);

% window size, taking padding into account
sz = floor(target_sz * (1 + padding));%搜索区域

% desired output (gaussian shaped), bandwidth proportional to target size
output_sigma = sqrt(prod(target_sz)) * output_sigma_factor;
[rs, cs] = ndgrid((1:sz(1)) - floor(sz(1)/2), (1:sz(2)) - floor(sz(2)/2));%中心点为(0,0)
y = exp(-0.5 / output_sigma^2 * (rs.^2 + cs.^2));%使用高斯函数标签
yf = single(fft2(y));%single-单精度数组

% store pre-computed cosine window
cos_window = single(hann(sz(1)) * hann(sz(2))');%汉宁窗

% to calculate precision
positions = zeros(numel(img_files), 4);

% initialize the projection matrix
projection_matrix = [];

% to calculate fps
time = 0;

for frame = 1:num_frames
    % load image
    im = imread([video_path img_files{frame}]);
    
    tic;
    
    if frame > 1
        % compute the compressed learnt appearance
        zp = feature_projection(z_npca, z_pca, projection_matrix, cos_window);
        
        % extract the feature map of the local image patch
        [xo_npca, xo_pca] = get_subwindow(im, pos, sz, non_compressed_features, compressed_features, w2c);
        
        % do the dimensionality reduction and windowing
        x = feature_projection(xo_npca, xo_pca, projection_matrix, cos_window);
        
        % calculate the response of the classifier
        kf = fft2(dense_gauss_kernel(sigma, x, zp));
        response = real(ifft2(alphaf_num .* kf ./ (alphaf_den + eps)));%这里加上eps解决Dudek数据集出现NAN情况。
        
        % target location is at the maximum response
        [row, col] = find(response == max(response(:)), 1);
        pos = pos - floor(sz/2) + [row, col];
    end
    
    % extract the feature map of the local image patch to train the classifer
    [xo_npca, xo_pca] = get_subwindow(im, pos, sz, non_compressed_features, compressed_features, w2c);
    
    if frame == 1
        % initialize the appearance
        z_npca = xo_npca;
        z_pca = xo_pca;
        
        % set number of compressed dimensions to maximum if too many
        num_compressed_dim = min(num_compressed_dim, size(xo_pca, 2));
    else
        % update the appearance
        z_npca = (1 - learning_rate) * z_npca + learning_rate * xo_npca;
        z_pca = (1 - learning_rate) * z_pca + learning_rate * xo_pca;
    end
    
    % if dimensionality reduction is used: update the projection matrix
    if use_dimensionality_reduction
        % compute the mean appearance
        data_mean = mean(z_pca, 1);
        
        % substract the mean from the appearance to get the data matrix
        data_matrix = bsxfun(@minus, z_pca, data_mean);%bsxfun - 对两个数组应用按元素运算,minus减去
        
        % calculate the covariance(协方差) matrix
        cov_matrix = 1/(prod(sz) - 1) * (data_matrix' * data_matrix);
        
        % calculate the principal components (pca_basis) and corresponding variances(主成分和相应的方差)
        if frame == 1
            [pca_basis, pca_variances, ~] = svd(cov_matrix);%[U,S,V] = svd(A) 执行矩阵 A 的奇异值分解，因此 A = U*S*V'，其中U-左奇异向量，以矩阵列形式返回
                                                            %S -奇异值，以对角矩阵形式返回，V-右奇异向量，以矩阵的列形式返回。
        else
            [pca_basis, pca_variances, ~] = svd((1 - compression_learning_rate) * old_cov_matrix + compression_learning_rate * cov_matrix);
        end
        
        % calculate the projection matrix(投影矩阵) as the first principal(第一主要)
        % components and extract their corresponding variances
        projection_matrix = pca_basis(:, 1:num_compressed_dim);%吴恩达的机器学习课程中讲到，需要由n维降到k维，就取左奇异矩阵的前k列
        projection_variances = pca_variances(1:num_compressed_dim, 1:num_compressed_dim);
        
        if frame == 1
            % initialize the old covariance matrix using the computed
            % projection matrix and variances
            %这里projection_matrix * projection_variances*projection_matrix'可以理解为将降为后的数据进行相乘回到图像数据形式，即A = U*S*V'，这里是A = U*S*U'。
            old_cov_matrix = projection_matrix * projection_variances * projection_matrix';
        else
            % update the old covariance matrix using the computed
            % projection matrix and variances
            old_cov_matrix = (1 - compression_learning_rate) * old_cov_matrix + compression_learning_rate * (projection_matrix * projection_variances * projection_matrix');
        end
    end
    
    % project the features of the new appearance example using the new
    % projection matrix
    x = feature_projection(xo_npca, xo_pca, projection_matrix, cos_window);
    
    % calculate the new classifier coefficients
    kf = fft2(dense_gauss_kernel(sigma, x));
    new_alphaf_num = yf .* kf;
    new_alphaf_den = kf .* (kf + lambda);
    
    if frame == 1
        % first frame, train with a single image
        alphaf_num = new_alphaf_num;
        alphaf_den = new_alphaf_den;
    else
        % subsequent frames, update the model
        alphaf_num = (1 - learning_rate) * alphaf_num + learning_rate * new_alphaf_num;
        alphaf_den = (1 - learning_rate) * alphaf_den + learning_rate * new_alphaf_den;
    end
    
    %save position
    positions(frame,:) = [pos target_sz];
    
    time = time + toc;
    
    %visualization
%     if visualization == 1
    if bSaveImage
        rect_position = [pos([2,1]) - target_sz([2,1])/2, target_sz([2,1])];
        if frame == 1  %first frame, create GUI
            figure('Name',['Tracker - ' video_path]);
            im_handle = imshow(uint8(im), 'Border','tight', 'InitialMag', 100 + 100 * (length(im) < 500));
            rect_handle = rectangle('Position',rect_position, 'EdgeColor','g');
            text_handle = text(10, 10, int2str(frame));
            set(text_handle, 'color', [0 1 1]);
        else
            try  %subsequent frames, update GUI
                set(im_handle, 'CData', im)
                set(rect_handle, 'Position', rect_position)
                set(text_handle, 'string', int2str(frame));
            catch
                return
            end
%         imwrite(frame2im(getframe(gcf)),[res_path num2str(frame) '.jpg']); 
        end
        
        drawnow
%         pause
    end
end

fps = num_frames/time;
