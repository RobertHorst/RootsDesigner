% App.m — MATLAB App Designer UI for Roots blower profile design
% Roots profiles based on a circle rolling inside and outside the pitch
% curve of identical noncircular gears.
% Copyright 2026, Robert Horst, Horst Tech LLC
%
% Usage:  RootsProfileApp
%
% Mode toggle (above tabs):
%   Set Shaft Spacing  — input ss, compute shell diameter
%   Set Shell Diameter — input shell_d, solve for shaft spacing 
%
% Settings (above tabs, used by both tabs):
%   Profile Method — Averaged (paper Eqs 5-6, default) or Noslip rolling
%   Units          — SI (flow CMM, velocity m/s) or Imperial (CFM, ft/min);
%                    dimensions are always entered in mm
%   Rotor Speed    — RPM used for flow and outlet velocity
%   Outlet Diameter — discharge opening (mm) for the mean outlet velocity
%
% Two tabs:
%   Interactive — adjust parameters, press Compute, view 6-angle profiles
%   Batch       — load/edit parameter table, Run All, click result row to plot


classdef RootsProfileApp < matlab.apps.AppBase
    properties (Constant)
        VERSION = "0.4.0"
        VERSION_DATE = "2026-11-20"
        NRES = 17                   % rows in the Results panel (incl. 3 headers)
        BATCH_BAD_COLS = [2 3 4 13 14 15]  % batch result columns zeroed on interference
        APP_NAME = "Roots Profile Designer"
        APP_VENDOR = "Horst Tech LLC"
    end
    % =====================================================================
    %  PROPERTIES
    % =====================================================================
    properties (Access = public)
        % --- Figure and layout ---
        UIFigure
        MainGrid
        LeftPanel               % grid holding mode toggle + tab group
        ModeRow                 % grid: mode toggle + Return to Defaults
        ModeButtonGroup
        ReturnDefaultsBtn
        SSRadioBtn
        SDRadioBtn
        SettingsPanel
        MethodDropDown
        InputDropDown           % design input: offset / min_gap / max_angle_dev
        UnitsDropDown
        RPMField
        OutletField
        LeftTabGroup
        InteractiveTab
        BatchTab

        % --- Interactive tab ---
        LobesSpinner
        ExField
        OffsetField             % holds offset, min gap or max angle dev
        OffsetLabel
        RotorHField
        ShellGapField
        SSField                 % holds ss or shell_d depending on mode
        SwitchLabel             % row-6 label that swaps text with mode
        PointsDropDown
        ComputeButton
        ExportSplineBtn
        StatusLabel
        ResultLabels            % NRESx2 cell of {nameLabel, valueLabel}
        BatchSettings           % settings used for the last batch run

        % --- Batch tab ---
        BatchInputTable
        BatchResultsTable
        LoadDefaultsBtn
        AddRowBtn
        DeleteRowBtn
        RunAllBtn
        ExportBatchBtn
        PlotMarkedBtn
        BatchStatusLabel

        % --- Plot panel ---
        PlotPanel
        PlotGrid
        Ax                      % 1x6 UIAxes array

        % --- Data cache ---
        LastXY
        LastNodes       double = 3
        LastSS          double = 80.4
        BatchXYCache    cell
        BatchNodeCache  double
        BatchSSCache    double
        SelectedInputRow double = 0
    end

    % =====================================================================
    %  PRIVATE METHODS — callbacks & helpers
    % =====================================================================
    methods (Access = private)

        % ---- Mark parameters as changed --------------------------------
        function paramChanged(app)
            app.StatusLabel.Text = 'Modified';
            app.StatusLabel.FontColor = [0.80 0.50 0.00];
        end

        % ---- Mode toggle callback --------------------------------------
        function modeChanged(app)
            isSD = app.SDRadioBtn.Value;
            if isSD
                app.SwitchLabel.Text = 'Shell Diameter (mm)';
                app.SSField.Limits = [1 Inf];
                app.SSField.Value = 130;
                app.BatchInputTable.ColumnName{7} = 'shell_d';
            else
                app.SwitchLabel.Text = 'Shaft Spacing (mm)';
                app.SSField.Limits = [1 Inf];
                app.SSField.Value = 80.4;
                app.BatchInputTable.ColumnName{7} = 'ss';
            end
            clearResults(app);
            % Clear batch data to avoid misinterpreting column 6
            app.BatchInputTable.Data = {};
            app.BatchResultsTable.Data = [];
            app.BatchXYCache = {};
            paramChanged(app);
        end

        % ---- Return to Defaults -----------------------------------------
        % Start-up state: Set Shell Diameter (130 mm), 1000 RPM, rotor
        % height 100 mm, Averaged method, default 3-lobe parameters.
        % The Units choice is kept.
        function applyDefaults(app)
            app.MethodDropDown.Value = 'averaged';
            app.InputDropDown.Value  = 'offset';
            inputKindChanged(app);
            app.RPMField.Value       = 1000;
            app.OutletField.Value    = 51;
            app.LobesSpinner.Value   = 3;
            app.ExField.Value        = 0.245;
            app.OffsetField.Value    = 2.72;
            app.RotorHField.Value    = 100;
            app.ShellGapField.Value  = 2;
            app.PointsDropDown.Value = '1001';
            app.SDRadioBtn.Value     = true;   % Set Shell Diameter mode
            modeChanged(app);                  % sets field to 130 mm, clears results
        end

        % ---- Design input changed (Offset / Min Gap / Max Angle Dev) ---
        function inputKindChanged(app)
            kind = app.InputDropDown.Value;
            [label, unit, def, lims, fmt] = inputKindInfoLocal(kind);
            app.OffsetLabel.Text = sprintf('%s (%s)', label, unit);
            app.OffsetField.Limits = lims;
            app.OffsetField.ValueDisplayFormat = fmt;
            app.OffsetField.Value = def;
            app.BatchInputTable.ColumnName{4} = kind;
            % Column 3 of the batch table changes meaning: clear batch data.
            app.BatchInputTable.Data = {};
            app.BatchResultsTable.Data = [];
            app.BatchXYCache = {};
            clearResults(app);
            paramChanged(app);
        end

        % ---- Results panel ---------------------------------------------
        function showResults(app, rows)
            for k = 1:RootsProfileApp.NRES
                nl = app.ResultLabels{k,1};
                vl = app.ResultLabels{k,2};
                vl.Text = rows{k,2};
                vl.FontSize = 12;
                switch rows{k,3}
                    case 'header'
                        nl.Text = rows{k,1};
                        nl.FontWeight = 'bold';
                        nl.FontColor = [0.13 0.13 0.13];
                        continue;
                    case 'solved'
                        nl.FontColor = [0.10 0.30 0.70];
                        vl.FontColor = [0.10 0.30 0.70];
                    case 'bad'
                        nl.FontColor = [0.35 0.35 0.35];
                        vl.FontColor = [0.85 0.15 0.15];
                    otherwise
                        nl.FontColor = [0.35 0.35 0.35];
                        vl.FontColor = [0 0 0];
                end
                nl.Text = ['   ' rows{k,1}];
                nl.FontWeight = 'normal';
                if strcmp(rows{k,1}, 'Flow Net'); vl.FontSize = 14; end
            end
        end

        function clearResults(app)
            % Row names and styles with blank values.
            z = struct('offset',0,'min_gap',0,'avg_gap',0,'max_angle_dev',0, ...
                'shell_d',0,'lobe_rmax',0,'lobe_rmin',0,'lobe_w',0, ...
                'lambda_r',0,'lambda_w',0,'area_eff',0,'CMM_loss',0, ...
                'CMM_net',0,'velocity_mps',0,'rpm',app.RPMField.Value, ...
                'interfere',false);
            rows = formatResultsLocal(z, 0, app.UnitsDropDown.Value, ...
                app.InputDropDown.Value, app.SDRadioBtn.Value);
            for k = 1:size(rows,1)
                if ~strcmp(rows{k,3}, 'header'); rows{k,2} = char(8212); end
            end
            showResults(app, rows);
        end

        function returnToDefaults(app)
            applyDefaults(app);
            app.StatusLabel.Text = 'Defaults restored.';
            app.StatusLabel.FontColor = [0.35 0.35 0.35];
        end

        % ---- Unified Compute & Plot ------------------------------------
        function computeAndPlot(app)
            nodes   = app.LobesSpinner.Value;
            ex      = app.ExField.Value;
            kind    = app.InputDropDown.Value;
            value   = app.OffsetField.Value;   % offset, min gap or max angle dev
            rotor_H = app.RotorHField.Value;
            sgap    = app.ShellGapField.Value;
            pts     = str2double(app.PointsDropDown.Value);
            units   = app.UnitsDropDown.Value;
            method  = app.MethodDropDown.Value;
            rpm     = app.RPMField.Value;
            outd    = app.OutletField.Value;
            isSD    = app.SDRadioBtn.Value;

            msg = 'Generating profile and analysing gaps...';
            if ~strcmp(kind, 'offset')
                msg = 'Solving for the offset...';
            elseif isSD
                msg = 'Solving for shaft spacing...';
            end
            dlg = uiprogressdlg(app.UIFigure, ...
                'Title','Computing', 'Message',msg, 'Indeterminate','on');

            try
                R = designComputeLocal(nodes, ex, kind, value, rotor_H, sgap, ...
                                       isSD, app.SSField.Value, pts, method, ...
                                       rpm, outd);
                ss = R.ss;
                xy = R.xy;

                app.LastXY    = xy;
                app.LastNodes = nodes;
                app.LastSS    = ss;

                showResults(app, formatResultsLocal(R, ss, units, kind, isSD));
                plotProfiles(app, xy, nodes, ss);

                app.StatusLabel.Tooltip = R.solve_note;
                if R.interfere
                    app.StatusLabel.Text = 'Lobes interfere.';
                    app.StatusLabel.FontColor = [0.85 0.15 0.15];
                elseif ~isempty(R.solve_note)
                    app.StatusLabel.Text = 'Target not exact (see message)';
                    app.StatusLabel.FontColor = [0.85 0.15 0.15];
                    close(dlg);
                    uialert(app.UIFigure, R.solve_note, 'Compute', 'Icon','warning');
                    return;
                else
                    app.StatusLabel.Text = 'Done.';
                    app.StatusLabel.FontColor = [0.20 0.60 0.20];
                end
            catch ME
                % No valid result: blank every value in red, so nothing
                % from an earlier run can be mistaken for this one.
                clearResults(app);
                for k = 1:RootsProfileApp.NRES
                    app.ResultLabels{k,2}.FontColor = [0.85 0.15 0.15];
                end
                app.LastXY = [];
                app.StatusLabel.Text = 'Error (see message)';
                app.StatusLabel.Tooltip = ME.message;
                app.StatusLabel.FontColor = [0.85 0.15 0.15];
                close(dlg);
                uialert(app.UIFigure, ME.message, 'Compute');
                return;
            end
            close(dlg);
        end

        % ---- Draw six rotation-angle subplots --------------------------
        function plotProfiles(app, xy, nodes, ss)
            starta = 0;
            startb = 180 + 180/nodes;
            ang_delta = (180/nodes) / 5;

            for idx = 1:6
                ax = app.Ax(idx);
                cla(ax);

                ang = (idx-1) * ang_delta;
                r1 = rotateShiftLocal(xy, starta + ang,  [-ss/2, 0]);
                r2 = rotateShiftLocal(xy, startb - ang,  [ ss/2, 0]);

                plot(ax, r1(:,1), r1(:,2), '-', ...
                    'Color',[0.15 0.35 0.70], 'LineWidth',1.2);
                hold(ax,'on');
                plot(ax, r2(:,1), r2(:,2), '-', ...
                    'Color',[0.75 0.22 0.17], 'LineWidth',1.2);
                hold(ax,'off');

                ax.DataAspectRatio = [1 1 1];
                maxR = max(abs(xy(:))) + ss/2 + 10;
                xlim(ax, [-maxR maxR]);
                ylim(ax, [-maxR*0.70 maxR*0.70]);
                title(ax, sprintf('%.1f%s', ang, char(176)), 'FontSize',11);
                grid(ax,'on');
                ax.GridAlpha = 0.15;
            end
        end

        % ---- Plot the row where Plot? == true --------------------------
        function plotMarkedProfiles(app)
            cellData = app.BatchInputTable.Data;
            if isempty(cellData)
                app.BatchStatusLabel.Text = 'No rows to plot.';
                return;
            end
            if isempty(app.BatchXYCache)
                app.BatchStatusLabel.Text = 'Run batch first, then plot.';
                return;
            end

            plotFlags  = cell2mat(cellData(:,1));
            markedRows = find(plotFlags);
            if isempty(markedRows)
                app.BatchStatusLabel.Text = 'No row marked Plot? = Yes.';
                return;
            end

            % Color palette — one colour per overlaid profile
            palette = [ ...
                0.15 0.35 0.70; ...
                0.85 0.25 0.15; ...
                0.20 0.65 0.30; ...
                0.85 0.55 0.10; ...
                0.55 0.25 0.70; ...
                0.10 0.60 0.65; ...
                0.85 0.40 0.55; ...
                0.40 0.40 0.40];

            % Angle steps from first marked row
            firstNodes = app.BatchNodeCache(markedRows(1));
            ang_delta  = (180 / firstNodes) / 5;

            % Axis limits across all marked profiles
            maxR = 0;
            for m = 1:numel(markedRows)
                row = markedRows(m);
                if row <= numel(app.BatchXYCache) && ~isempty(app.BatchXYCache{row})
                    xy = app.BatchXYCache{row};
                    ss = app.BatchSSCache(row);
                    maxR = max(maxR, max(abs(xy(:))) + ss/2 + 10);
                end
            end

            % Clear axes and hold on
            for idx = 1:6
                cla(app.Ax(idx));
                hold(app.Ax(idx), 'on');
            end

            % Overlay each marked profile
            for m = 1:numel(markedRows)
                row = markedRows(m);
                if row > numel(app.BatchXYCache) || isempty(app.BatchXYCache{row})
                    continue;
                end
                xy    = app.BatchXYCache{row};
                nodes = app.BatchNodeCache(row);
                ss    = app.BatchSSCache(row);
                col   = palette(mod(m-1, size(palette,1)) + 1, :);

                starta = 0;
                startb = 180 + 180/nodes;
                for idx = 1:6
                    ang = (idx-1) * ang_delta;
                    r1 = rotateShiftLocal(xy, starta + ang, [-ss/2, 0]);
                    r2 = rotateShiftLocal(xy, startb - ang, [ ss/2, 0]);
                    plot(app.Ax(idx), r1(:,1), r1(:,2), '-', ...
                        'Color', col, 'LineWidth', 1.2);
                    plot(app.Ax(idx), r2(:,1), r2(:,2), '-', ...
                        'Color', col, 'LineWidth', 1.2);
                end
            end

            % Format axes
            for idx = 1:6
                ax = app.Ax(idx);
                hold(ax, 'off');
                ax.DataAspectRatio = [1 1 1];
                xlim(ax, [-maxR maxR]);
                ylim(ax, [-maxR*0.70 maxR*0.70]);
                ang = (idx-1) * ang_delta;
                title(ax, sprintf('%.1f%s', ang, char(176)), 'FontSize', 11);
                grid(ax, 'on');
                ax.GridAlpha = 0.15;
            end

            app.BatchStatusLabel.Text = ...
                sprintf('Plotted %d marked profile(s).', numel(markedRows));
        end

        % ---- Batch: Run All -------------------------------------------
        function runBatch(app)
            cellData = app.BatchInputTable.Data;
            if isempty(cellData)
                app.BatchStatusLabel.Text = 'No rows. Load defaults or add rows.';
                return;
            end
            nRows   = size(cellData,1);
            numData = cell2mat(cellData(:,2:8));    % columns 2-8 are params
            units   = app.UnitsDropDown.Value;
            method  = app.MethodDropDown.Value;
            rpm     = app.RPMField.Value;
            outd    = app.OutletField.Value;
            kind    = app.InputDropDown.Value;
            app.BatchSettings = struct('units',units,'method',method, ...
                                       'rpm',rpm,'outlet_d',outd, ...
                                       'input_kind',kind);
            removeStyle(app.BatchResultsTable);
            badRows = [];               % interfering lobes
            errRows = [];               % failed solves
            noteRows = [];              % target not exact
            errMsgs = {};
            [~, ~, ~, fs, vs] = unitInfoLocal(units);
            isSD    = app.SDRadioBtn.Value;
            resData = zeros(nRows, 15);
            app.BatchXYCache   = cell(nRows,1);
            app.BatchNodeCache = zeros(nRows,1);
            app.BatchSSCache   = zeros(nRows,1);

            dlg = uiprogressdlg(app.UIFigure, ...
                'Title','Batch Processing', ...
                'Message','Starting...', ...
                'Cancelable','on');

            for i = 1:nRows
                if dlg.CancelRequested
                    app.BatchStatusLabel.Text = ...
                        sprintf('Cancelled after %d/%d.', i-1, nRows);
                    close(dlg);
                    app.BatchResultsTable.Data = resData(1:i-1,:);
                    return;
                end
                dlg.Value   = (i-1)/nRows;
                dlg.Message = sprintf('Set %d / %d ...', i, nRows);

                nd=numData(i,1); ex=numData(i,2); gs=numData(i,3);
                rh=numData(i,4); sg=numData(i,5); col6=numData(i,6);
                pt=numData(i,7);
                try
                    % gs: offset, min gap or max angle dev (Design Input)
                    R = designComputeLocal(nd, ex, kind, gs, rh, sg, isSD, ...
                                           col6, pt, method, rpm, outd);
                    shaft = R.ss;
                    resData(i,:) = [R.offset, R.min_gap, R.avg_gap, ...
                        R.max_angle_dev, shaft, R.shell_d, R.lobe_rmax, ...
                        R.lobe_rmin, R.lobe_w, R.lambda_r, R.lambda_w, ...
                        R.area_eff, R.velocity_mps*vs, R.CMM_loss*fs, ...
                        R.CMM_net*fs];
                    if R.interfere; badRows(end+1) = i; end %#ok<AGROW>
                    if ~isempty(R.solve_note)
                        noteRows(end+1) = i; %#ok<AGROW>
                        errMsgs{end+1} = sprintf('Row %d: %s', i, R.solve_note); %#ok<AGROW>
                    end
                    app.BatchXYCache{i}   = R.xy;
                    app.BatchNodeCache(i) = nd;
                    app.BatchSSCache(i)   = shaft;
                catch ME
                    resData(i,:) = NaN;
                    errRows(end+1) = i; %#ok<AGROW>
                    errMsgs{end+1} = sprintf('Row %d: %s', i, ME.message); %#ok<AGROW>
                end
            end
            close(dlg);

            app.BatchResultsTable.Data = round(resData, 4);
            if ~isempty(badRows)
                % Interfering lobes: gap, angle and flow cells shown as 0 in red
                [rr, cc] = ndgrid(badRows, RootsProfileApp.BATCH_BAD_COLS);
                addStyle(app.BatchResultsTable, uistyle('FontColor',[0.85 0.15 0.15]), ...
                         'cell', [rr(:), cc(:)]);
            end
            red = uistyle('FontColor',[0.85 0.15 0.15]);
            if ~isempty(errRows)
                addStyle(app.BatchResultsTable, red, 'row', errRows);
            end
            if ~isempty(noteRows)
                if strcmp(kind, 'min_gap'); kc = 2; else; kc = 4; end
                addStyle(app.BatchResultsTable, red, 'cell', ...
                         [noteRows(:), repmat(kc, numel(noteRows), 1)]);
            end
            % Auto-plot the row marked Plot? = true (before the status text,
            % which the plot would otherwise overwrite)
            plotMarkedProfiles(app);
            if isempty(errMsgs)
                app.BatchStatusLabel.Text = ...
                    sprintf('Done — %d sets.  Select Plot? then press Plot.', nRows);
            else
                app.BatchStatusLabel.Text = sprintf( ...
                    'Done — %d sets. %d row(s) failed or missed the target (red).', ...
                    nRows, numel(errMsgs));
                uialert(app.UIFigure, strjoin(errMsgs, newline), 'Batch', ...
                        'Icon','warning');
            end
        end

        % ---- Batch result row clicked -> plot ---------------------------
        function batchResultClicked(app, event)
            if isempty(event.Indices); return; end
            row = event.Indices(1,1);
            if isempty(app.BatchXYCache) || row > numel(app.BatchXYCache)
                return;
            end
            if isempty(app.BatchXYCache{row}); return; end
            plotProfiles(app, app.BatchXYCache{row}, ...
                app.BatchNodeCache(row), app.BatchSSCache(row));
            app.BatchStatusLabel.Text = sprintf('Showing row %d.', row);
        end

        % ---- Batch input row selected (for delete) --------------------
        function batchInputSelected(app, event)
            if ~isempty(event.Indices)
                app.SelectedInputRow = event.Indices(1,1);
            end
        end

        % ---- Batch: Plot? radio behaviour (single selection) ----------
        function batchCellEdited(app, event)
            row = event.Indices(1);
            col = event.Indices(2);
            if col == 1
                d  = app.BatchInputTable.Data;
                nR = size(d,1);
                for k = 1:nR
                    d{k,1} = false;
                end
                d{row,1} = true;
                app.BatchInputTable.Data = d;
            end
        end

        % ---- Batch: Add a row from interactive params ------------------
        function addRow(app)
            newRow = [{false}, num2cell([app.LobesSpinner.Value, ...
                app.ExField.Value, app.OffsetField.Value, ...
                app.RotorHField.Value, app.ShellGapField.Value, ...
                app.SSField.Value, str2double(app.PointsDropDown.Value)])];
            if isempty(app.BatchInputTable.Data)
                app.BatchInputTable.Data = newRow;
            else
                app.BatchInputTable.Data = ...
                    [app.BatchInputTable.Data; newRow];
            end
            app.BatchStatusLabel.Text = 'Row added.';
        end

        % ---- Batch: Delete selected or last row -----------------------
        function deleteRow(app)
            d = app.BatchInputTable.Data;
            if isempty(d); return; end
            if app.SelectedInputRow > 0 && app.SelectedInputRow <= size(d,1)
                d(app.SelectedInputRow,:) = [];
                app.SelectedInputRow = 0;
            else
                d(end,:) = [];
            end
            app.BatchInputTable.Data = d;
            app.BatchStatusLabel.Text = 'Row deleted.';
        end

        % ---- Batch: Load default parameter sets -----------------------
        function loadDefaults(app)
            sg = 2;
            if app.SDRadioBtn.Value
                % Set Shell Diameter mode: paper Table 3 (130 mm housing);
                % column 6 is the shell diameter.
                defs = [
                    2, 0.000, 1.00, 100, sg, 130, 1001;
                    3, 0.000, 1.00, 100, sg, 130, 1001;
                    4, 0.000, 1.00, 100, sg, 130, 1001;
                    5, 0.000, 1.00, 100, sg, 130, 1001;
                    2, 0.245, 2.42, 100, sg, 130, 1001;
                    3, 0.245, 2.72, 100, sg, 130, 1001;
                    4, 0.245, 3.06, 100, sg, 130, 1001;
                    5, 0.245, 3.39, 100, sg, 130, 1001];
                what = '130 mm housing (paper Table 3)';
            else
            what = '80.4 mm shaft spacing (paper Table 1)';
            defs = [
                2, 0.000, 1.00, 100, sg, 80.4, 1001;
                2, 0.089, 1.17, 100, sg, 80.4, 1001;
                2, 0.170, 1.70, 100, sg, 80.4, 1001;
                2, 0.245, 2.545, 100, sg, 80.4, 1001;
                2, 0.300, 3.40, 100, sg, 80.4, 1001;
                3, 0.000, 1.00, 100, sg, 80.4, 1001;
                3, 0.089, 1.18, 100, sg, 80.4, 1001;
                3, 0.170, 1.76, 100, sg, 80.4, 1001;
                3, 0.245, 2.72, 100, sg, 80.4, 1001;
                3, 0.300, 3.675, 100, sg, 80.4, 1001;
                4, 0.000, 1.00, 100, sg, 80.4, 1001;
                4, 0.089, 1.19, 100, sg, 80.4, 1001;
                4, 0.170, 1.85, 100, sg, 80.4, 1001;
                4, 0.245, 2.95, 100, sg, 80.4, 1001;
                4, 0.300, 4.00, 100, sg, 80.4, 1001;
                5, 0.000, 1.00, 100, sg, 80.4, 1001;
                5, 0.089, 1.20, 100, sg, 80.4, 1001;
                5, 0.170, 1.95, 100, sg, 80.4, 1001;
                5, 0.245, 3.15, 100, sg, 80.4, 1001;
                5, 0.300, 4.30, 100, sg, 80.4, 1001];
            end

            kind = app.InputDropDown.Value;
            if ~strcmp(kind, 'offset')
                % Same cases, with the chosen design input in column 3
                [label, unit, def] = inputKindInfoLocal(kind);
                defs(:,3) = def;
                what = sprintf('%s, %s %g %s', what, label, def, unit);
            end
            nR = size(defs,1);
            plotCol = num2cell(false(nR,1));
            plotCol{end} = true;                    % last row defaults to Plot
            app.BatchInputTable.Data = [plotCol, num2cell(defs)];
            app.BatchStatusLabel.Text = sprintf('%d default rows loaded: %s.', nR, what);
        end

        % ---- Export batch results to CSV ------------------------------
        function exportBatch(app)
            rd = app.BatchResultsTable.Data;
            cellData = app.BatchInputTable.Data;
            if isempty(rd)
                uialert(app.UIFigure,'No results. Run batch first.','Export');
                return;
            end
            [file,path] = uiputfile('*.csv','Export Batch Results');
            if file == 0; return; end
            st = app.BatchSettings;
            [~, fu, vu] = unitInfoLocal(st.units);
            if app.SDRadioBtn.Value
                col6hdr = 'shell_d_input';
            else
                col6hdr = 'ss_input';
            end
            headers = {'Lobes','ex',[st.input_kind '_input'],'rotor_H', ...
                'shellgap',col6hdr,'points', ...
                'offset','min_gap','avg_gap','max_angle_dev_deg','ss', ...
                'shell_d','lobe_rmax','lobe_rmin','lobe_w','lambda_r', ...
                'lambda_w','area_eff',['velocity_' strrep(vu,'/','_')], ...
                ['flow_loss_' fu],['flow_net_' fu]};
            numInput = cell2mat(cellData(:,2:8));   % skip Plot? column
            T = array2table([numInput, rd], 'VariableNames', headers);
            nR = height(T);
            T.method   = repmat(string(st.method), nR, 1);
            T.rpm      = repmat(st.rpm, nR, 1);
            T.outlet_d = repmat(st.outlet_d, nR, 1);
            writetable(T, fullfile(path,file));
            app.BatchStatusLabel.Text = ['Saved: ' file];
        end

        % ---- Export spline points for Fusion 360 ----------------------
        function exportSpline(app)
            if isempty(app.LastXY)
                uialert(app.UIFigure, ...
                    'No profile computed yet. Press Compute first.','Export');
                return;
            end
            [file,path] = uiputfile('*.csv','Export Spline Points');
            if file == 0; return; end
            scale = 10;
            xy = app.LastXY;
            z  = zeros(size(xy,1), 1);
            out = round([xy./scale, z] .* 1000) ./ 1000;
            writematrix(out, fullfile(path,file));
            app.StatusLabel.Text = ['Spline -> ' file];
            app.StatusLabel.FontColor = [0.20 0.60 0.20];
        end

        % =================================================================
        %  BUILD THE UI
        % =================================================================
        function createComponents(app)

            % ---- Figure ------------------------------------------------
            app.UIFigure = uifigure('Visible','off');
            app.UIFigure.Position = [60 40 1460 920];
            app.UIFigure.Name = sprintf('%s  v%s  —  %s', ...
                RootsProfileApp.APP_NAME, ...
                 RootsProfileApp.VERSION, ...
                RootsProfileApp.APP_VENDOR);
            app.UIFigure.Color = [0.96 0.96 0.97];

            % ---- Main grid: [left panel | right plots] ------------------
            app.MainGrid = uigridlayout(app.UIFigure, [1 2]);
            app.MainGrid.ColumnWidth = {400, '1x'};
            app.MainGrid.Padding = [6 6 6 6];
            app.MainGrid.ColumnSpacing = 6;

            % ---- Left panel: mode toggle + tab group --------------------
            app.LeftPanel = uigridlayout(app.MainGrid, [3 1]);
            app.LeftPanel.Layout.Row = 1;
            app.LeftPanel.Layout.Column = 1;
            app.LeftPanel.RowHeight = {30, 'fit', '1x'};
            app.LeftPanel.Padding = [0 0 0 0];
            app.LeftPanel.RowSpacing = 4;

            app.ModeRow = uigridlayout(app.LeftPanel, [1 2]);
            app.ModeRow.Layout.Row = 1;
            app.ModeRow.ColumnWidth = {'1x', 125};
            app.ModeRow.Padding = [0 0 0 0];
            app.ModeRow.ColumnSpacing = 4;
            app.ModeButtonGroup = uibuttongroup(app.ModeRow, ...
                'BorderType','none', ...
                'BackgroundColor',[0.96 0.96 0.97]);
            app.ModeButtonGroup.Layout.Row = 1;
            app.ModeButtonGroup.Layout.Column = 1;
            app.SSRadioBtn = uiradiobutton(app.ModeButtonGroup, ...
                'Text','Set Shaft Spacing', ...
                'Position',[6 2 130 22]);
            app.SDRadioBtn = uiradiobutton(app.ModeButtonGroup, ...
                'Text','Set Shell Diameter', ...
                'Position',[138 2 135 22], ...
                'Value',true);              % default at start-up
            app.ReturnDefaultsBtn = uibutton(app.ModeRow,'push', ...
                'Text','Return to Defaults', ...
                'Tooltip',['Set Shell Diameter (130 mm), 1000 RPM, rotor ' ...
                           'height 100 mm, Averaged method and default ' ...
                           '3-lobe parameters. Units are kept.']);
            app.ReturnDefaultsBtn.Layout.Row = 1;
            app.ReturnDefaultsBtn.Layout.Column = 2;
            app.ReturnDefaultsBtn.ButtonPushedFcn = @(~,~) returnToDefaults(app);
            app.ModeButtonGroup.SelectionChangedFcn = ...
                @(~,~) modeChanged(app);

            % ---- Settings shared by both tabs ---------------------------
            chg = @(~,~) paramChanged(app);
            app.SettingsPanel = uipanel(app.LeftPanel,'Title','Settings', ...
                'FontWeight','bold');
            app.SettingsPanel.Layout.Row = 2;
            sgl = uigridlayout(app.SettingsPanel, [5 2]);
            sgl.ColumnWidth = {140, '1x'};
            sgl.RowHeight = repmat({24}, 1, 5);
            sgl.Padding = [8 4 8 4];
            sgl.RowSpacing = 3;
            slabs = {'Profile Method','Design Input','Units', ...
                'Rotor Speed (RPM)','Outlet Diameter (mm)'};
            for k = 1:5
                lb = uilabel(sgl,'Text',slabs{k});
                lb.Layout.Row = k; lb.Layout.Column = 1;
            end
            app.MethodDropDown = uidropdown(sgl, ...
                'Items',{'Averaged','Noslip rolling'}, ...
                'ItemsData',{'averaged','noslip'},'Value','averaged', ...
                'Tooltip',['Averaged: fixed-ratio construction of the paper ' ...
                           '(default). Noslip rolling: circle rolls without ' ...
                           'slip on the pitch curve.']);
            app.MethodDropDown.Layout.Row = 1;
            app.MethodDropDown.Layout.Column = 2;
            app.MethodDropDown.ValueChangedFcn = chg;
            app.InputDropDown = uidropdown(sgl, ...
                'Items',{'Offset (mm)','Min Gap (mm)','Max Angle Dev (deg)'}, ...
                'ItemsData',{'offset','min_gap','max_angle_dev'}, ...
                'Value','offset', ...
                'Tooltip',['Which clearance value you enter. The other two ' ...
                           'are computed: with Min Gap or Max Angle Dev ' ...
                           'the offset is solved for.']);
            app.InputDropDown.Layout.Row = 2;
            app.InputDropDown.Layout.Column = 2;
            app.InputDropDown.ValueChangedFcn = @(~,~) inputKindChanged(app);
            app.UnitsDropDown = uidropdown(sgl, ...
                'Items',{'SI','Imperial'},'Value','SI', ...
                'Tooltip',['SI: flow in CMM, velocity in m/s. Imperial: ' ...
                           'flow in CFM, velocity in ft/min. Dimensions ' ...
                           'are always in mm.']);
            app.UnitsDropDown.Layout.Row = 3;
            app.UnitsDropDown.Layout.Column = 2;
            app.UnitsDropDown.ValueChangedFcn = chg;
            app.RPMField = uieditfield(sgl,'numeric', ...
                'Limits',[1 100000],'Value',1000, ...
                'ValueDisplayFormat','%.0f');
            app.RPMField.Layout.Row = 4;
            app.RPMField.Layout.Column = 2;
            app.RPMField.ValueChangedFcn = chg;
            app.OutletField = uieditfield(sgl,'numeric', ...
                'Limits',[1 2000],'Value',51, ...
                'ValueDisplayFormat','%.1f', ...
                'Tooltip','Discharge opening diameter, for mean outlet velocity');
            app.OutletField.Layout.Row = 5;
            app.OutletField.Layout.Column = 2;
            app.OutletField.ValueChangedFcn = chg;

            % ============================================================
            %  LEFT — Tab group (Interactive / Batch)
            % ============================================================
            app.LeftTabGroup = uitabgroup(app.LeftPanel);
            app.LeftTabGroup.Layout.Row = 3;

            % ---------- INTERACTIVE TAB ---------------------------------
            app.InteractiveTab = uitab(app.LeftTabGroup,'Title','Interactive');
            ig = uigridlayout(app.InteractiveTab, [4 1]);
            ig.RowHeight = {'fit', 38, 'fit', '1x'};
            ig.Padding = [6 6 6 6];
            ig.RowSpacing = 8;

            % -- Parameters panel --
            pp = uipanel(ig,'Title','Parameters','FontWeight','bold');
            pp.Layout.Row = 1;
            pg = uigridlayout(pp, [7 2]);
            pg.ColumnWidth = {140, '1x'};
            pg.RowHeight = repmat({28}, 1, 7);
            pg.Padding = [8 6 8 6];
            pg.RowSpacing = 4;

            labs = {'Lobes','Eccentricity (ex)', ...
                'Offset (mm)','Rotor Height (mm)', ...
                'Shell Gap (mm)','Shaft Spacing (mm)', ...
                'Points'};
            for k = 1:7
                lb = uilabel(pg,'Text',labs{k});
                lb.Layout.Row = k; lb.Layout.Column = 1;
                if k == 3; app.OffsetLabel = lb; end
                if k == 6; app.SwitchLabel = lb; end
            end

            app.LobesSpinner = uispinner(pg, ...
                'Limits',[2 10],'Value',3,'Step',1);
            app.LobesSpinner.Layout.Row = 1;
            app.LobesSpinner.Layout.Column = 2;
            app.LobesSpinner.ValueChangedFcn = chg;

            app.ExField = uieditfield(pg,'numeric', ...
                'Limits',[0 0.5],'Value',0.245, ...
                'ValueDisplayFormat','%.3f');
            app.ExField.Layout.Row = 2;
            app.ExField.Layout.Column = 2;
            app.ExField.ValueChangedFcn = chg;

            app.OffsetField = uieditfield(pg,'numeric', ...
                'Limits',[0.01 Inf],'Value',2.72, ...
                'ValueDisplayFormat','%.3f');
            app.OffsetField.Layout.Row = 3;
            app.OffsetField.Layout.Column = 2;
            app.OffsetField.ValueChangedFcn = chg;

            app.RotorHField = uieditfield(pg,'numeric', ...
                'Limits',[1 Inf],'Value',100, ...
                'ValueDisplayFormat','%.1f');
            app.RotorHField.Layout.Row = 4;
            app.RotorHField.Layout.Column = 2;
            app.RotorHField.ValueChangedFcn = chg;

            app.ShellGapField = uieditfield(pg,'numeric', ...
                'Limits',[0 Inf],'Value',2, ...
                'ValueDisplayFormat','%.1f');
            app.ShellGapField.Layout.Row = 5;
            app.ShellGapField.Layout.Column = 2;
            app.ShellGapField.ValueChangedFcn = chg;

            app.SSField = uieditfield(pg,'numeric', ...
                'Limits',[1 Inf],'Value',80.4, ...
                'ValueDisplayFormat','%.1f');
            app.SSField.Layout.Row = 6;
            app.SSField.Layout.Column = 2;
            app.SSField.ValueChangedFcn = chg;

            app.PointsDropDown = uidropdown(pg, ...
                'Items',{'180','360','720','1001'},'Value','1001');
            app.PointsDropDown.Layout.Row = 7;
            app.PointsDropDown.Layout.Column = 2;
            app.PointsDropDown.ValueChangedFcn = chg;

            % -- Buttons row --
            br = uigridlayout(ig,[1 3]);
            br.Layout.Row = 2;
            br.ColumnWidth = {110, 110, '1x'};
            br.Padding = [0 0 0 0];
            br.ColumnSpacing = 6;

            app.ComputeButton = uibutton(br,'push','Text','Compute', ...
                'FontWeight','bold', ...
                'BackgroundColor',[0.20 0.47 0.80], ...
                'FontColor','w');
            app.ComputeButton.Layout.Column = 1;
            app.ComputeButton.ButtonPushedFcn = @(~,~) computeAndPlot(app);

            app.ExportSplineBtn = uibutton(br,'push','Text','Export Spline');
            app.ExportSplineBtn.Layout.Column = 2;
            app.ExportSplineBtn.ButtonPushedFcn = @(~,~) exportSpline(app);

            app.StatusLabel = uilabel(br,'Text','','FontColor',[0.4 0.4 0.4]);
            app.StatusLabel.Layout.Column = 3;

            % -- Results panel --
            nres = RootsProfileApp.NRES;
            rp = uipanel(ig,'Title','Results','FontWeight','bold');
            rp.Layout.Row = 3;
            rg = uigridlayout(rp,[nres 2]);
            rg.ColumnWidth = {140,'1x'};
            rg.RowHeight = repmat({19},1,nres);
            rg.Padding = [8 4 8 4];
            rg.RowSpacing = 1;

            app.ResultLabels = cell(nres,2);
            for k = 1:nres
                app.ResultLabels{k,1} = uilabel(rg,'Text','', ...
                    'FontColor',[0.35 0.35 0.35]);
                app.ResultLabels{k,1}.Layout.Row = k;
                app.ResultLabels{k,1}.Layout.Column = 1;
                app.ResultLabels{k,2} = uilabel(rg,'Text',char(8212), ...
                    'FontWeight','bold');
                app.ResultLabels{k,2}.Layout.Row = k;
                app.ResultLabels{k,2}.Layout.Column = 2;
            end

            % ---------- BATCH TAB ---------------------------------------
            app.BatchTab = uitab(app.LeftTabGroup,'Title','Batch');
            bg = uigridlayout(app.BatchTab,[4 1]);
            bg.RowHeight = {'1x', 34, '1x', 22};
            bg.Padding = [6 6 6 6];
            bg.RowSpacing = 6;

            % Batch input table (editable, first column is Plot? radio)
            app.BatchInputTable = uitable(bg);
            app.BatchInputTable.Layout.Row = 1;
            app.BatchInputTable.ColumnName = ...
                {'Plot?','Lobes','ex','offset','rotor_H','shell_gap','ss','points'};
            app.BatchInputTable.ColumnFormat = ...
                {'logical','numeric','numeric','numeric','numeric','numeric','numeric','numeric'};
            app.BatchInputTable.ColumnEditable = true(1,8);
            app.BatchInputTable.Data = {};
            app.BatchInputTable.CellSelectionCallback = ...
                @(~,ev) batchInputSelected(app,ev);
            app.BatchInputTable.CellEditCallback = ...
                @(~,ev) batchCellEdited(app,ev);

            % Button bar
            bb = uigridlayout(bg,[1 6]);
            bb.Layout.Row = 2;
            bb.ColumnWidth = {'1x','1x','1x','1x','1x','1x'};
            bb.Padding = [0 0 0 0];
            bb.ColumnSpacing = 4;

            app.LoadDefaultsBtn = uibutton(bb,'push','Text','Defaults');
            app.LoadDefaultsBtn.Layout.Column = 1;
            app.LoadDefaultsBtn.ButtonPushedFcn = @(~,~) loadDefaults(app);

            app.AddRowBtn = uibutton(bb,'push','Text','Add Row');
            app.AddRowBtn.Layout.Column = 2;
            app.AddRowBtn.ButtonPushedFcn = @(~,~) addRow(app);

            app.DeleteRowBtn = uibutton(bb,'push','Text','Delete');
            app.DeleteRowBtn.Layout.Column = 3;
            app.DeleteRowBtn.ButtonPushedFcn = @(~,~) deleteRow(app);

            app.RunAllBtn = uibutton(bb,'push','Text','Run All', ...
                'FontWeight','bold', ...
                'BackgroundColor',[0.22 0.60 0.30], ...
                'FontColor','w');
            app.RunAllBtn.Layout.Column = 4;
            app.RunAllBtn.ButtonPushedFcn = @(~,~) runBatch(app);

            app.PlotMarkedBtn = uibutton(bb,'push','Text','Plot', ...
                'FontWeight','bold', ...
                'BackgroundColor',[0.20 0.47 0.80], ...
                'FontColor','w');
            app.PlotMarkedBtn.Layout.Column = 5;
            app.PlotMarkedBtn.ButtonPushedFcn = @(~,~) plotMarkedProfiles(app);

            app.ExportBatchBtn = uibutton(bb,'push','Text','Export');
            app.ExportBatchBtn.Layout.Column = 6;
            app.ExportBatchBtn.ButtonPushedFcn = @(~,~) exportBatch(app);

            % Batch results table (read-only, click row to plot)
            app.BatchResultsTable = uitable(bg);
            app.BatchResultsTable.Layout.Row = 3;
            app.BatchResultsTable.ColumnName = ...
                {'Offset','Min_Gap','Avg_Gap','Max_Angle_Dev','SS', ...
                 'Shell_D','Rmax','Rmin','Width','Lambda_r','Lambda_w', ...
                 'Area_Eff','Velocity','Flow_Loss','Flow_Net'};
            app.BatchResultsTable.ColumnEditable = false(1,15);
            app.BatchResultsTable.Data = [];
            app.BatchResultsTable.CellSelectionCallback = ...
                @(~,ev) batchResultClicked(app,ev);

            app.BatchStatusLabel = uilabel(bg, ...
                'Text','Load defaults or add rows to begin.', ...
                'FontColor',[0.4 0.4 0.4]);
            app.BatchStatusLabel.Layout.Row = 4;

            % ============================================================
            %  RIGHT — Plot panel  (2 x 3 axes)
            % ============================================================
            app.PlotPanel = uipanel(app.MainGrid, ...
                'Title','Rotor Profiles at Rotation Angles', ...
                'FontWeight','bold','BorderType','line');
            app.PlotPanel.Layout.Row = 1;
            app.PlotPanel.Layout.Column = 2;

            app.PlotGrid = uigridlayout(app.PlotPanel,[2 3]);
            app.PlotGrid.Padding = [4 4 4 4];
            app.PlotGrid.RowSpacing = 6;
            app.PlotGrid.ColumnSpacing = 6;

            app.Ax = gobjects(1,6);
            idx = 0;
            for r = 1:2
                for c = 1:3
                    idx = idx + 1;
                    ax = uiaxes(app.PlotGrid);
                    ax.Layout.Row = r;
                    ax.Layout.Column = c;
                    ax.XGrid = 'on';
                    ax.YGrid = 'on';
                    ax.GridAlpha = 0.15;
                    ax.DataAspectRatio = [1 1 1];
                    ax.FontSize = 10;
                    title(ax, char(8212));
                    app.Ax(idx) = ax;
                end
            end

            % ---- Show figure -------------------------------------------
            applyDefaults(app);          % start in Set Shell Diameter mode
            app.StatusLabel.Text = '';
            app.UIFigure.Visible = 'on';
        end
    end

    % =====================================================================
    %  PUBLIC — constructor / destructor
    % =====================================================================
    methods (Access = public)
        function app = RootsProfileApp
            createComponents(app);
            registerApp(app, app.UIFigure);
            if nargout == 0
                clear app
            end
        end
        function delete(app)
            delete(app.UIFigure);
        end
    end
end

% =========================================================================
%  LOCAL COMPUTATION FUNCTIONS
%  (accessible to all methods in this file)
% =========================================================================

function [x, y, rho] = pitchcurveLocal(ss, ex, nodes, theta)
    % Noncircular gear pitch curve with half-gap correction
    a   = ss / (1 + sqrt(1 - ex^2));
    cp  = a * (1 - ex^2);
    rho = cp ./ (1 - ex * cos(nodes * theta));
    other_theta = -theta + pi/nodes;
    other_rho   = cp ./ (1 - ex * cos(nodes * other_theta));
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
    gaps = zeros(360, 1);
    for i = 1:360
        ang = i - 1;
        gaps(i) = pairGapLocal(xyarray, starta + ang, startb - ang, ss);
    end
    [min_gap, imin] = min(gaps);
    ang_at_min = imin - 1;
    avg_gap = mean(gaps);
    gaparray = [(1:360)', gaps];
end

function gap = pairGapLocal(xyarray, theta1, theta2, ss)
    % Signed clearance between rotor1 held at theta1 and rotor2 held at
    % theta2 (shaft centres at -ss/2 and +ss/2).
    %   Positive: smallest vertex-to-vertex distance between the rotors.
    %   Negative: the rotors overlap; minus the penetration depth (largest
    %   distance from a rotor2 vertex inside rotor1 to the nearest rotor1
    %   vertex).
    % Evaluated in rotor1's own frame. Only vertices near the other rotor
    % are compared; if the result is not within the margin G that makes
    % this exact, all vertices are compared.
    p1 = xyarray;                                               % rotor1, local
    p2 = rotateShiftLocal(xyarray, theta2, [ss/2, 0]) + [ss/2, 0];
    p2 = rotateShiftLocal(p2, -theta1, [0, 0]);                 % rotor2 in rotor1 frame
    c2 = rotateShiftLocal([ss, 0], -theta1, [0, 0]);            % rotor2 centre
    rmax = max(hypot(p1(:,1), p1(:,2)));
    G = 0.15 * rmax;
    i2 = find(hypot(p2(:,1), p2(:,2)) <= rmax + G);
    i1 = find(hypot(p1(:,1) - c2(1), p1(:,2) - c2(2)) <= rmax + G);
    gap = Inf;
    if ~isempty(i1) && ~isempty(i2)
        gap = signedGapLocal(p1, p2(i2,:), i1);
    end
    if ~(abs(gap) <= G)
        gap = signedGapLocal(p1, p2, 1:size(p1,1));
    end
end

function gap = signedGapLocal(p1, q, i1)
    % q: rotor2 vertices (rotor1 frame); i1: rotor1 vertices to compare.
    dx = p1(i1,1) - q(:,1).';
    dy = p1(i1,2) - q(:,2).';
    d  = sqrt(min(dx.^2 + dy.^2, [], 1));        % nearest rotor1 vertex
    in = inpolygon(q(:,1), q(:,2), p1(:,1), p1(:,2));
    if any(in)
        gap = -max(d(in));
    else
        gap = min(d);
    end
end

function [min_gap, avg_gap, max_angle_dev] = gapMetricsLocal(xyarray, nodes, ss, doAngle)
    % Min / average gap over a full rotation and, if doAngle, the max
    % angle deviation (NaN otherwise). The play is checked at every
    % distinct close approach of the rotors (closeApproachAnglesLocal),
    % not only at the overall minimum gap: the tightest angular play can
    % be at a different position, and using only the overall minimum makes
    % the value jump when that position moves.
    if nargin < 4; doAngle = true; end
    [min_gap, avg_gap, gaparray, ang_at_min] = findMinGapLocal(xyarray, nodes, ss);
    max_angle_dev = NaN;
    if doAngle
        seg = hypot(diff(xyarray(:,1)), diff(xyarray(:,2)));
        cand = closeApproachAnglesLocal(gaparray(:,2), nodes, 0.02 * median(seg));
        max_angle_dev = Inf;
        for k = 1:numel(cand)
            ang_refined = refineMinGapAngleLocal(xyarray, nodes, ss, cand(k));
            max_angle_dev = min(max_angle_dev, ...
                findMaxAngleDeviationLocal(xyarray, nodes, ss, ang_refined, max_angle_dev));
        end
    end
end

function cand = closeApproachAnglesLocal(gaps, nodes, tol)
    % Sweep angles (deg) of the distinct close approaches in the 1-degree
    % gap sweep (gaps(i) is the gap at sweep angle i-1), tightest first.
    % A close approach is a local minimum of the gap. Two kinds of local
    % minima are dropped, because checking them repeats work without
    % changing the result:
    %   ripples: minima that rise less than tol before the gap falls lower
    %     again. These come from the polygon discretization; on a
    %     near-uniform gap (e.g. ex = 0) there are dozens of them.
    %   symmetric repeats: the mesh repeats every 360/N degrees of sweep
    %     (one lobe pitch), and mirroring it about the line of centres maps
    %     sweep angle a to -a, so a minimum at a has twins at +/-a + k*360/N
    %     with the same gap and play. Only one of each set is checked. (The
    %     half-pitch repeat, a + 180/N, swaps the roles of the two rotors,
    %     which changes the play, so it is not folded.)
    % The overall minimum is always kept.
    gaps = gaps(:);
    n = numel(gaps);
    [~, iMin] = min(gaps);
    isMin = (gaps <= circshift(gaps, 1)) & (gaps <= circshift(gaps, -1));
    idx = find(isMin);
    keep = false(size(idx));
    for k = 1:numel(idx)
        i = idx(k);
        keep(k) = (i == iMin) || ...
            min(riseLocal(gaps, i, -1), riseLocal(gaps, i, +1)) > tol;
    end
    idx = idx(keep);
    [~, order] = sort(gaps(idx));
    idx = idx(order);
    period = 360 / nodes;
    cand = [];
    folded = [];
    for k = 1:numel(idx)
        a = mod(idx(k) - 1, period);
        a = min(a, period - a);
        if all(abs(a - folded) > 1.0)
            cand(end+1) = idx(k) - 1;       %#ok<AGROW>
            folded(end+1) = a;              %#ok<AGROW>
        end
    end
end

function r = riseLocal(gaps, i, step)
    % Largest rise above gaps(i) before the gap falls below gaps(i).
    n = numel(gaps);
    top = gaps(i);
    for k = 1:n-1
        g = gaps(mod(i - 1 + step*k, n) + 1);
        if g < gaps(i)
            r = top - gaps(i);
            return;
        end
        top = max(top, g);
    end
    r = Inf;
end

function dev = crossingAngleLocal(xyarray, theta1, theta2_0, ss, dir, max_search)
    % Smallest deviation angle (0..max_search) by which rotor2 can be
    % turned away from theta2_0, with rotor1 held fixed at theta1, before
    % the gap first reaches zero (first contact). The deviation is stepped
    % outward in 0.25 degree increments and the first step that closes the
    % gap is refined by bisection. (Testing only the end of the range is
    % not enough: the rotors can pass through each other and be clear
    % again at max_search.)
    tol  = 1e-3;
    step = 0.25;
    gapAt = @(d) pairGapLocal(xyarray, theta1, theta2_0 + dir*d, ss);
    if gapAt(0) <= 0
        dev = 0;
        return;
    end
    lo = 0;
    while lo < max_search
        hi = min(lo + step, max_search);
        if gapAt(hi) <= 0
            while (hi - lo) > tol
                mid = (lo + hi) / 2;
                if gapAt(mid) > 0
                    lo = mid;
                else
                    hi = mid;
                end
            end
            dev = (lo + hi) / 2;
            return;
        end
        lo = hi;
    end
    dev = max_search;          % no contact within a half lobe pitch
end

function max_dev = findMaxAngleDeviationLocal(xyarray, nodes, ss, ang, limit)
    % At the given synchronized-sweep rotation angle, hold rotor1 fixed and
    % find the smallest single-rotor rotation deviation of rotor2 — in
    % either direction — that closes the gap to zero. This is the angular
    % play (e.g. timing-gear backlash or torsional deflection) the
    % mechanism can tolerate at this position before the rotors interfere.
    % limit (optional, deg): stop searching at this deviation (the result
    % is then limit); used when only a value below a known play matters.
    starta = 0;
    startb = 180 + 180/nodes;
    theta1   = starta + ang;
    theta2_0 = startb - ang;

    max_search = 180 / nodes;      % one half lobe pitch
    if nargin >= 5
        max_search = min(max_search, limit);
    end
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

function R = rootsCompute(nodes, ex, offset, rotor_H, shellgap, ss, points, method, rpm, outlet_d)
    % Core Roots profile computation (no plotting).
    % method:   'averaged' (paper Eqs 5-6, default) or 'noslip' (true rolling)
    % rpm:      rotor speed for flow / velocity
    % outlet_d: discharge opening diameter (mm) for the mean outlet velocity
    % All lengths in mm; flows returned in m^3/min (CMM) in the struct R.
    if nargin < 8 || isempty(method);   method = 'averaged'; end
    if nargin < 9 || isempty(rpm);      rpm = 1000;          end
    if nargin < 10 || isempty(outlet_d); outlet_d = 51;      end
    method = normalizeMethodLocal(method);

    [xyarray, gear_xy, r] = generateProfileLocal(nodes, ex, offset, ss, points, method);

    lobe_w = minLobeWidthLocal(xyarray);
    radii  = hypot(xyarray(:,1), xyarray(:,2));
    lobe_rmax = max(radii);                 % measured from the profile
    lobe_rmin = min(radii);

    % --- Area efficiency ------------------------------------------------
    shell_area = pi * lobe_rmax^2;
    rotor_area = polyarea(xyarray(:,1), xyarray(:,2));
    air_area   = shell_area - rotor_area;
    area_eff   = air_area / shell_area;
    shell_d    = 2 * (lobe_rmax + shellgap);

    % --- Gaps -------------------------------------------------------------
    [min_gap, avg_gap, max_angle_dev] = gapMetricsLocal(xyarray, nodes, ss);
    valid = profileIsSimpleLocal(xyarray(1:end-1,:));
    % Interference: the lobes overlap somewhere in the rotation, or the
    % offset profile crosses itself. Gap, angle and flow values are then
    % meaningless and are reported as 0 (raw values kept in *_raw).
    interfere = (min_gap <= 0) || ~valid;

    % --- Flow at the given RPM (m^3/min) -----------------------------------
    vol_mm3      = 2 * air_area * rotor_H;                          % both rotors, per rev
    gap_area     = avg_gap * 2 * pi * ((lobe_rmax + lobe_rmin) / 2); % avg gap x circumference
    vol_loss_mm3 = gap_area * rotor_H;
    CMM_max  = vol_mm3 * 1e-9 * rpm;
    CMM_loss = vol_loss_mm3 * 1e-9 * rpm;
    CMM_net  = CMM_max - CMM_loss;
    if outlet_d > 0
        velocity_mps = (CMM_net / 60) / (pi * (outlet_d*1e-3)^2 / 4);
    else
        velocity_mps = NaN;
    end

    raw = [min_gap, avg_gap, max_angle_dev];
    if interfere
        min_gap = 0; avg_gap = 0; max_angle_dev = 0;
        CMM_max = 0; CMM_loss = 0; CMM_net = 0; velocity_mps = 0;
    end

    R = struct('method', method, 'offset', offset, 'ss', ss, ...
        'interfere', interfere, 'min_gap_raw', raw(1), ...
        'avg_gap_raw', raw(2), 'max_angle_dev_raw', raw(3),  'r_c', r, 'rpm', rpm, 'outlet_d', outlet_d, ...
        'lobe_rmax', lobe_rmax, 'lobe_rmin', lobe_rmin, 'lobe_w', lobe_w, ...
        'lambda_r', lobe_rmin / lobe_rmax, 'lambda_w', lobe_w / lobe_rmax, ...
        'shell_d', shell_d, 'area_eff', area_eff, ...
        'CMM_max', CMM_max, 'CMM_loss', CMM_loss, 'CMM_net', CMM_net, ...
        'velocity_mps', velocity_mps, ...
        'min_gap', min_gap, 'avg_gap', avg_gap, 'max_angle_dev', max_angle_dev, ...
        'valid', valid);
    R.xy = xyarray;
    R.gear_xy = gear_xy;
end

function m = normalizeMethodLocal(method)
    m = lower(regexprep(char(method), '[\s_\-]', ''));
    if startsWith(m, 'avg') || startsWith(m, 'averaged')
        m = 'averaged';
    elseif startsWith(m, 'noslip')
        m = 'noslip';
    else
        error('Unknown profile method "%s"; use Averaged or Noslip rolling.', method);
    end
end

function [label, fu, vu, fscale, vscale] = unitInfoLocal(units)
    % SI: flow in CMM, velocity in m/s.  Imperial: CFM, ft/min.
    if strcmpi(units, 'Imperial')
        label = 'Imperial'; fu = 'CFM'; vu = 'ft/min';
        fscale = 1 / 0.028316846592;  vscale = 196.8503937007874;
    else
        label = 'SI'; fu = 'CMM'; vu = 'm/s';
        fscale = 1;  vscale = 1;
    end
end

function rows = formatResultsLocal(R, ss, units, kind, isSD)
    % {name, value, style} rows for the Results panel, in three sections.
    % style: 'header' (section title), 'normal', 'solved' (computed from
    % the chosen inputs) or 'bad' (interfering lobes: value shown as 0).
    % Net flow is the last row.
    [label, fu, vu, fs, vs] = unitInfoLocal(units);
    if strcmp(label, 'SI')
        vtxt = sprintf('%.2f %s', R.velocity_mps * vs, vu);
    else
        vtxt = sprintf('%.0f %s', R.velocity_mps * vs, vu);
    end
    bad = 'normal';
    if R.interfere; bad = 'bad'; end
    offStyle = 'normal';
    if ~strcmp(kind, 'offset'); offStyle = 'solved'; end
    ssStyle = 'normal';
    if isSD; ssStyle = 'solved'; end
    rows = { ...
        'Gaps and Angles', '', 'header'; ...
        'Offset',          sprintf('%.3f mm', R.offset), offStyle; ...
        'Min Gap',         sprintf('%.2f mm', R.min_gap), bad; ...
        'Avg Gap',         sprintf('%.2f mm', R.avg_gap), bad; ...
        'Max Angle Dev',   sprintf('%.3f%s', R.max_angle_dev, char(176)), bad; ...
        'Lobe and Shell Geometry', '', 'header'; ...
        'Shaft Spacing',   sprintf('%.2f mm', ss), ssStyle; ...
        'Shell Diameter',  sprintf('%.1f mm', R.shell_d), 'normal'; ...
        'Lobe Rmax',       sprintf('%.1f mm', R.lobe_rmax), 'normal'; ...
        'Lobe Rmin',       sprintf('%.1f mm', R.lobe_rmin), 'normal'; ...
        'Lobe Width',      sprintf('%.1f mm', R.lobe_w), 'normal'; ...
        'Lambda r / w',    sprintf('%.3f / %.3f', R.lambda_r, R.lambda_w), 'normal'; ...
        'Area Efficiency', sprintf('%.3f', R.area_eff), 'normal'; ...
        sprintf('Airflow @ %g RPM', R.rpm), '', 'header'; ...
        'Outlet Velocity', vtxt, bad; ...
        'Flow Loss',       sprintf('%.3f %s', R.CMM_loss * fs, fu), bad; ...
        'Flow Net',        sprintf('%.3f %s', R.CMM_net * fs, fu), bad};
    if isfield(R, 'solve_note') && ~isempty(R.solve_note)
        % The solved-for value missed its target (it jumps past it): red.
        if strcmp(kind, 'min_gap'); rows{3,3} = 'bad'; else; rows{5,3} = 'bad'; end
    end
end

function [label, unit, def, lims, fmt] = inputKindInfoLocal(kind)
    % Design input choices: the offset is entered directly, or solved for
    % to give the entered Min Gap or Max Angle Dev.
    switch kind
        case 'min_gap'
            label = 'Min Gap'; unit = 'mm'; def = 2.0; lims = [0.01 Inf]; fmt = '%.3f';
        case 'max_angle_dev'
            label = 'Max Angle Dev'; unit = 'deg'; def = 3.0; lims = [0.01 90]; fmt = '%.3f';
        otherwise
            label = 'Offset'; unit = 'mm'; def = 2.72; lims = [0.01 Inf]; fmt = '%.3f';
    end
end

function ss = solveSSLocal(nodes, ex, offset, shellgap, shell_d, points, method)
    % Shaft spacing that gives the target shell (housing) diameter.
    target_rmax = shell_d / 2 - shellgap;
    if target_rmax <= 0
        error('Shell diameter too small for shell gap.');
    end
    f = @(ss_val) lobeRmaxFromSS(nodes, ex, offset, ss_val, points, method) - target_rmax;
    ss = fzero(f, [max(2*offset + 1, 5), shell_d * 2]);
end

function [offset, ss, note] = solveOffsetLocal(nodes, ex, kind, target, shellgap, isSD, ss_or_sd, points, method)
    % Offset (and shaft spacing) that gives the target Min Gap (mm) or Max
    % Angle Dev (deg). The smallest offset that reaches the target is
    % found: the bracket is grown from a first guess, then refined by
    % bisection, keeping f(a) < 0 <= f(b) so the result always reaches the
    % target. In Set Shell Diameter mode ss is re-solved for each offset.
    % note is '' or explains why the achieved value is above the target
    % (the value jumps past it).
    note = '';
    ssFor = @(off) ssForOffsetLocal(off, nodes, ex, shellgap, isSD, ss_or_sd, points, method);
    f = @(off) offsetObjectiveLocal(off, nodes, ex, kind, target, ssFor, points, method);
    if strcmp(kind, 'offset')
        offset = target;
        ss = ssFor(offset);
        return;
    end
    [label, unit] = inputKindInfoLocal(kind);
    if target <= 0
        error('%s must be greater than 0.', label);
    end
    if strcmp(kind, 'max_angle_dev') && target >= 180/nodes
        error('Max Angle Dev must be less than half a lobe pitch (%g deg for %d lobes).', ...
              180/nodes, nodes);
    end

    best = -Inf; bestOff = NaN;            % largest value seen, for messages
    if isSD; sz = ss_or_sd / 2; else; sz = ss_or_sd; end
    off_max = 0.45 * sz;
    if strcmp(kind, 'min_gap'); a = target / 2; else; a = 1.0; end
    a = min(max(a, 0.01), off_max);
    [fa, best, bestOff, ua] = evalTrackLocal(f, a, target, best, bestOff);
    if ~(fa >= 0)
        b = a; ub = ua;
        while true
            bn = min(b * 1.5, off_max);
            [fbn, best, bestOff, ubn] = evalTrackLocal(f, bn, target, best, bestOff);
            if fbn >= 0
                b = bn; fb = fbn;
                break;
            end
            if ~ubn && ub
                % The profile breaks down somewhere between b and bn: the
                % target may still be reached just below that point.
                found = false;
                cs = linspace(b, bn, 9);
                for c = cs(2:end-1)
                    [fc, best, bestOff, uc] = evalTrackLocal(f, c, target, best, bestOff);
                    if fc >= 0
                        found = true; break;
                    end
                    if uc; a = c; fa = fc; end
                end
                if found
                    b = c; fb = fc;
                    break;
                end
                error('%s', unreachableMsgLocal(label, unit, target, best, bestOff));
            end
            if bn >= off_max
                error('%s', unreachableMsgLocal(label, unit, target, best, bestOff));
            end
            a = bn; fa = fbn; b = bn; ub = ubn;
        end
    else
        b = a; fb = fa;
        while true
            a = a / 1.5;
            [fa, best, bestOff] = evalTrackLocal(f, a, target, best, bestOff);
            if ~(fa >= 0); break; end
            if a < 1e-3
                offset = a; ss = ssFor(a); return;
            end
            b = a; fb = fa;
        end
    end
    xtol = 1e-3;
    while (b - a) > xtol
        c = (a + b) / 2;
        fc = evalTrackLocal(f, c, target, best, bestOff);
        if ~(fc >= 0)
            a = c; fa = fc;
        else
            b = c; fb = fc;
        end
    end
    offset = b;
    ss = ssFor(offset);
    achieved = fb + target;
    if achieved - target > max(0.02 * target, 0.01)
        note = sprintf(['%s jumps from %.3g to %.3g %s near offset %.3f mm, ' ...
            'so exactly %g %s cannot be reached; the next larger value is used.'], ...
            label, fa + target, achieved, unit, b, target, unit);
    end
end

function [val, best, bestOff, usable] = evalTrackLocal(f, off, target, best, bestOff)
    % f(off). usable is false (and val NaN or -target) if the profile or
    % shaft-spacing solve fails or the profile crosses itself. Tracks the
    % largest achieved value for the "cannot be reached" message.
    try
        [val, usable] = f(off);
    catch
        val = NaN; usable = false;
        return;
    end
    if usable && val + target > best
        best = val + target; bestOff = off;
    end
end

function msg = unreachableMsgLocal(label, unit, target, best, bestOff)
    msg = sprintf('%s of %g %s cannot be reached', label, target, unit);
    if ~isnan(bestOff) && best > 0
        msg = sprintf('%s; the largest found is %.3g %s (offset %.3g mm)', ...
                      msg, best, unit, bestOff);
    end
    msg = [msg '.'];
end

function [val, usable] = offsetObjectiveLocal(off, nodes, ex, kind, target, ssFor, points, method)
    % Achieved Min Gap or Max Angle Dev minus the target, for one offset.
    s  = ssFor(off);
    xy = generateProfileLocal(nodes, ex, off, s, points, method);
    usable = profileIsSimpleLocal(xy(1:end-1,:));
    if ~usable
        val = -target;          % a crossed profile counts as not reached
        return;
    end
    [g, ~, ang] = gapMetricsLocal(xy, nodes, s, ~strcmp(kind, 'min_gap'));
    if strcmp(kind, 'min_gap')
        val = max(g, 0) - target;
    elseif g > 0
        val = ang - target;
    else
        val = -target;
    end
end

function s = ssForOffsetLocal(off, nodes, ex, shellgap, isSD, ss_or_sd, points, method)
    if isSD
        s = solveSSLocal(nodes, ex, off, shellgap, ss_or_sd, points, method);
    else
        s = ss_or_sd;
    end
end

function R = designComputeLocal(nodes, ex, kind, value, rotor_H, shellgap, isSD, ss_or_sd, points, method, rpm, outlet_d)
    % Solve the offset and shaft spacing for the chosen inputs, then run
    % rootsCompute.
    [offset, ss, note] = solveOffsetLocal(nodes, ex, kind, value, shellgap, isSD, ...
                                          ss_or_sd, points, method);
    R = rootsCompute(nodes, ex, offset, rotor_H, shellgap, ss, points, ...
                     method, rpm, outlet_d);
    R.input_kind = kind;
    R.input_value = value;
    R.solve_note = note;
end

function [r, rho_max, rho_min] = rollingRadiusAveragedLocal(nodes, ex, ss)
    % Rolling-circle radius used by the 'averaged' method (unchanged from
    % v0.3): r_c = L / (4 pi N), L = arc length of the conjugate curve
    % ss - rho(theta + pi/N) of the uncorrected base gear (Eq 2 applied to
    % the Eq 1 gear). Kept as-is so existing profiles reproduce exactly.
    a = ss / (1 + sqrt(1 - ex^2));
    theta = linspace(0, 2*pi, 10000);
    cp  = a * (1 - ex^2);
    other_rho = cp ./ (1 - ex * cos(nodes * (-theta + pi/nodes)));
    rho = ss - other_rho;                            % full correction
    x = rho .* cos(theta);
    y = rho .* sin(theta);
    circumference = sum(sqrt(diff(x).^2 + diff(y).^2));
    r = circumference / (4 * nodes * pi);
    rho_max = max(rho);
    rho_min = min(rho);
end

function [xy, r] = rawProfileAveragedLocal(nodes, ex, ss, points)
    % Paper Eqs 5-6: fixed-ratio construction, circle centre on the radial line.
    r = rollingRadiusAveragedLocal(nodes, ex, ss);
    p  = (1:points)';
    th = (p - 1) * (2*pi / points);
    [~, ~, rhoP] = pitchcurveLocal(ss, ex, nodes, th);
    span     = (points+1) / (nodes*2);
    halfspan = (points+1) / (nodes*4);
    dedend   = mod(floor((p + halfspan) / span), 2);

    phi_a = th * (2*nodes + 1);                      % addendum
    Mx_a = (rhoP + r) .* cos(th) + r * cos(phi_a);
    My_a = (rhoP + r) .* sin(th) + r * sin(phi_a);
    phi_d = -th * (2*nodes - 1);                     % dedendum
    Mx_d = (rhoP - r) .* cos(th) - r * cos(phi_d);
    My_d = (rhoP - r) .* sin(th) - r * sin(phi_d);

    isA = (dedend == 0);
    xy = [Mx_d, My_d];
    xy(isA,:) = [Mx_a(isA), My_a(isA)];
end

function [xy, r] = rawProfileNoslipLocal(nodes, ex, ss, points)
    % True rolling without slip of a circle on the rho3 pitch curve: the
    % circle centre lies on the curve normal and the circle turns by
    % +/- ds / r_c. Closure (2N arcs of one full turn) forces
    % r_c = L / (4 pi N), L = arc length of rho3. Output points are
    % uniformly spaced in pitch-curve arc length, starting at the lobe tip.
    dense = 200000;
    th = linspace(0, 2*pi, dense + 1);
    [~, ~, rho] = pitchcurveLocal(ss, ex, nodes, th);
    C  = rho .* exp(1i * th);
    s  = [0, cumsum(abs(diff(C)))];
    L  = s(end);
    r  = L / (4 * pi * nodes);
    dC = gradient(C, th);
    nu = unwrap(angle(dC)) - pi/2;                   % outward normal angle

    su  = (0:points-1)' * L / points;
    Cs  = interp1(s, real(C), su) + 1i * interp1(s, imag(C), su);
    nus = interp1(s, nu, su);
    nh  = exp(1i * nus);

    seg = L / (2 * nodes);                           % one addendum/dedendum arc = 2 pi r
    k   = floor((su + seg/2) / seg);
    sc  = k * seg;
    isA = mod(k, 2) == 0;
    psi = nus + pi - (su - sc) / r;                  % dedendum (inside)
    psi(isA) = nus(isA) + (su(isA) - sc(isA)) / r;   % addendum (outside)
    ctr = Cs - r * nh;
    ctr(isA) = Cs(isA) + r * nh(isA);
    P  = ctr + r * exp(1i * psi);
    xy = [real(P), imag(P)];
end

function xy = offsetPointwiseLocal(xy0, offset)
    % Shift each point by offset along the inward normal estimated from
    % its neighbours (unchanged from v0.3).
    n = size(xy0, 1);
    idx  = (1:n)';
    prev = 1 + mod(idx - 2, n);
    next = 1 + mod(idx, n);
    xi = pi/2 + atan2(xy0(next,2) - xy0(prev,2), xy0(next,1) - xy0(prev,1));
    xy = [xy0(:,1) + offset * cos(xi), xy0(:,2) + offset * sin(xi)];
end

function [ii, tt] = segmentCrossingsLocal(xy, k)
    % Test every segment i of the closed polygon against segment i+k.
    n = size(xy, 1);
    P = xy;
    Q = circshift(xy, -1, 1);
    i = (1:n)';
    j = 1 + mod(i - 1 + k, n);
    d1 = Q(i,:) - P(i,:);
    d2 = Q(j,:) - P(j,:);
    w  = P(j,:) - P(i,:);
    den = d1(:,1).*d2(:,2) - d1(:,2).*d2(:,1);
    t = (w(:,1).*d2(:,2) - w(:,2).*d2(:,1)) ./ den;
    u = (w(:,1).*d1(:,2) - w(:,2).*d1(:,1)) ./ den;
    hit = (den ~= 0) & (t > 0) & (t < 1) & (u > 0) & (u < 1);
    ii = i(hit);
    tt = t(hit);
end

function xy = removeOffsetLoopsLocal(xy, max_span)
    % Trim the small swallow-tail loops an inward offset creates where the
    % radius of curvature is smaller than the offset (e.g. at the cusps of
    % an epicycloid/hypocycloid profile). Loop-free profiles are unchanged.
    for iter = 1:10000
        n = size(xy, 1);
        found = false;
        for k = min(max_span, floor(n/2)):-1:2
            [ii, tt] = segmentCrossingsLocal(xy, k);
            if ~isempty(ii)
                i = ii(1); t = tt(1); found = true;
                break;
            end
        end
        if ~found; return; end
        X = xy(i,:) + t * (xy(1 + mod(i, n),:) - xy(i,:));
        keep = true(n, 1);
        keep(1 + mod(i + (0:k-1), n)) = false;       % points i+1 .. i+k (1-based)
        pos = nnz(keep(1:i));                        % insert after the kept point i
        xk = xy(keep,:);
        xy = [xk(1:pos,:); X; xk(pos+1:end,:)];
    end
end

function ok = profileIsSimpleLocal(xy)
    % True when the closed profile (no repeated end point) does not cross itself.
    n = size(xy, 1);
    ok = true;
    for k = 2:n-2
        if ~isempty(segmentCrossingsLocal(xy, k))
            ok = false;
            return;
        end
    end
end

function xy = startAtTipLocal(xy)
    % Rotate the point list so it starts at the lobe tip on the +x axis.
    ang = abs(atan2(xy(:,2), xy(:,1)));
    rr  = hypot(xy(:,1), xy(:,2));
    [~, i0] = min(ang + (rr < 0.5*max(rr)) * 10);
    xy = circshift(xy, -(i0 - 1), 1);
end

function [xy, gear_xy, r] = generateProfileLocal(nodes, ex, offset, ss, points, method)
    % Offset rotor profile (closed: first point repeated at the end).
    if strcmp(normalizeMethodLocal(method), 'noslip')
        [xy0, r] = rawProfileNoslipLocal(nodes, ex, ss, points);
    else
        [xy0, r] = rawProfileAveragedLocal(nodes, ex, ss, points);
    end
    xy = offsetPointwiseLocal(xy0, offset);
    xy = removeOffsetLoopsLocal(xy, max(4, floor(points / (4*nodes))));
    xy = startAtTipLocal(xy);
    xy(end+1,:) = xy(1,:);

    th = (0:points-1)' * (2*pi / points);
    [gx, gy] = pitchcurveLocal(ss, ex, nodes, th);
    gear_xy = [gx, gy; gx(1), gy(1)];
end

function lobe_w = minLobeWidthLocal(xyarray)
    % Scan-based minimum lobe width: from the lobe tip, walk the y-column
    % to the first local max, then follow it down to the next local min.
    n = size(xyarray, 1) - 1;
    lobe_w = 0;
    p = 2;
    while p <= n && xyarray(p,2) >= xyarray(p-1,2)
        p = p + 1;
    end
    if p <= n
        lobe_w = xyarray(p,2);
        p = p + 1;
    end
    while p <= n && xyarray(p,2) <= lobe_w
        lobe_w = xyarray(p,2);
        p = p + 1;
    end
    lobe_w = lobe_w * 2;
end

function lobe_rmax = lobeRmaxFromSS(nodes, ex, offset, ss, points, method)
    % Profile-measured lobe_rmax for a given ss (no gap analysis).
    % Used by the fzero shell-diameter solver.
    if nargin < 6; method = 'averaged'; end
    xy = generateProfileLocal(nodes, ex, offset, ss, points, method);
    lobe_rmax = max(hypot(xy(:,1), xy(:,2)));
end
