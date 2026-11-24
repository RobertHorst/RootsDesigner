function results = RootsProfileScript(nodes, ex, offset, rotor_H, shellgap, ssOrShellD, points, units, mode, doPlot)
%ROOTSPROFILESCRIPT  Octave script/function version of RootsProfileApp.
%   Computes a Roots blower rotor profile and reports the same metrics as
%   the App Designer "Results" panel (shaft spacing, lobe geometry, area
%   efficiency, lambda, min/avg mesh gap, max angle deviation before
%   interference, and flow), then plots the six-angle rotor mesh figure.
%
%   RESULTS = ROOTSPROFILESCRIPT() runs with the app's default parameters.
%
%   RESULTS = ROOTSPROFILESCRIPT(NODES, EX, OFFSET, ROTOR_H, SHELLGAP, ...
%       SSORSHELLD, POINTS, UNITS, MODE, DOPLOT)
%
%   MODE     — 'ss' (default): SSORSHELLD is the shaft spacing (mm).
%              'sd': SSORSHELLD is the target shell diameter (mm); shaft
%                    spacing is solved for via fzero, as in the app's
%                    "Set Shell Diameter" mode.
%   UNITS    — 'CMM' (default), 'CMH', or 'CFM' — flow units at 1000 RPM.
%   DOPLOT   — true (default) to draw the six-angle mesh figure.
%
%   Copyright 2026, Robert Horst, Horst Tech LLC

    if nargin < 1  || isempty(nodes);      nodes      = 3;      end
    if nargin < 2  || isempty(ex);         ex         = 0.245;  end
    if nargin < 3  || isempty(offset);     offset     = 2.72;   end
    if nargin < 4  || isempty(rotor_H);    rotor_H    = 100;    end
    if nargin < 5  || isempty(shellgap);   shellgap   = 2;      end
    if nargin < 6  || isempty(ssOrShellD); ssOrShellD = 80.4;   end
    if nargin < 7  || isempty(points);     points     = 1001;   end
    if nargin < 8  || isempty(units);      units      = 'CMM';  end
    if nargin < 9  || isempty(mode);       mode       = 'ss';   end
    if nargin < 10 || isempty(doPlot);     doPlot     = true;   end

    if strcmpi(mode, 'sd')
        shell_d_target = ssOrShellD;
        target_rmax = shell_d_target/2 - shellgap;
        if target_rmax <= 0
            error('RootsProfileScript:shellTooSmall', ...
                'Shell diameter too small for shell gap.');
        end
        f = @(ss_val) lobeRmaxFromSS(nodes, ex, offset, ss_val, points) - target_rmax;
        ss_lo = max(2*offset + 1, 5);
        ss_hi = shell_d_target * 2;
        ss = fzero(f, [ss_lo, ss_hi]);
    else
        ss = ssOrShellD;
    end

    [lr,lrn,lw,sd,ae,cl,cn,mg,ag,lb,mad,xy,~] = ...
        rootsCompute(nodes, ex, offset, rotor_H, shellgap, ss, points);

    fl = flowConvertLocal(cl, units);
    fn = flowConvertLocal(cn, units);

    % --- console report, matching the App's Results panel --------------
    printf('%-16s %10.2f mm\n',  'Shaft Spacing',   ss);
    printf('%-16s %10.1f mm\n',  'Lobe Rmax',       lr);
    printf('%-16s %10.1f mm\n',  'Lobe Rmin',       lrn);
    printf('%-16s %10.1f mm\n',  'Lobe Width',      lw);
    printf('%-16s %10.1f mm\n',  'Shell Diameter',  sd);
    printf('%-16s %10.3f\n',     'Area Efficiency', ae);
    printf('%-16s %10.3f\n',     'Lambda',          lb);
    printf('%-16s %10.2f mm\n',  'Min Gap',         mg);
    printf('%-16s %10.2f mm\n',  'Avg Gap',         ag);
    printf('%-16s %10.3f deg\n', 'Max Angle Dev',   mad);
    printf('%-16s %10.2f %s\n',  'Flow Loss',       fl, units);
    printf('%-16s %10.2f %s\n',  'Flow Net',        fn, units);

    if doPlot
        plotProfilesLocal(xy, nodes, ss);
    end

    results = struct( ...
        'nodes', nodes, 'ex', ex, 'offset', offset, 'rotor_H', rotor_H, ...
        'shellgap', shellgap, 'points', points, 'units', units, ...
        'mode', mode, 'ss', ss, 'lobe_rmax', lr, 'lobe_rmin', lrn, ...
        'lobe_w', lw, 'shell_d', sd, 'area_eff', ae, 'lambda', lb, ...
        'min_gap', mg, 'avg_gap', ag, 'max_angle_dev_deg', mad, ...
        'flow_loss', fl, 'flow_net', fn, 'xy', xy);
end

% =========================================================================
%  LOCAL COMPUTATION FUNCTIONS
%  (ported 1:1 from RootsProfileApp.m — App Designer UI removed, math and
%  interference analysis unchanged)
% =========================================================================

function plotProfilesLocal(xy, nodes, ss)
    % Six-panel rotor mesh figure, matching the app's plotProfiles method.
    starta = 0;
    startb = 180 + 180/nodes;
    ang_delta = (180/nodes) / 5;

    figure('Name', 'Roots Profile — Rotor Mesh at 6 Angles');
    for idx = 1:6
        subplot(2,3,idx);
        ang = (idx-1) * ang_delta;
        r1 = rotateShiftLocal(xy, starta + ang, [-ss/2, 0]);
        r2 = rotateShiftLocal(xy, startb - ang, [ ss/2, 0]);

        plot(r1(:,1), r1(:,2), '-', 'Color', [0.15 0.35 0.70], 'LineWidth', 1.2);
        hold on;
        plot(r2(:,1), r2(:,2), '-', 'Color', [0.75 0.22 0.17], 'LineWidth', 1.2);
        hold off;

        axis equal;
        maxR = max(abs(xy(:))) + ss/2 + 10;
        xlim([-maxR maxR]);
        ylim([-maxR*0.70 maxR*0.70]);
        title(sprintf('%.1f deg', ang));
        grid on;
    end
end

function flow = flowConvertLocal(x, units)
    % Convert CFM to selected units
    if strcmpi(units, 'CMM')
        flow = x * 0.028316846592;
    elseif strcmpi(units, 'CMH')
        flow = x * 0.028316846592 * 60;
    else
        flow = x;   % already CFM
    end
end

function [x, y, rho] = pitchcurveLocal(ss, ex, nodes, theta)
    % Noncircular gear pitch curve with half-gap correction
    a   = ss / (1 + sqrt(1 - ex^2));
    cp  = a * (1 - ex^2);
    rho = cp / (1 - ex * cos(nodes * theta));
    other_theta = -theta + pi/nodes;
    other_rho   = cp / (1 - ex * cos(nodes * other_theta));
    pitch_gap   = ss - rho - other_rho;
    rho = rho + pitch_gap/2;
    x = rho .* cos(theta);
    y = rho .* sin(theta);
end

function rotated_points = rotateShiftLocal(points, angle_degrees, displacement)
    % Rotate Nx2 points by angle(s) in degrees, then translate
    N = size(points, 1);
    M = numel(angle_degrees);
    angle_radians = deg2rad(angle_degrees(:));
    cosA = cos(angle_radians);
    sinA = sin(angle_radians);
    R = zeros(2,2,M);
    R(1,1,:) = cosA;  R(1,2,:) = -sinA;
    R(2,1,:) = sinA;  R(2,2,:) =  cosA;
    rotated_points = zeros(N,2,M);
    for k = 1:M
        rotated_points(:,:,k) = (R(:,:,k) * points')' + displacement;
    end
end

function [min_gap, avg_gap, gaparray, ang_at_min] = findMinGapLocal(xyarray, nodes, ss)
    % Sweep 360 degree positions and find minimum/average clearance
    starta = 0;
    startb = 180 + 180/nodes;
    min_gap    = inf;
    ang_at_min = 0;
    gap_accum  = 0;
    gaparray   = zeros(360, 2);

    for i = 1:360
        ang = i - 1;
        rotor1 = rotateShiftLocal(xyarray, starta + ang, [-ss/2, 0]);
        rotor2 = rotateShiftLocal(xyarray, startb - ang, [ ss/2, 0]);

        in = inpolygon(rotor2(:,1), rotor2(:,2), ...
                       rotor1(:,1), rotor1(:,2));

        dx = rotor1(:,1) - rotor2(:,1).';
        dy = rotor1(:,2) - rotor2(:,2).';
        dist_matrix = sqrt(dx.^2 + dy.^2);
        dist_matrix(:, in) = -dist_matrix(:, in);

        current_min = min(dist_matrix(:));
        if current_min < min_gap
            min_gap = current_min;
            ang_at_min = ang;
        end
        gaparray(i,:) = [i, current_min];
        gap_accum = gap_accum + current_min;
    end
    avg_gap = gap_accum / 360;
end

function gap = pairGapLocal(xyarray, theta1, theta2, ss)
    % Clearance (signed: negative = overlap) between rotor1 held at theta1
    % and rotor2 held at theta2, using the same distance/overlap test as
    % findMinGapLocal.
    rotor1 = rotateShiftLocal(xyarray, theta1, [-ss/2, 0]);
    rotor2 = rotateShiftLocal(xyarray, theta2, [ ss/2, 0]);

    in = inpolygon(rotor2(:,1), rotor2(:,2), rotor1(:,1), rotor1(:,2));

    dx = rotor1(:,1) - rotor2(:,1).';
    dy = rotor1(:,2) - rotor2(:,2).';
    dist_matrix = sqrt(dx.^2 + dy.^2);
    dist_matrix(:, in) = -dist_matrix(:, in);

    gap = min(dist_matrix(:));
end

function dev = crossingAngleLocal(xyarray, theta1, theta2_0, ss, dir, max_search)
    % Bisection for the smallest deviation angle (0..max_search) by which
    % rotor2 can be turned away from theta2_0, with rotor1 held fixed at
    % theta1, before the gap first reaches zero (interference).
    tol = 1e-3;
    lo = 0;
    hi = max_search;
    gap_hi = pairGapLocal(xyarray, theta1, theta2_0 + dir*hi, ss);
    if gap_hi > 0
        % No interference within a half lobe pitch of deviation.
        dev = max_search;
        return;
    end
    while (hi - lo) > tol
        mid = (lo + hi) / 2;
        if pairGapLocal(xyarray, theta1, theta2_0 + dir*mid, ss) > 0
            lo = mid;
        else
            hi = mid;
        end
    end
    dev = (lo + hi) / 2;
end

function max_dev = findMaxAngleDeviationLocal(xyarray, nodes, ss, ang)
    % At the given synchronized-sweep rotation angle, hold rotor1 fixed and
    % find the smallest single-rotor rotation deviation of rotor2 — in
    % either direction — that closes the gap to zero. This is the angular
    % play (e.g. timing-gear backlash or torsional deflection) the
    % mechanism can tolerate at this position before the rotors interfere.
    starta = 0;
    startb = 180 + 180/nodes;
    theta1   = starta + ang;
    theta2_0 = startb - ang;

    max_search = 180 / nodes;      % one half lobe pitch
    dev_pos = crossingAngleLocal(xyarray, theta1, theta2_0, ss, +1, max_search);
    dev_neg = crossingAngleLocal(xyarray, theta1, theta2_0, ss, -1, max_search);
    max_dev = min(dev_pos, dev_neg);
end

function ang_refined = refineMinGapAngleLocal(xyarray, nodes, ss, ang_coarse)
    % Golden-section refine of the 1-degree-resolution minimum-gap angle
    % found by findMinGapLocal, searching the synchronized sweep motion
    % (both rotors turning together) in a +/-1 degree window.
    starta = 0;
    startb = 180 + 180/nodes;
    f = @(a) pairGapLocal(xyarray, starta + a, startb - a, ss);
    ang_refined = fminbnd(f, ang_coarse - 1, ang_coarse + 1);
end

function [lobe_rmax, lobe_rmin, lobe_w, shell_d, area_eff, ...
          CFM_loss, CFM_net, min_gap, avg_gap, lamb, max_angle_dev, xy, gear_xy] = ...
          rootsCompute(nodes, ex, offset, rotor_H, shellgap, ss, points)
    % Core Roots profile computation (no plotting).
    % Returns geometry, efficiency, flow and profile arrays.

    a = ss / (1 + sqrt(1 - ex^2));

    % --- Circumference & rolling-circle radius (full gap correction) ----
    num_pts = 10000;
    theta = linspace(0, 2*pi, num_pts);
    cp  = a * (1 - ex^2);
    rho = cp ./ (1 - ex * cos(nodes * theta));
    other_theta = -theta + pi/nodes;
    other_rho   = cp ./ (1 - ex * cos(nodes * other_theta));
    pitch_gap   = ss - rho - other_rho;
    rho = rho + pitch_gap;                          % full correction

    x = rho .* cos(theta);
    y = rho .* sin(theta);
    dx_c = diff(x);  dy_c = diff(y);
    circumference = sum(sqrt(dx_c.^2 + dy_c.^2));

    max_rho = max(rho);
    min_rho = min(rho);
    lamb = min_rho / max_rho;
    r = circumference / (4 * nodes * pi);           % rolling circle radius

    % --- Generate profile points ----------------------------------------
    xyarray0gap = zeros(points+1, 2);
    gear_xy     = zeros(points+1, 2);
    delta_th = (2*pi) / points;
    th = 0;

    for p = 1:points
        [gx, gy, ~] = pitchcurveLocal(ss, ex, nodes, th);
        gear_xy(p,:) = [gx, gy];

        span     = (points+1) / (nodes*2);
        halfspan = (points+1) / (nodes*4);
        dedend   = mod(floor((p + halfspan) / span), 2);

        [~, ~, rhoP] = pitchcurveLocal(ss, ex, nodes, th);

        if dedend == 0      % Addendum
            phi = th * (2*nodes + 1);
            Sx = (rhoP + r) * cos(th);
            Sy = (rhoP + r) * sin(th);
            Mx = Sx + r * cos(phi);
            My = Sy + r * sin(phi);
        else                % Dedendum
            phi = -th * (2*nodes - 1);
            Sx = (rhoP - r) * cos(th);
            Sy = (rhoP - r) * sin(th);
            Mx = Sx - r * cos(phi);
            My = Sy - r * sin(phi);
        end
        xyarray0gap(p,:) = [Mx, My];
        th = th + delta_th;
    end
    xyarray0gap(points+1,:) = xyarray0gap(1,:);
    gear_xy(points+1,:)     = gear_xy(1,:);

    % --- Offset shrink (offset is the input parameter) -----------------
    xyarray = zeros(points+1, 2);
    for p = 1:points
        prev = 1 + mod(p + points - 2, points);
        next = 1 + mod(p, points);
        ddx = xyarray0gap(next,1) - xyarray0gap(prev,1);
        ddy = xyarray0gap(next,2) - xyarray0gap(prev,2);
        thtan = atan2(ddy, ddx);
        xi = pi/2 + thtan;
        xyarray(p,1) = xyarray0gap(p,1) + offset * cos(xi);
        xyarray(p,2) = xyarray0gap(p,2) + offset * sin(xi);
    end
    xyarray(points+1,:) = xyarray(1,:);
    xy = xyarray;

    % --- Minimum lobe width --------------------------------------------
    lobe_w = 0;
    p = 2;
    while p <= points && xyarray(p,2) >= xyarray(p-1,2)
        p = p + 1;
    end
    if p <= points
        lobe_w = xyarray(p,2);
        p = p + 1;
    end
    while p <= points && xyarray(p,2) <= lobe_w
        lobe_w = xyarray(p,2);
        p = p + 1;
    end
    lobe_w = lobe_w * 2;

    lobe_rmax = max_rho + 2*r - offset;
    lobe_rmin = min_rho - 2*r - offset;

    % --- Area efficiency ------------------------------------------------
    shell_area = pi * lobe_rmax^2;
    rotor_area = polyarea(xyarray(:,1), xyarray(:,2));
    air_area   = shell_area - rotor_area;
    area_eff   = air_area / shell_area;
    shell_d    = 2 * (lobe_rmax + shellgap);

    % --- Volume & flow at 1000 RPM (CFM) -------------------------------
    vol_mm3   = air_area * rotor_H;
    vol_in3   = vol_mm3 / (25.4^3);
    vol_cuft  = 2 * vol_in3 / (12^3);              % 2x for both rotors

    [min_gap, avg_gap, ~, ang_at_min] = findMinGapLocal(xyarray, nodes, ss);

    % --- Max angle deviation before interference at the tightest gap ---
    ang_refined    = refineMinGapAngleLocal(xyarray, nodes, ss, ang_at_min);
    max_angle_dev  = findMaxAngleDeviationLocal(xyarray, nodes, ss, ang_refined);

    gap_area      = avg_gap * 2 * pi * ((lobe_rmax + lobe_rmin) / 2);
    vol_loss_mm3  = gap_area * rotor_H;
    vol_loss_in3  = vol_loss_mm3 / (25.4^3);
    vol_loss_cuft = vol_loss_in3 / (12^3);

    CFM_max  = vol_cuft * 1000;
    CFM_loss = vol_loss_cuft * 1000;
    CFM_net  = CFM_max - CFM_loss;
end

function lobe_rmax = lobeRmaxFromSS(nodes, ex, offset, ss, points)
    % Lightweight computation of lobe_rmax for a given ss.
    % Used by fzero solver in RootsProfileScript (no gap analysis).
    a = ss / (1 + sqrt(1 - ex^2));

    num_pts = 10000;
    theta = linspace(0, 2*pi, num_pts);
    cp  = a * (1 - ex^2);
    rho = cp ./ (1 - ex * cos(nodes * theta));
    other_theta = -theta + pi/nodes;
    other_rho   = cp ./ (1 - ex * cos(nodes * other_theta));
    pitch_gap   = ss - rho - other_rho;
    rho = rho + pitch_gap;              % full correction

    x = rho .* cos(theta);
    y = rho .* sin(theta);
    circumference = sum(sqrt(diff(x).^2 + diff(y).^2));

    max_rho = max(rho);
    r = circumference / (4 * nodes * pi);
    lobe_rmax = max_rho + 2*r - offset;
end
