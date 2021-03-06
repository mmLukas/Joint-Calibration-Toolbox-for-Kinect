function do_calib_online( imd_dataset, rgb_dataset, ...
    use_depth_kc, use_depth_distortion )

% Input
global rgb_grid_p rgb_grid_x
global depth_plane_mask
global calib0
% Output
global final_calib final_calib_error
global max_depth_sample_count

do_initial_rgb_calib2(false, rgb_dataset); % calculate homography of color camera
do_fixed_depth_calib(); % initialize all parameters related to depth camera

% ccount = length(rgb_grid_p);
% icount = length(imd_dataset);

%Get depth samples
fprintf('Extracting disparity samples...\n');
[depth_plane_points,depth_plane_disparity] = get_depth_samples2(imd_dataset, depth_plane_mask);
initial_count = sum(cellfun(@(x) size(x,2),depth_plane_points));
[depth_plane_points,depth_plane_disparity] = reduce_depth_samples(depth_plane_points,depth_plane_disparity,max_depth_sample_count);
total_count = sum(cellfun(@(x) size(x,2),depth_plane_points));
fprintf('Initial disparity samples: %d, using %d.\n',initial_count,total_count);

fprintf('-------------------\n');
fprintf('Joint RGB-Depth calibration\n');
fprintf('-------------------\n');

%Joint minimization
options = calibrate_kinect_options();
options.use_fixed_rK = false;
options.use_fixed_rkc = [false false false false false];
options.use_fixed_dK = false;
% options.use_fixed_dkc = [false false false false true];
options.use_fixed_dkc = [true true true true true];
options.use_fixed_dR = false;
options.use_fixed_dt = false;
options.use_fixed_pose = false;
options.display = 'iter';

% options for calibratig depth geometric distortion coefficients--dkc
options2 = calibrate_kinect_options();
options2.use_fixed_rK = true;
options2.use_fixed_rkc = true;
options2.use_fixed_dK = false;
options2.use_fixed_dkc = [false false false false true];
options2.use_fixed_dR = true;
options2.use_fixed_dt = true;
options2.use_fixed_pose = true;
options2.display = 'iter';

% Note: if we choose parameters from the original code, the depth values
% calculated from disparity calculated are around 1e-5, which leads to
% great cost betewen reprojected disparity points to measured ones.
% calib0.dc = [3.0938 -0.0028]; % recommended by 
calib0.dc = [3.3309495161 -0.0030711016]; % recommended by Herrera
% check wall images and fill in corresponding Rext amd Text
k = find(cellfun(@(x) isempty(x), rgb_grid_p{1}));
for i = 1 : length(k)
    [calib0.Rext{k(i)},calib0.text{k(i)}] = depth_extern_calib(calib0,depth_plane_points{k(i)},depth_plane_disparity{k(i)});
    %   disp(calib0.text{k(i)});
end

converged=false;
i=1;
calib_new = calib0;

%Fixed variances
use_fixed_vars = true;
fixed_color_var = [ 0.18     0.30].^2;
fixed_depth_var = 0.9^2;

%Cost
new_color_cost = calibrate_kinect_cost_color(calib_new,options,rgb_grid_p,rgb_grid_x);
new_color_cost_sum = cellfun(@(x) sum(x.^2), new_color_cost);
new_depth_cost = calibrate_kinect_cost_depth(calib_new,options,depth_plane_points,depth_plane_disparity);
new_depth_cost_sum = sum(new_depth_cost.^2);
fprintf('Initial cost: ');
for k=1:length(new_color_cost)
    fprintf('%.0fpx, ',new_color_cost_sum(k));
end
fprintf('%.0fkdu\n',new_depth_cost_sum);

while(~converged)
    fprintf('-------------------------\n');
    fprintf('Pass #%d\n',i);
    fprintf('-------------------------\n');
    calib_old = calib_new;
    old_color_cost_sum = new_color_cost_sum;
    old_depth_cost_sum = new_depth_cost_sum;
    
    old_var.color_error_var = calib_old.color_error_var;
    old_var.depth_error_var = calib_old.depth_error_var;
    if(use_fixed_vars)
        calib_old.color_error_var = fixed_color_var;
        calib_old.depth_error_var = fixed_depth_var;
    end
    
    %Calibrate general parameters
    %   if(use_depth_kc)
    %     %If we're optimizing the geometric distortion, fix the intrinsics to
    %     %speed up the general parameter refinement.
    %     if(any(calib_old.dkc))
    %       options.use_fixed_dK = true;
    %     else
    %       options.use_fixed_dK = false;
    %     end
    %   end
    fprintf('Pass #%d: Calibrating general parameters...\n', i);
    [calib_new,jacobian,cerror,derror]=calibrate_kinect(options,rgb_grid_p,rgb_grid_x,depth_plane_points,depth_plane_disparity,calib_old);
    
    %Calibrate depth distortion
    if(use_depth_distortion)
        %Calibrate distortion
        fprintf('Pass #%d: Calibrating depth distortion...\n', i);
        [calib_new.dc_alpha,calib_new.dc_beta]=calib_distortion2(calib_new, calib_new.Rext, calib_new.text, imd_dataset, depth_plane_mask);
        %       [calib_new.dc_woffset]=calib_distortion_woffset(calib_new,calib_new.Rext, calib_new.text, dfiles, depth_plane_mask);
    end
    
    %Calibrate depth geometric distortion
    if(use_depth_kc)
        fprintf('Pass #%d: Calibrating geometric distortion...\n', i);
%         calib_new.color_error_var = calib_old.color_error_var;
%         calib_new.depth_error_var = calib_old.depth_error_var;
        [calib_new,~,~,~]=calibrate_kinect(options2,rgb_grid_p,rgb_grid_x,depth_plane_points,depth_plane_disparity,calib_new);
    end
    
    %Calculate cost
    new_color_cost = calibrate_kinect_cost_color(calib_new,options,rgb_grid_p,rgb_grid_x);
    new_color_cost_sum = cellfun(@(x) sum(x.^2), new_color_cost);
    new_depth_cost = calibrate_kinect_cost_depth(calib_new,options,depth_plane_points,depth_plane_disparity);
    new_depth_cost_sum = sum(new_depth_cost.^2);
    fprintf('Pass #%d costs: ',i);
    for k=1:length(new_color_cost)
        fprintf('%.0fpx, ',new_color_cost_sum(k));
    end
    fprintf('%.0fkdu\n',new_depth_cost_sum);
    
    %Get variances
    calib_new.color_error_var = cellfun(@var,new_color_cost);
    calib_new.depth_error_var = var(new_depth_cost);
    
    fprintf('Pass #%d stats:\n',i);
    for k=1:length(new_color_cost)
        [sigma,sigma_lower,sigma_upper] = std_interval(new_color_cost{k},0.99);
        fprintf('Color %d: mean=%f, std=%f [-%f,+%f] (pixels)\n',k,mean(new_color_cost{k}),sigma,sigma_lower,sigma_upper);
    end
    [sigma,sigma_lower,sigma_upper] = std_interval(new_depth_cost,0.99);
    fprintf('Depth: mean=%f, std=%f [-%f,+%f] (disparity)\n',mean(new_depth_cost),sigma,sigma_lower,sigma_upper);
    
    if(~use_depth_distortion && ~use_depth_kc)
        converged = true;
    else
        converged = true;
        
        old_std = [old_var.color_error_var, old_var.depth_error_var].^0.5;
        new_std = [calib_new.color_error_var, calib_new.depth_error_var].^0.5;
        if(any( abs(old_std-new_std)./new_std >= 0.01 ) )
            fprintf('Error variance has changed, will iterate again.\n');
            converged = false;
        end
        
        old_cost = [old_color_cost_sum, old_depth_cost_sum];
        new_cost = [new_color_cost_sum, new_depth_cost_sum];
        if(any( abs(old_cost-new_cost)./new_cost >= 0.01 ))
            fprintf('Error residuals have changed, will iterate again.\n');
            converged = false;
        end
    end
    %   converged = true;
    i=i+1;
end

final_calib = calib_new;
final_calib_error = calibrate_kinect_tolerance(options,calib_new,jacobian,cerror,derror);

end

