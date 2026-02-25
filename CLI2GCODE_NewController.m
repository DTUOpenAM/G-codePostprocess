%% CLI → Layer-job Post Processor (Netfabb CLI to open LPBF job)
% This script converts a Netfabb-generated *.cli file into a job folder
% containing one text file per layer. Each layer file contains machine
% commands (galvo moves, scan moves, recoater/build piston/dosing commands)
% and ends with a "read next-layer-file" line so the machine controller can
% stream layers sequentially.
%
% Workflow
% 1) User selects a .cli file via file dialog.
% 2) A GUI prompts for:
%    - Per-object process parameters (Active, Power, Feedrate, Crossflow)
%    - Machine dosing strategy (layer-based table)
%    - Mirror X/Y toggles
%    - Advanced settings (galvo scaling, jump speed, recoater interval, etc.)
%    - Processing range (start/stop layer)
% 3) The CLI is parsed and split into $$LAYER sections.
% 4) For each processed layer, a layer file is generated:
%    <jobname>-layer<k>.txt
% 5) A README.txt is written with metadata and settings.
% 6) The job folder is zipped into <jobname>.zip
%
% Output
% - Folder: <jobname>\   (created in current working directory)
%   - <jobname>-layer1.txt
%   - <jobname>-layer2.txt
%   - ...
%   - README.txt
% - Zip: <jobname>.zip
%
% Key assumptions
% - CLI units are read from $$UNITS/<scalar> and applied as a multiplier.
% - Coordinates are scaled to galvo counts:
%     X = (x_mm * scalar * mirror) * scaleFactorX + offset
%     Y = (y_mm * scalar * mirror) * scaleFactorY + offset
%   where offset is typically 32767 (center offset in controller space).
% - Objects are identified by the first value after POLYLINE/ or HATCHES/
%   and mapped to GUI table row = object_number - 1.
%
% Notes
% - Layer indexing and special handling:
%   * Layer 1: initializes crossflow/VFD/oxygen.
%   * Layer 2: dosing only (currently).
%   * Layers >2: full recoating + piston + dosing sequence.
% - Crossflow changes introduce a dummy slow galvo move (~10 s) to allow
%   flow stabilization before scanning resumes.


clear

%% --- Select input file ---
[inputFile, path] = uigetfile('*.cli');
if isequal(inputFile, 0)
    disp('User selected Cancel');
else
    disp(['User selected ', fullfile(path, inputFile)]);
end

% Build full path (critical: uigetfile returns name + folder separately)
cliPath = fullfile(path, inputFile);

%% --- (Legacy / currently unused) ---
customLayerHeight = 50;

%% --- Collect parameters via GUI and process ---
[processParameters, machineParameters, label_matches, mirrorX, mirrorY, recoaterInterval, advancedParams, processingRange, layerHeight] = custom_cli_input(cliPath);
processcli(cliPath, processParameters, machineParameters, mirrorX, mirrorY, label_matches, recoaterInterval, advancedParams, processingRange);


%% ========================================================================
%  Main pipeline
%  ========================================================================

function processcli(inputFile, processParameters, machineParameters, mirrorX, mirrorY, label_matches, recoaterInterval, advancedParams, processingRange)

    %% --- Output folder setup ---
    [~, baseFileName, ~] = fileparts(inputFile);

    folderName = fullfile(pwd, baseFileName);
    if ~exist(folderName, 'dir')
        mkdir(folderName);
    end

    %% --- Read CLI file ---
    cli_data = fileread(inputFile);

    %% --- Constants / controller scaling ---
    scaleFactorX = 203.18;     % Value from LOOP2, 11/11/2024
    scaleFactorY = 203.62;     % Value from LOOP2, 11/11/2024
    powerFactor  = 300;        % 300W laser to percentage

    offsetCounts = 32767;

    jumpSpeed    = advancedParams.jumpSetting * advancedParams.galvoSpeedScale;

    % Dummy‐move parameters for ~10 s delay. d / s ~ 10
    dummySlowSpeed = 5816;     % very slow galvo speed (units/sec)

    maxGalvoX = 59164;
    minGalvoX = 1000;

    %% --- Extract scalar multiplier, layer count, and layer height ---
    unitsPattern = '\$\$UNITS\/(\d+\.?\d*)';
    units = regexp(cli_data, unitsPattern, 'tokens');
    scalar_multiplier = str2double(units{1}{1});

    layersPattern = '\$\$LAYERS\/(\d+\.?\d*)';
    numLayers = regexp(cli_data, layersPattern, 'tokens');
    numLayerCount = str2double(numLayers{1}{1});

    heightPattern = '\$\$LAYER\/(\d+\.?\d*)';
    all_layerHeights = regexp(cli_data, heightPattern, 'tokens');
    layerHeight = (str2num(all_layerHeights{2}{1}) - str2num(all_layerHeights{1}{1})) * scalar_multiplier * 1000;


    %% --- Clamp processing range to available layers ---
    processingRange(1) = max(1, round(processingRange(1)));
    processingRange(2) = min(numLayerCount, round(processingRange(2)));

    if processingRange(2) < processingRange(1)
        processingRange(2) = processingRange(1);
    end

    %% --- Dispenser settings (from GUI) ---
    dispenserValue = machineParameters; %#ok<NASGU>  % kept for compatibility / future use

    %% --- Split CLI data into $$ sections and organize by layer ---
    layerIndices = find(contains(strsplit(cli_data, '\n'), 'LAYER/')); %#ok<NASGU> % kept (legacy)

    layers = cell(numLayerCount, 1);
    segments = strsplit(cli_data, '$$');  % split into sections

    currentLayer = 0;
    for i = 2:length(segments)  % skip preamble (index 1)
        if startsWith(segments{i}, 'LAYER/')
            currentLayer = currentLayer + 1;
        end
        if currentLayer > 0
            layers{currentLayer}{end+1} = segments{i};
        end
    end

    %% --- Mirror handling ---
    if mirrorX
        mirrorHandleX = -1;
    else
        mirrorHandleX = 1;
    end

    if mirrorY
        mirrorHandleY = -1;
    else
        mirrorHandleY = 1;
    end

    %% --- Ensure machineParameters is numeric ---
    if ~isnumeric(machineParameters)
        machineParameters = cellfun(@str2double, machineParameters);
    end

    %% --- Parallel processing of layers ---
    parfor layer_count = processingRange(1):processingRange(2)

        % Initialize gcode for this layer
        gcode_str = '';
        lastLaserPower = NaN;
        lastCrossflow  = NaN;

        fprintf('Processing layer %d of %d...\n', layer_count, processingRange(2));

        %% --- Dispenser schedule lookup for this layer ---
        currentDispenserValue = machineParameters(1,2); % default to Base Dose

        for idx = 1:size(machineParameters, 1)
            if layer_count >= machineParameters(idx, 1)

                % If Pattern Period is nonzero and the layer falls on the period...
                if machineParameters(idx, 3) > 0 && mod(layer_count - machineParameters(idx, 1), machineParameters(idx, 3)) == 0
                    currentDispenserValue = machineParameters(idx, 4);
                else
                    currentDispenserValue = machineParameters(idx, 2);
                end
            end
        end

        %% --- Layer-level commands (recoater/build piston/dosing/init) ---
        if layer_count > 2 && layer_count < numLayerCount

            if mod(layer_count, recoaterInterval) == 0
                gcode_str = [gcode_str sprintf('homerecoater\n')];
            end

            gcode_str = [gcode_str sprintf('movebuildpistonby %d\n', layerHeight)];
            gcode_str = [gcode_str sprintf('moverecoaterto %d\n', advancedParams.recoatTo)];
            gcode_str = [gcode_str sprintf('movebuildpistonby %d\n', advancedParams.pistonRetraction)];
            gcode_str = [gcode_str sprintf('moverecoaterto %d\n', 0)];
            gcode_str = [gcode_str sprintf('movebuildpistonby %d\n', -advancedParams.pistonRetraction - 100)];
            gcode_str = [gcode_str sprintf('movebuildpistonby %d\n', 100)];
            gcode_str = [gcode_str sprintf('movedosingby %d\n', currentDispenserValue)];

        elseif layer_count == 2

            gcode_str = [gcode_str sprintf('movedosingby %d\n', currentDispenserValue)];

        elseif layer_count == 1

            gcode_str = [gcode_str sprintf('setcrossflowfanspeed %.0f\n', 65536 * advancedParams.crossflowSetting / 100)];
            gcode_str = [gcode_str sprintf('setvfdspeed %d\n', advancedParams.VFDsetting)];
            gcode_str = [gcode_str sprintf('setoxygenlevel %.5f\n', advancedParams.oxygenSetting)];

        end

        %% --- Geometry segments for this layer ---
        for j = 1:length(layers{layer_count})
            seg = layers{layer_count}{j};

            % ------------------------------------------------------------
            % POLYLINE/
            % ------------------------------------------------------------
            if startsWith(seg, 'POLYLINE/')
                data = str2double(strsplit(seg(10:end), ','));
                object_number = data(1);

                % Skip if object is inactive
                if ~processParameters{object_number-1, 3}
                    continue;
                end

                % Retrieve this object’s crossflow setting
                crossflow_pct = processParameters{object_number-1, 6};

                % Update crossflow only if changed (+ dummy move)
                if isnan(lastCrossflow) || lastCrossflow ~= crossflow_pct
                    crossflow_val = 65536 * crossflow_pct / 100;
                    gcode_str = [gcode_str sprintf('setcrossflowfanspeed %0.0f\n', crossflow_val)];
   
                    % --- dummy move with laser off ---
                    gcode_str = [gcode_str sprintf('movegalvoto %.f, %.f\n', maxGalvoX, offsetCounts)];
                    gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', dummySlowSpeed)];
                    gcode_str = [gcode_str sprintf('movegalvoto %.f, %.f\n', minGalvoX, offsetCounts)];
                end
                lastCrossflow = crossflow_pct;

                % Coordinates
                x_values = (data(4:2:end-1) * scalar_multiplier * mirrorHandleX) * scaleFactorX + offsetCounts;
                y_values = (data(5:2:end)   * scalar_multiplier * mirrorHandleY) * scaleFactorY + offsetCounts;

                % Process parameters
                power = processParameters{object_number-1, 4} / powerFactor * 100;
                speed = processParameters{object_number-1, 5} * advancedParams.galvoSpeedScale;

                % Laser power: update only if changed
                if isnan(lastLaserPower) || lastLaserPower ~= power
                    gcode_str = [gcode_str sprintf('setlaserpower %0.0f\n', power)];
                end
                lastLaserPower = power;

                % Move (jump), then scan
                gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', jumpSpeed)];
                gcode_str = [gcode_str sprintf('movegalvoto %.f, %.f\n', x_values(1), y_values(1))];
                gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', speed)];

                for i = 2:length(x_values)
                    gcode_str = [gcode_str sprintf('scangalvoto %.f, %.f\n', x_values(i), y_values(i))];
                end

            % ------------------------------------------------------------
            % HATCHES/
            % ------------------------------------------------------------
            elseif startsWith(seg, 'HATCHES/')
                data = str2double(strsplit(seg(9:end), ','));
                object_number = data(1);

                % Skip if object is inactive
                if ~processParameters{object_number-1, 3}
                    continue;
                end

                % Retrieve this object’s crossflow setting
                crossflow_pct = processParameters{object_number-1, 6};

                % Update crossflow only if changed (+ dummy move)
                if isnan(lastCrossflow) || lastCrossflow ~= crossflow_pct
                    crossflow_val = 65536 * crossflow_pct / 100;
                    gcode_str = [gcode_str sprintf('setcrossflowfanspeed %0.0f\n', crossflow_val)];

                    % --- dummy move with laser off ---
                    gcode_str = [gcode_str sprintf('movegalvoto %.f, %.f\n', maxGalvoX, offsetCounts)];
                    gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', dummySlowSpeed)];
                    gcode_str = [gcode_str sprintf('movegalvoto %.f, %.f\n', minGalvoX, offsetCounts)];
                end
                lastCrossflow = crossflow_pct;

                % Coordinates
                x_values = (data(3:2:end-1) * scalar_multiplier * mirrorHandleX) * scaleFactorX + offsetCounts;
                y_values = (data(4:2:end)   * scalar_multiplier * mirrorHandleY) * scaleFactorY + offsetCounts;

                % Process parameters
                power = processParameters{object_number-1, 4} / powerFactor * 100;
                speed = processParameters{object_number-1, 5} * advancedParams.galvoSpeedScale;

                % Laser power: update only if changed
                if isnan(lastLaserPower) || lastLaserPower ~= power
                    gcode_str = [gcode_str sprintf('setlaserpower %0.0f\n', power)];
                end
                lastLaserPower = power;

                % Alternate move/scan pairs
                for i = 1:length(x_values)
                    if mod(i, 2) == 1
                        gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', jumpSpeed)];
                        gcode_str = [gcode_str sprintf('movegalvoto %.f, %.f\n', x_values(i), y_values(i))];
                    else
                        gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', speed)];
                        gcode_str = [gcode_str sprintf('scangalvoto %.f, %.f\n', x_values(i), y_values(i))];
                    end
                end

            % ------------------------------------------------------------
            % GEOMETRYEND
            % ------------------------------------------------------------
            elseif startsWith(seg, 'GEOMETRYEND')
                gcode_str = [gcode_str sprintf('setcrossflowfanspeed 0\n')];
                gcode_str = [gcode_str sprintf('setvfdspeed 0\n')];
                gcode_str = [gcode_str sprintf('setoxygenlevel 0')];
            end
        end

        %% --- Save layer file ---
        save_layer_file(layer_count, gcode_str, baseFileName, folderName, numLayerCount);
    end

    %% --- README + summary ---
    currentDateTime = datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss');

    readmeFilePath = fullfile(folderName, 'README.txt');
    fileID = fopen(readmeFilePath, 'w');

    fprintf(fileID, 'Processing Date and Time: %s\n', currentDateTime);
    fprintf(fileID, '----------------------\n');
    fprintf(fileID, 'Processing Information:\n');
    fprintf(fileID, '----------------------\n');
    fprintf(fileID, 'File Name: %s\n', inputFile);
    fprintf(fileID, 'Total Layers in File: %d\n', numLayerCount);
    fprintf(fileID, 'Processed Layer Range: %d to %d\n', processingRange(1), processingRange(2));
    fprintf(fileID, 'Crossflow Fan Speed: %0.0f%%\n', advancedParams.crossflowSetting);
    fprintf(fileID, 'Dispenser Schedule [StartLayer, BaseDose, PatternPeriod, PatternDose]:\n');
    for r = 1:size(machineParameters, 1)
        fprintf(fileID, '  %d, %d, %d, %d\n', machineParameters(r,1), machineParameters(r,2), machineParameters(r,3), machineParameters(r,4));
    end
    fprintf(fileID, 'Mirror X: %d\n', mirrorX);
    fprintf(fileID, 'Mirror Y: %d\n', mirrorY);

    fprintf(fileID, '\nProcessing Parameters per Object:\n');
    fprintf(fileID, 'Format: Index (Name): Active, Power[W], Feedrate[mm/s], Crossflow[%%]\n');
    for i = 1:size(processParameters, 1)
        fprintf(fileID, 'Object %d (%s): Active=%d, Power=%0.0f W, Feedrate=%0.0f mm/s, Crossflow=%0.0f%%\n', ...
            processParameters{i, 1}, processParameters{i, 2}, ...
            processParameters{i, 3}, processParameters{i, 4}, processParameters{i, 5}, processParameters{i, 6});
    end

    fclose(fileID);

    fprintf('README.txt created in %s\n', folderName);

    fprintf('The print is %d layers and layer height is %d microns\n', numLayerCount-1, layerHeight)
    powderVolume = (250^2*pi/4)*(numLayerCount*layerHeight/1000)/1000000;
    fprintf('The build volume is therefore %0.4fL\n', powderVolume)
    fprintf('Your dosing strategy and print cross-section will affect the actual powder usage\n')

    %% --- Zip output folder ---
    zipFileName = [baseFileName '.zip'];
    zip(zipFileName, folderName);

end



%% ========================================================================
%  File IO helpers
%  ========================================================================

function save_layer_file(layer_num, gcode_data, baseFileName, folderPath, numLayerCount)

    layer_filename = fullfile(folderPath, sprintf('%s-layer%d.txt', baseFileName, layer_num));

    fileID = fopen(layer_filename, 'w');
    fprintf(fileID, '%s', gcode_data);

    if layer_num < numLayerCount
        next_layer_filename = sprintf('read %s-layer%d.txt', baseFileName, layer_num + 1);
        fprintf(fileID, '%s', next_layer_filename);
    end

    fclose(fileID);
end



%% ========================================================================
%  GUI / parameter input
%  ========================================================================

function [processParameters, machineParameters, label_matches, mirrorX, mirrorY, recoaterInterval, advancedParams, processingRange, layerHeight] = custom_cli_input(cli_filename)

    %% --- Read CLI header (first 500 lines) ---
    fid = fopen(cli_filename, 'r');
    lines = {};
    for i = 1:500
        tline = fgetl(fid);
        if ~ischar(tline)
            break;
        end
        lines{end+1} = tline;
    end
    fclose(fid);
    file_content = strjoin(lines, '\n');

    %% --- Extract units, layers, layer height ---
    unitsPattern = '\$\$UNITS\/(\d+\.?\d*)';
    units = regexp(file_content, unitsPattern, 'tokens');
    scalar_multiplier = str2double(units{1}{1});

    layersPattern = '\$\$LAYERS\/(\d+\.?\d*)';
    numLayersTokens = regexp(file_content, layersPattern, 'tokens');
    totalLayers = str2double(numLayersTokens{1}{1});

    heightPattern = '\$\$LAYER\/(\d+\.?\d*)';
    all_layerHeights = regexp(file_content, heightPattern, 'tokens');
    layerHeight = (str2num(all_layerHeights{2}{1}) - str2num(all_layerHeights{1}{1})) * scalar_multiplier * 1000;

    %% --- Extract object labels ---
    label_matches = regexp(file_content, '\$\$LABEL/(\d+),([^,\n\r]+)', 'tokens');
    label_matches = label_matches(2:end);

    %% --- Build GUI ---
    fig = uifigure('Name', 'Enter Parameters', 'Position', [100 100 700 600]);
    tgroup = uitabgroup(fig, 'Position', [10 10 680 580]);

    % -----------------------------
    % Process Parameters tab
    % -----------------------------
    processTab = uitab(tgroup, 'Title', 'Process Parameters');

    instructionTextProcess = ['Enter process parameters for each object to be processed. ' ...
        'Please ensure that suitable parameters for each materials and object. ' ...
        'It is recommended to use clear and descriptive names for each object in Netfabb. ' ...
        'The Machine Settings contain dosing and layer height information. ' ...
        'When finished, press Submit and a gcode will be created.'];
    uilabel(processTab, 'Text', instructionTextProcess, 'Position', [10, 450, 660, 100], ...
        'HorizontalAlignment', 'center', 'WordWrap', 'on');

    powderVolume = (250^2*pi/4)*(totalLayers*layerHeight/1000)/1000000;

    metadataText = sprintf(['Filename: %s\n', ...
        'Layer Height: %d microns\n', ...
        'Total Layers: %d\n', ...
        'The Build Volume is %.3fL\n', ...
        'Printer: LOOP2\n', ...
        'Post Processor Version: v3.0'], ...
        cli_filename, layerHeight, totalLayers, powderVolume);

    metadataPanel = uipanel(processTab, 'Title', 'Print Metadata', 'Position', [650, 200, 90, 250]);
    uilabel(metadataPanel, 'Text', metadataText, 'Position', [5, -20, 80, 250], ...
        'HorizontalAlignment', 'left', 'VerticalAlignment', 'top', 'WordWrap', 'on');

    % Columns: Index, Object, Active, Power [W], Feedrate [mm/s], Cross Flow [%]
    tableData = cell(numel(label_matches), 6);
    for i = 1:numel(label_matches)
        tableData{i, 1} = i+1;
        tableData{i, 2} = label_matches{i}{2};
        tableData{i, 3} = true;
        [power_sug, feedrate_sug] = suggest_parameters(label_matches{i}{2}, layerHeight);
        tableData{i, 4} = power_sug;
        tableData{i, 5} = feedrate_sug;
        tableData{i, 6} = 70;
    end

    processTable = uitable(processTab, ...
        'Data', tableData, ...
        'ColumnName', {'','Object','Active','Power [W]','Feedrate [mm/s]','Cross Flow [%]'}, ...
        'ColumnEditable', [false false true true true true], ...
        'RowName', [], ...
        'Position', [10, 50, 620, 300]);

    %%% New
    % --- Excel roundtrip (kun ProcessParameters) ---
    lastExcelPath = pwd;
    lastExcelFile = fullfile(lastExcelPath, 'process_params.xlsx');

    uibutton(processTab, 'Text','Export to Excel', ...
        'Position',[10, 10, 120, 30], ...
        'ButtonPushedFcn', @(~,~) exportToExcelCb());

    uibutton(processTab, 'Text','Open in Excel', ...
        'Position',[140, 10, 120, 30], ...
        'ButtonPushedFcn', @(~,~) openInExcelCb());

    uibutton(processTab, 'Text','Import from Excel', ...
        'Position',[270, 10, 140, 30], ...
        'ButtonPushedFcn', @(~,~) importFromExcelCb());

    function exportToExcelCb()
        procT = processTableToTable(processTable);

        [f,p] = uiputfile('*.xlsx','Save Process Parameters as', lastExcelFile);
        if isequal(f,0); return; end
        lastExcelFile = fullfile(p,f); lastExcelPath = p;

        writetable(procT, lastExcelFile, 'Sheet','ProcessParameters');
        uialert(fig, sprintf('Saved:\n%s', lastExcelFile), 'Export OK', 'Icon','success');
    end

    function openInExcelCb()
        if ~isfile(lastExcelFile)
            uialert(fig,'No Excel file yet. Do an export first.','Open in Excel');
            return;
        end
        if ispc
            winopen(lastExcelFile);
        elseif ismac
            system(sprintf('open "%s" &', lastExcelFile));
        else
            system(sprintf('xdg-open "%s" &', lastExcelFile));
        end
    end

    function importFromExcelCb()
        [f,p] = uigetfile('*.xlsx','Select edited Excel', lastExcelPath);
        if isequal(f,0); return; end
        xfile = fullfile(p,f);
        try
            T = readtable(xfile, 'Sheet','ProcessParameters');
        catch
            uialert(fig,'Could not read sheet "ProcessParameters".','Import error','Icon','error');
            return;
        end

        required = {'Index','Object','Active','Power_W','Feedrate_mm_s','CrossFlow_pct'};
        missing = setdiff(required, T.Properties.VariableNames);
        if ~isempty(missing)
            uialert(fig, sprintf('Missing columns:\n%s', strjoin(missing, ', ')), ...
                'Import error','Icon','error');
            return;
        end

        T.Index         = double(T.Index);
        T.Object        = string(T.Object);
        if ~islogical(T.Active)
            if iscell(T.Active) || isstring(T.Active)
                T.Active = ismember(upper(string(T.Active)), ["1","TRUE","YES","X"]);
            else
                T.Active = logical(T.Active);
            end
        end
        T.Power_W       = double(T.Power_W);
        T.Feedrate_mm_s = double(T.Feedrate_mm_s);
        T.CrossFlow_pct = double(T.CrossFlow_pct);

        processTable.Data = [ ...
            num2cell(T.Index), cellstr(T.Object), num2cell(T.Active), ...
            num2cell(T.Power_W), num2cell(T.Feedrate_mm_s), num2cell(T.CrossFlow_pct) ];

        uialert(fig, 'Imported edited values from Excel.', 'Import OK', 'Icon','success');
    end

    function T = processTableToTable(ut)
        D = ut.Data;
        idx  = double([D{:,1}].');
        obj  = string(D(:,2));
        actv = logical([D{:,3}].');
        pwr  = double([D{:,4}].');
        fr   = double([D{:,5}].');
        cfl  = double([D{:,6}].');

        T = table(idx, obj, actv, pwr, fr, cfl, ...
            'VariableNames', {'Index','Object','Active','Power_W','Feedrate_mm_s','CrossFlow_pct'});
    end
    %%% New

    uilabel(processTab, 'Text', 'Process Range:', ...
        'Position', [10, 420, 250, 22], 'HorizontalAlignment', 'center', 'WordWrap', 'on');

    uilabel(processTab, 'Text', 'Start Layer:', 'Position', [10, 390, 100, 22]);
    startLayerField = uieditfield(processTab, 'numeric', 'Position', [120, 390, 100, 22], 'Value', 1);

    uilabel(processTab, 'Text', 'Stop Layer:', 'Position', [250, 390, 100, 22]);
    stopLayerField = uieditfield(processTab, 'numeric', 'Position', [360, 390, 100, 22], 'Value', totalLayers);

    % -----------------------------
    % Machine Settings tab
    % -----------------------------
    machineTab = uitab(tgroup, 'Title', 'Machine Settings');

    instructionTextMachine = ['Dispenser signifies the amount of powder. ' ...
        'To change the dosing throughout the print, enter the start layer ' ...
        'and the chosen amount.'];
    uilabel(machineTab, 'Text', instructionTextMachine, 'Position', [10, 450, 660, 100], ...
        'HorizontalAlignment', 'center', 'WordWrap', 'on');

    dispenserTableData = [1, 400, 0, 0];
    dispenserTable = uitable(machineTab, 'Data', dispenserTableData, ...
        'ColumnName', {'Start Layer', 'Base Dose', 'Pattern Period', 'Pattern Dose'}, ...
        'ColumnEditable', [true true true true], ...
        'RowName', [], ...
        'Position', [10, 250, 300, 100]);

    uibutton(machineTab, 'push', 'Text', 'Add Row', ...
        'Position', [320, 250, 100, 30], ...
        'ButtonPushedFcn', @(btn, event) addRowCallback());

    function addRowCallback()
        currentData = dispenserTable.Data;
        if isempty(currentData)
            newData = [1, 400, 0, 0];
        else
            newStartLayer = currentData(end, 1) + 1;
            newData = [newStartLayer, 400, 0, 0];
        end
        dispenserTable.Data = [currentData; newData];
    end

    uibutton(machineTab, 'push', 'Text', 'Remove Row', ...
        'Position', [320, 210, 100, 30], ...
        'ButtonPushedFcn', @(btn, event) removeRowCallback());

    function removeRowCallback()
        currentData = dispenserTable.Data;
        if isempty(currentData)
            return;
        end
        if isprop(dispenserTable, 'SelectedRows') && ~isempty(dispenserTable.SelectedRows)
            selectedRows = dispenserTable.SelectedRows;
            currentData(selectedRows, :) = [];
            dispenserTable.Data = currentData;
            dispenserTable.SelectedRows = [];
        else
            currentData(end, :) = [];
            dispenserTable.Data = currentData;
        end
    end

    mirrorXCheckbox = uicheckbox(machineTab, 'Text', 'Mirror X', 'Position', [10, 200, 100, 22]);
    mirrorXCheckbox.Value = true;

    mirrorYCheckbox = uicheckbox(machineTab, 'Text', 'Mirror Y', 'Position', [10, 170, 100, 22]);

    % -----------------------------
    % Advanced tab
    % -----------------------------
    advancedTab = uitab(tgroup, 'Title', 'Advanced');

    uilabel(advancedTab, 'Text', 'Galvo Speed Scale Factor (avg. X and Y):', ...
        'Position', [10, 450, 200, 22]);
    galvoScaleField = uieditfield(advancedTab, 'numeric', ...
        'Position', [220, 450, 100, 22], 'Value', 203.4);

    uilabel(advancedTab, 'Text', 'Recoater Movement:', ...
        'Position', [10, 400, 200, 22]);
    recoatField = uieditfield(advancedTab, 'numeric', ...
        'Position', [220, 400, 100, 22], 'Value', 450);

    uilabel(advancedTab, 'Text', 'Build Piston Retraction:', ...
        'Position', [10, 350, 200, 22]);
    pistonRetractionField = uieditfield(advancedTab, 'numeric', ...
        'Position', [220, 350, 100, 22], 'Value', 600);

    uilabel(advancedTab, 'Text', 'Crossflow Fan:', ...
        'Position', [10, 300, 200, 22]);
    crossflowField = uieditfield(advancedTab, 'numeric', ...
        'Position', [220, 300, 100, 22], 'Value', 70);

    uilabel(advancedTab, 'Text', 'VFD Setting:', ...
        'Position', [10, 250, 200, 22]);
    VFDField = uieditfield(advancedTab, 'numeric', ...
        'Position', [220, 250, 100, 22], 'Value', 55);

    uilabel(advancedTab, 'Text', 'Oxygen Setting:', ...
        'Position', [10, 200, 200, 22]);
    oxygenField = uieditfield(advancedTab, 'numeric', ...
        'Position', [220, 200, 100, 22], 'Value', 0.1);

    uilabel(advancedTab, 'Text', 'Jump Speed:', ...
        'Position', [10, 150, 200, 22]);
    jumpSpeedField = uieditfield(advancedTab, 'numeric', ...
        'Position', [220, 150, 100, 22], 'Value', 3000);

    uilabel(advancedTab, 'Text', 'Recoater Home Interval (layers):', ...
        'Position', [10, 100, 180, 22]);
    recoaterField = uieditfield(advancedTab, 'numeric', ...
        'Position', [220, 100, 100, 22], 'Value', 200);

    % -----------------------------
    % Submit
    % -----------------------------
    submitButton = uibutton(fig, 'push', 'Text', 'Submit', 'Position', [300, 10, 100, 30], ...
        'ButtonPushedFcn', @(btn, event) onSubmit()); %#ok<NASGU>

    processParameters = [];
    machineParameters = [];

    uiwait(fig);

    function onSubmit()
        processParameters = processTable.Data;

        machineParameters = dispenserTable.Data;
        machineParameters = sortrows(machineParameters, 1);

        mirrorX = mirrorXCheckbox.Value;
        mirrorY = mirrorYCheckbox.Value;

        advancedParams.galvoSpeedScale   = galvoScaleField.Value;
        advancedParams.recoatTo          = recoatField.Value;
        advancedParams.pistonRetraction  = pistonRetractionField.Value;
        advancedParams.crossflowSetting  = crossflowField.Value;
        advancedParams.VFDsetting        = VFDField.Value;
        advancedParams.oxygenSetting     = oxygenField.Value;
        advancedParams.jumpSetting       = jumpSpeedField.Value;

        recoaterInterval = recoaterField.Value;
        processingRange  = [startLayerField.Value, stopLayerField.Value];

        delete(fig);
    end
end



%% ========================================================================
%  Parameter suggestion
%  ========================================================================

function [power, feedrate] = suggest_parameters(object_name, layerHeight)

    if layerHeight > 45 && layerHeight < 55
        power    = 250;
        feedrate = 2000;

        if contains(object_name, '(Filling)', 'IgnoreCase', true)
            power = 190; feedrate = 950;

        elseif contains(object_name, '(Support)', 'IgnoreCase', true)
            power = 250; feedrate = 1100;

        elseif contains(object_name, '(SolidSupport)', 'IgnoreCase', true)
            power = 190; feedrate = 950;

        elseif contains(object_name, 'Overhang', 'IgnoreCase', true)
            power = 175; feedrate = 4000;
        end

    elseif layerHeight > 25 && layerHeight < 35
        power    = 120;
        feedrate = 1500;

        if contains(object_name, '(Filling)', 'IgnoreCase', true)
            power = 190; feedrate = 1500;

        elseif contains(object_name, '(Support)', 'IgnoreCase', true)
            power = 250; feedrate = 2200;

        elseif contains(object_name, '(SolidSupport)', 'IgnoreCase', true)
            power = 190; feedrate = 1500;

        elseif contains(object_name, 'Overhang', 'IgnoreCase', true)
            power = 175; feedrate = 4000;
        end
    end
end