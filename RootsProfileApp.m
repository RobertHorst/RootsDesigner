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
% Two tabs:
%   Interactive — adjust parameters, press Compute, view 6-angle profiles
%   Batch       — load/edit parameter table, Run All, click result row to plot


classdef RootsProfileApp < matlab.apps.AppBase
    properties (Constant)
        VERSION = "0.3.0"
        VERSION_DATE = "2026-07-17"
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
        ModeButtonGroup
        SSRadioBtn
        SDRadioBtn
        LeftTabGroup
        InteractiveTab
        BatchTab

        % --- Interactive tab ---
        LobesSpinner
        ExField
        OffsetField
        RotorHField
        ShellGapField
        SSField                 % holds ss or shell_d depending on mode
        SwitchLabel             % row-6 label that swaps text with mode
        PointsDropDown
        UnitsDropDown
        ComputeButton
        ExportSplineBtn
        StatusLabel
        ResultLabels            % 12x2 cell of {nameLabel, valueLabel}

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
                app.SSField.Limits = [10 1000];
                app.SSField.Value = 130;
                app.BatchInputTable.ColumnName{7} = 'shell_d';
                app.LoadDefaultsBtn.Enable = 'off';
            else
                app.SwitchLabel.Text = 'Shaft Spacing (mm)';
                app.SSField.Limits = [10 300];
                app.SSField.Value = 80.4;
                app.BatchInputTable.ColumnName{7} = 'ss';
                app.LoadDefaultsBtn.Enable = 'on';
            end
            for k = 1:12
                app.ResultLabels{k,2}.Text = char(8212);
            end
            % Clear batch data to avoid misinterpreting column 6
            app.BatchInputTable.Data = {};
            app.BatchResultsTable.Data = [];
            app.BatchXYCache = {};
            paramChanged(app);
        end

        % ---- Unified Compute & Plot ------------------------------------
        function computeAndPlot(app)
            nodes   = app.LobesSpinner.Value;
            ex      = app.ExField.Value;
            offset  = app.OffsetField.Value;
            rotor_H = app.RotorHField.Value;
            sgap    = app.ShellGapField.Value;
            pts     = str2double(app.PointsDropDown.Value);
            units   = app.UnitsDropDown.Value;
            isSD    = app.SDRadioBtn.Value;

            dlg = uiprogressdlg(app.UIFigure, ...
                'Title','Computing', ...
                'Message','Generating profile and analysing gaps...', ...
                'Indeterminate','on');

            try
                if isSD
                    shell_d_target = app.SSField.Value;
                    target_rmax = shell_d_target / 2 - sgap;
                    if target_rmax <= 0
                        error('Shell diameter too small for shell gap.');
                    end
                    dlg.Message = 'Solving for shaft spacing...';
                    f = @(ss_val) lobeRmaxFromSS(nodes,ex,offset, ...
                                      ss_val,pts) - target_rmax;
                    ss_lo = max(2*offset + 1, 5);
                    ss_hi = shell_d_target * 2;
                    ss = fzero(f, [ss_lo, ss_hi]);
                    dlg.Message = 'Running full profile analysis...';
                else
                    ss = app.SSField.Value;
                end

                [lr,lrn,lw,sd,ae,cl,cn,mg,ag,lb,mad,xy,~] = ...
                    rootsCompute(nodes,ex,offset,rotor_H,sgap,ss,pts);

                app.LastXY    = xy;
                app.LastNodes = nodes;
                app.LastSS    = ss;

                fl = flowConvertLocal(cl, units);
                fn = flowConvertLocal(cn, units);

                vals = { ...
                    sprintf('%.2f mm', ss); ...
                    sprintf('%.1f mm', lr); ...
                    sprintf('%.1f mm', lrn); ...
                    sprintf('%.1f mm', lw); ...
                    sprintf('%.1f mm', sd); ...
                    sprintf('%.3f',    ae); ...
                    sprintf('%.3f',    lb); ...
                    sprintf('%.2f mm', mg); ...
                    sprintf('%.2f mm', ag); ...
                    sprintf('%.3f%s',  mad, char(176)); ...
                    sprintf('%.2f %s', fl, units); ...
                    sprintf('%.2f %s', fn, units)};
                for k = 1:12
                    app.ResultLabels{k,2}.Text = vals{k};
                end

                % Highlight Shaft Spacing blue when computed in SD mode
                if isSD
                    app.ResultLabels{1,1}.FontColor = [0.10 0.30 0.70];
                    app.ResultLabels{1,2}.FontColor = [0.10 0.30 0.70];
                else
                    app.ResultLabels{1,1}.FontColor = [0.35 0.35 0.35];
                    app.ResultLabels{1,2}.FontColor = [0 0 0];
                end

                plotProfiles(app, xy, nodes, ss);

                app.StatusLabel.Text = 'Done.';
                app.StatusLabel.FontColor = [0.20 0.60 0.20];
            catch ME
                app.StatusLabel.Text = ['Error: ' ME.message];
                app.StatusLabel.FontColor = [0.85 0.15 0.15];
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
            isSD    = app.SDRadioBtn.Value;
            resData = zeros(nRows, 12);
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
                    if isSD
                        target_rmax = col6 / 2 - sg;
                        if target_rmax <= 0; error('Shell diameter too small.'); end
                        f = @(ss_val) lobeRmaxFromSS(nd,ex,gs, ...
                                          ss_val,pt) - target_rmax;
                        ss_lo = max(2*gs + 1, 5);
                        ss_hi = col6 * 2;
                        shaft = fzero(f, [ss_lo, ss_hi]);
                    else
                        shaft = col6;
                    end
                    [lr,lrn,lw,sd,ae,cl,cn,mg,ag,lb,mad,xy,~] = ...
                        rootsCompute(nd,ex,gs,rh,sg,shaft,pt);
                    fl = flowConvertLocal(cl, units);
                    fn = flowConvertLocal(cn, units);
                    resData(i,:) = [shaft,lr,lrn,lw,sd,ae,fl,fn,mg,ag,mad,lb];
                    app.BatchXYCache{i}   = xy;
                    app.BatchNodeCache(i) = nd;
                    app.BatchSSCache(i)   = shaft;
                catch
                    resData(i,:) = NaN;
                end
            end
            close(dlg);

            app.BatchResultsTable.Data = round(resData, 4);
            app.BatchStatusLabel.Text = ...
                sprintf('Done — %d sets.  Select Plot? then press Plot.', nRows);

            % Auto-plot the row marked Plot? = true
            plotMarkedProfiles(app);
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

            nR = size(defs,1);
            plotCol = num2cell(false(nR,1));
            plotCol{end} = true;                    % last row defaults to Plot
            app.BatchInputTable.Data = [plotCol, num2cell(defs)];
            app.BatchStatusLabel.Text = '20 default rows loaded.';
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
            units = app.UnitsDropDown.Value;
            if app.SDRadioBtn.Value
                col6hdr = 'shell_d_input';
            else
                col6hdr = 'ss_input';
            end
            headers = {'Lobes','ex','offset','rotor_H','shellgap',col6hdr, ...
                'points','ss','lobe_rmax','lobe_rmin','lobe_w','shell_d', ...
                'area_eff',[units '_loss'],[units '_net'], ...
                'min_gap','avg_gap','max_angle_dev_deg','lambda'};
            numInput = cell2mat(cellData(:,2:8));   % skip Plot? column
            T = array2table([numInput, rd], 'VariableNames', headers);
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
            app.UIFigure.Position = [60 60 1460 870];
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
            app.LeftPanel = uigridlayout(app.MainGrid, [2 1]);
            app.LeftPanel.Layout.Row = 1;
            app.LeftPanel.Layout.Column = 1;
            app.LeftPanel.RowHeight = {30, '1x'};
            app.LeftPanel.Padding = [0 0 0 0];
            app.LeftPanel.RowSpacing = 4;

            app.ModeButtonGroup = uibuttongroup(app.LeftPanel, ...
                'BorderType','none', ...
                'BackgroundColor',[0.96 0.96 0.97]);
            app.ModeButtonGroup.Layout.Row = 1;
            app.SSRadioBtn = uiradiobutton(app.ModeButtonGroup, ...
                'Text','Set Shaft Spacing', ...
                'Position',[10 2 160 22], ...
                'Value',true);
            app.SDRadioBtn = uiradiobutton(app.ModeButtonGroup, ...
                'Text','Set Shell Diameter', ...
                'Position',[185 2 170 22]);
            app.ModeButtonGroup.SelectionChangedFcn = ...
                @(~,~) modeChanged(app);

            % ============================================================
            %  LEFT — Tab group (Interactive / Batch)
            % ============================================================
            app.LeftTabGroup = uitabgroup(app.LeftPanel);
            app.LeftTabGroup.Layout.Row = 2;

            % ---------- INTERACTIVE TAB ---------------------------------
            app.InteractiveTab = uitab(app.LeftTabGroup,'Title','Interactive');
            ig = uigridlayout(app.InteractiveTab, [4 1]);
            ig.RowHeight = {'fit', 38, 'fit', '1x'};
            ig.Padding = [6 6 6 6];
            ig.RowSpacing = 8;

            % -- Parameters panel --
            pp = uipanel(ig,'Title','Parameters','FontWeight','bold');
            pp.Layout.Row = 1;
            pg = uigridlayout(pp, [8 2]);
            pg.ColumnWidth = {140, '1x'};
            pg.RowHeight = repmat({28}, 1, 8);
            pg.Padding = [8 6 8 6];
            pg.RowSpacing = 4;

            labs = {'Lobes','Eccentricity (ex)', ...
                'Offset (mm)','Rotor Height (mm)', ...
                'Shell Gap (mm)','Shaft Spacing (mm)', ...
                'Points','Flow Units (@ 1K RPM)'};
            for k = 1:8
                lb = uilabel(pg,'Text',labs{k});
                lb.Layout.Row = k; lb.Layout.Column = 1;
                if k == 6; app.SwitchLabel = lb; end
            end

            chg = @(~,~) paramChanged(app);

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
                'Limits',[0.01 15],'Value',2.72, ...
                'ValueDisplayFormat','%.2f');
            app.OffsetField.Layout.Row = 3;
            app.OffsetField.Layout.Column = 2;
            app.OffsetField.ValueChangedFcn = chg;

            app.RotorHField = uieditfield(pg,'numeric', ...
                'Limits',[1 1000],'Value',100, ...
                'ValueDisplayFormat','%.1f');
            app.RotorHField.Layout.Row = 4;
            app.RotorHField.Layout.Column = 2;
            app.RotorHField.ValueChangedFcn = chg;

            app.ShellGapField = uieditfield(pg,'numeric', ...
                'Limits',[0 20],'Value',2, ...
                'ValueDisplayFormat','%.1f');
            app.ShellGapField.Layout.Row = 5;
            app.ShellGapField.Layout.Column = 2;
            app.ShellGapField.ValueChangedFcn = chg;

            app.SSField = uieditfield(pg,'numeric', ...
                'Limits',[10 300],'Value',80.4, ...
                'ValueDisplayFormat','%.1f');
            app.SSField.Layout.Row = 6;
            app.SSField.Layout.Column = 2;
            app.SSField.ValueChangedFcn = chg;

            app.PointsDropDown = uidropdown(pg, ...
                'Items',{'180','360','720','1001'},'Value','1001');
            app.PointsDropDown.Layout.Row = 7;
            app.PointsDropDown.Layout.Column = 2;
            app.PointsDropDown.ValueChangedFcn = chg;

            app.UnitsDropDown = uidropdown(pg, ...
                'Items',{'CFM','CMM','CMH'},'Value','CMM');
            app.UnitsDropDown.Layout.Row = 8;
            app.UnitsDropDown.Layout.Column = 2;
            app.UnitsDropDown.ValueChangedFcn = chg;

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

            % -- Results panel (12 rows) --
            rp = uipanel(ig,'Title','Results','FontWeight','bold');
            rp.Layout.Row = 3;
            rg = uigridlayout(rp,[12 2]);
            rg.ColumnWidth = {140,'1x'};
            rg.RowHeight = repmat({20},1,12);
            rg.Padding = [8 4 8 4];
            rg.RowSpacing = 2;

            rnames = {'Shaft Spacing','Lobe Rmax','Lobe Rmin','Lobe Width', ...
                'Shell Diameter','Area Efficiency','Lambda', ...
                'Min Gap','Avg Gap','Max Angle Dev','Flow Loss','Flow Net'};
            app.ResultLabels = cell(12,2);
            for k = 1:12
                app.ResultLabels{k,1} = uilabel(rg,'Text',rnames{k}, ...
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
                {'SS','Rmax','Rmin','Width','Shell_D','Area_Eff', ...
                 'Flow_Loss','Flow_Net','Min_Gap','Avg_Gap', ...
                 'Max_Angle_Dev','Lambda'};
            app.BatchResultsTable.ColumnEditable = false(1,12);
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
    % Used by fzero solver in computeAndPlot / runBatch (no gap analysis).
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
