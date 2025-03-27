clear

[inputFile, path] = uigetfile('*.cli');
if isequal(inputFile, 0)
   disp('User selected Cancel');
else
   disp(['User selected ', fullfile(path, inputFile)]);
end

customLayerHeight = 50;

[processParameters, machineParameters, label_matches, mirrorX, mirrorY, recoaterInterval, advancedParams, processingRange, layerHeight] = custom_cli_input(inputFile);
processcli(inputFile, processParameters, machineParameters, mirrorX, mirrorY, label_matches, recoaterInterval, advancedParams, processingRange);



function processcli(inputFile, processParameters, machineParameters, mirrorX, mirrorY, label_matches, recoaterInterval, advancedParams, processingRange)
    % Extract the base filename without the extension
    [~, baseFileName, ~] = fileparts(inputFile);
    
    % Create a folder named after the base filename
    folderName = fullfile(pwd, baseFileName);
    if ~exist(folderName, 'dir')
        mkdir(folderName);
    end

    cli_data = fileread(inputFile);
    
    scaleFactorX = 203.18;   % Value from LOOP2, 11/11/2024
    scaleFactorY = 203.62;   % Value from LOOP2, 11/11/2024
    
    powerFactor = 300;      % 300W laser to percentage
    
    jumpSpeed = advancedParams.jumpSetting*advancedParams.galvoSpeedScale;
    
    % Extract the scalar multiplier from the CLI file
    unitsPattern = '\$\$UNITS\/(\d+\.?\d*)';
    units = regexp(cli_data, unitsPattern, 'tokens');
    scalar_multiplier = str2double(units{1}{1});

    % Extract the layer count from the CLI file
    layersPattern = '\$\$LAYERS\/(\d+\.?\d*)';
    numLayers = regexp(cli_data, layersPattern, 'tokens');
    numLayerCount = str2double(numLayers{1}{1});

    % Extract the layer height from the CLI file
    heightPattern = '\$\$LAYER\/(\d+\.?\d*)';
    all_layerHeights = regexp(cli_data, heightPattern, 'tokens');
    layerHeight = (str2num(all_layerHeights{2}{1}) - str2num(all_layerHeights{1}{1})) * scalar_multiplier * 1000;

    % Extract the dispenser setting
    dispenserValue = machineParameters;

    % Split the CLI file data by layers
    layerIndices = find(contains(strsplit(cli_data, '\n'), 'LAYER/'));
    
    % Create a cell array to hold the segments for each layer
    layers = cell(numLayerCount, 1);
    segments = strsplit(cli_data, '$$');  % Split into sections

    % Organize the segments into layers
    currentLayer = 0;
    for i = 2:length(segments)  % Skip preamble (index 1)
        if startsWith(segments{i}, 'LAYER/')
            currentLayer = currentLayer + 1;
        end
        if currentLayer > 0
            layers{currentLayer}{end+1} = segments{i};
        end
    end

    if mirrorX
        mirrorHandleX = -1;  % Apply mirroring to the X positions
    else
        mirrorHandleX = 1;
    end

    if mirrorY
        mirrorHandleY = -1;  % Apply mirroring to the Y positions
    else
        mirrorHandleY = 1;
    end


    if ~isnumeric(machineParameters)
    machineParameters = cellfun(@str2double, machineParameters);
    end

    % Parallel processing of layers using parfor
    parfor layer_count = processingRange(1):processingRange(2)
        % Initialize gcode for this layer
        gcode_str = '';
        lastLaserPower = NaN;

        % Output the current layer being processed
        fprintf('Processing layer %d of %d...\n', layer_count, processingRange(2));

        
        % Initialize with the settings from the first row
        currentDispenserValue = machineParameters(1,2); % Default to Base Dose
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

        
        % Handle layer-specific commands
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
            gcode_str = [gcode_str sprintf('setcrossflowfanspeed %0.0f\n', 65536 * advancedParams.crossflowSetting / 100)];
            gcode_str = [gcode_str sprintf('setvfdspeed %d\n', advancedParams.VFDsetting)];
            gcode_str = [gcode_str sprintf('setoxygenlevel %f0.1\n', advancedParams.oxygenSetting)];
        end





        % Process the segments for this layer
        for j = 1:length(layers{layer_count})
            seg = layers{layer_count}{j};
            if startsWith(seg, 'POLYLINE/')
                data = str2double(strsplit(seg(10:end), ','));
                object_number = data(1);

                % Check if this object is active. If not, skip processing this segment.
                if ~processParameters{object_number-1, 3}
                    continue;
                end

                x_values = (data(4:2:end-1) * scalar_multiplier * mirrorHandleX) * scaleFactorX + 32767;
                y_values = (data(5:2:end) * scalar_multiplier * mirrorHandleY) * scaleFactorY + 32767;

                % Use the processParameters and label_matches to dynamically set power or speed
                power = processParameters{object_number-1, 4}/powerFactor*100;  % Get power for this object
                speed = processParameters{object_number-1, 5}*advancedParams.galvoSpeedScale;  % Get speed for this object

                
                % Setting Processing settings
                %gcode_str = [gcode_str sprintf('setlaserpower %0.0f\n', power)];
                % Only update the laser power if it has changed
                if isnan(lastLaserPower) || lastLaserPower ~= power
                    gcode_str = [gcode_str sprintf('setlaserpower %0.0f\n', power)];
                    lastLaserPower = power;
                end

                %gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', speed)];

                %gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', jumpSpeed)];

                gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', advancedParams.jumpSetting*advancedParams.galvoSpeedScale)];
                gcode_str = [gcode_str sprintf('movegalvoto %.f, %.f\n', x_values(1), y_values(1))];
                gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', speed)];
                
                for i = 2:length(x_values)
                    gcode_str = [gcode_str sprintf('scangalvoto %.f, %.f\n', x_values(i), y_values(i))];
                end
            
            elseif startsWith(seg, 'HATCHES/')
                data = str2double(strsplit(seg(9:end), ','));
                object_number = data(1);

                % Skip processing if this object is turned off.
                if ~processParameters{object_number-1, 3}
                    continue;
                end
                
                x_values = (data(3:2:end-1) * scalar_multiplier * mirrorHandleX) * scaleFactorX + 32767;
                y_values = (data(4:2:end) * scalar_multiplier * mirrorHandleY) * scaleFactorY + 32767;

                % Apply the process parameters based on object label
                power = processParameters{object_number-1, 4}/powerFactor*100;  % Power for hatches
                speed = processParameters{object_number-1, 5}*advancedParams.galvoSpeedScale;  % Speed for hatches

                %gcode_str = [gcode_str sprintf('setlaserpower %0.0f\n', power)];
                % Only update the laser power if it has changed
                if isnan(lastLaserPower) || lastLaserPower ~= power
                    gcode_str = [gcode_str sprintf('setlaserpower %0.0f\n', power)];
                    lastLaserPower = power;
                end
                %gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', speed)];

                for i = 1:length(x_values)
                    if mod(i, 2) == 1
                        gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', advancedParams.jumpSetting*advancedParams.galvoSpeedScale)];
                        gcode_str = [gcode_str sprintf('movegalvoto %.f, %.f\n', x_values(i), y_values(i))];
                    else
                        gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', speed)];
                        gcode_str = [gcode_str sprintf('scangalvoto %.f, %.f\n', x_values(i), y_values(i))];
                    end
                end

            elseif startsWith(seg, 'GEOMETRYEND')
                gcode_str = [gcode_str sprintf('setcrossflowfanspeed 0\n')];
                gcode_str = [gcode_str sprintf('setvfdspeed 0\n')];
                gcode_str = [gcode_str sprintf('setoxygenlevel 0')];
            end
        end

        % Save the current layer G-code and reference to the next file
        save_layer_file(layer_count, gcode_str, baseFileName, folderName, numLayerCount);
    end

            % Get the current date and time
            currentDateTime = datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss');

                % Create the README file inside the folder
            readmeFilePath = fullfile(folderName, 'README.txt');
            fileID = fopen(readmeFilePath, 'w');
            

            % Write metadata into the README file
            fprintf(fileID, 'Processing Date and Time: %s\n', currentDateTime);
            fprintf(fileID, '----------------------\n');
            fprintf(fileID, 'Processing Information:\n');
            fprintf(fileID, '----------------------\n');
            fprintf(fileID, 'File Name: %s\n', inputFile);
            fprintf(fileID, 'Total Layers in File: %d\n', numLayerCount);
            fprintf(fileID, 'Processed Layer Range: %d to %d\n', processingRange(1), processingRange(2));
            fprintf(fileID, 'Crossflow Fan Speed: %0.0f%%\n', advancedParams.crossflowSetting);
            fprintf(fileID, 'Dispenser Value: %s\n', machineParameters);
            fprintf(fileID, 'Mirror X: %d\n', mirrorX);
            fprintf(fileID, 'Mirror Y: %d\n', mirrorY);
            
            % Optional: Write any other metadata or specific settings
            fprintf(fileID, '\nProcessing Parameters per Object:\n');
            for i = 1:size(processParameters, 1)
                fprintf(fileID, 'Object %d (%s): Power = %0.0f W, Feedrate = %0.0f mm/s\n', processParameters{i, 1}, processParameters{i, 2}, processParameters{i, 3}, processParameters{i, 4});

            end
            
            % Close the file
            fclose(fileID);
            
            % Display a message when README is created
            fprintf('README.txt created in %s\n', folderName);

            fprintf('The print is %d layers and layer height is %d microns\n', numLayerCount-1, layerHeight)
            powderVolume = (250^2*pi/4)*(numLayerCount*layerHeight/1000)/1000000;
            fprintf('The build volume is therefore %0.4fL\n', powderVolume)
            fprintf('Your dosing strategy and print cross-section will affect the actual powder usage\n')


        % Zip the folder after all layers are saved
    zipFileName = [baseFileName '.zip'];
    zip(zipFileName, folderName);

end

% Function to save the current layer G-code to its own file
function save_layer_file(layer_num, gcode_data, baseFileName, folderPath, numLayerCount)
    % Create the filename for the current layer inside the folder
    layer_filename = fullfile(folderPath, sprintf('%s_layer-%d.txt', baseFileName, layer_num));

    % Open file and write G-code
    fileID = fopen(layer_filename, 'w');
    fprintf(fileID, '%s', gcode_data);

    % If this is not the final layer, append the reference to the next layer
    if layer_num < numLayerCount
        next_layer_filename = sprintf('read %s_layer-%d.txt', baseFileName, layer_num + 1);
        fprintf(fileID, '%s', next_layer_filename);
    end

    fclose(fileID);
end




function [processParameters, machineParameters, label_matches, mirrorX, mirrorY, recoaterInterval, advancedParams, processingRange, layerHeight] = custom_cli_input(cli_filename)
    
    % Instead of reading the entire file, read only the first 200 lines
    fid = fopen(cli_filename, 'r');
    lines = {};
    for i = 1:200
        tline = fgetl(fid);
        if ~ischar(tline)
            break;
        end
        lines{end+1} = tline;
    end
    fclose(fid);
    file_content = strjoin(lines, '\n');

    % Extract the scalar multiplier from the CLI file
    unitsPattern = '\$\$UNITS\/(\d+\.?\d*)';
    units = regexp(file_content, unitsPattern, 'tokens');
    scalar_multiplier = str2double(units{1}{1});

    % Extract total number of layers from the CLI file
    layersPattern = '\$\$LAYERS\/(\d+\.?\d*)';
    numLayersTokens = regexp(file_content, layersPattern, 'tokens');
    totalLayers = str2double(numLayersTokens{1}{1});

    % Extract the layer height from the CLI file
    heightPattern = '\$\$LAYER\/(\d+\.?\d*)';
    all_layerHeights = regexp(file_content, heightPattern, 'tokens');
    layerHeight = (str2num(all_layerHeights{2}{1}) - str2num(all_layerHeights{1}{1})) * scalar_multiplier * 1000;

    % Extract labels and their names
    label_matches = regexp(file_content, '\$\$LABEL/(\d+),([^,\n\r]+)', 'tokens');
    label_matches = label_matches(2:end);

    % Create a figure for the custom GUI dialog
    fig = uifigure('Name', 'Enter Parameters', 'Position', [100 100 700 600]);

    % Create a tab group
    tgroup = uitabgroup(fig, 'Position', [10 10 680 580]);

    % Create the "Process Parameters" tab
    processTab = uitab(tgroup, 'Title', 'Process Parameters');

    % Add instructional text for the "Process Parameters" tab
    instructionTextProcess = ['Enter process parameters for each object to be processed. ' ...
        'Please ensure that suitable parameters for each materials and object. ' ...
        'It is recommended to use clear and descriptive names for each object in Netfabb. ' ...
        'The Machine Settings contain dosing and layer height information. ' ...
        'When finished, press Submit and a gcode will be created.'];
    uilabel(processTab, 'Text', instructionTextProcess, 'Position', [10, 450, 660, 100], 'HorizontalAlignment', 'center', 'WordWrap', 'on');

    % Create a metadata string
    metadataText = sprintf(['Filename: %s\n', ...
                        'Layer Height: %d microns\n', ...
                        'Total Layers: %d\n', ...
                        'Printer: LOOP2\n', ...
                        'Post Processor Version: v3.0'], ...
                        cli_filename, layerHeight, totalLayers);
                    
    % Create a panel on the right side of the Process Parameters tab for metadata
    % Adjust the Position: [left, bottom, width, height]
    metadataPanel = uipanel(processTab, 'Title', 'Print Metadata', 'Position', [580, 200, 90, 250]);
    uilabel(metadataPanel, 'Text', metadataText, 'Position', [5, -20, 80, 250], ...
    'HorizontalAlignment', 'left', 'VerticalAlignment', 'top', 'WordWrap', 'on');

    % Prepare the data for the table with an added "Active" column (default true)
    tableData = cell(numel(label_matches), 5); % Columns: Index, Object, Active, Power, Feedrate
    for i = 1:numel(label_matches)
        tableData{i, 1} = i+1;
        tableData{i, 2} = label_matches{i}{2}; % Object (Label Name)
        tableData{i, 3} = true;              % Active flag (checkbox) – true by default
        [power_sug, feedrate_sug] = suggest_parameters(label_matches{i}{2}, layerHeight);
        tableData{i, 4} = power_sug;         % Default Power
        tableData{i, 5} = feedrate_sug;        % Default Feedrate
    end
    
    % Create the table in the "Process Parameters" tab with the new "Active" column.
    processTable = uitable(processTab, 'Data', tableData, ...
                           'ColumnName', {'', 'Object', 'Active', 'Power [W]', 'Feedrate [mm/s]'}, ...
                           'ColumnEditable', [false false true true true], ...
                           'RowName', [], ...
                           'Position', [10 50 560 300]);


    uilabel(processTab, 'Text', 'Process Range:', ...
    'Position', [10, 420, 250, 22], 'HorizontalAlignment', 'center', 'WordWrap', 'on');
    
    % Field for Start Layer (default is 1)
    uilabel(processTab, 'Text', 'Start Layer:', 'Position', [10, 390, 100, 22]);
    startLayerField = uieditfield(processTab, 'numeric', 'Position', [120, 390, 100, 22], 'Value', 1);
    
    % Field for Stop Layer (default is totalLayers from the file)
    uilabel(processTab, 'Text', 'Stop Layer:', 'Position', [250, 390, 100, 22]);
    stopLayerField = uieditfield(processTab, 'numeric', 'Position', [360, 390, 100, 22], 'Value', totalLayers);


    % Create the "Machine Settings" tab
    machineTab = uitab(tgroup, 'Title', 'Machine Settings');

    % Add instructional text for the "Machine Settings" tab
    instructionTextMachine = ['Dispenser signifies the amount of powder. ' ...
                              'To change the dosing throughout the print, enter the start layer ' ...
                              'and the chosen amount.'];
    uilabel(machineTab, 'Text', instructionTextMachine, 'Position', [10, 450, 660, 100], 'HorizontalAlignment', 'center', 'WordWrap', 'on');


    % Create a table for dispenser settings with default data
    % Columns: [Start Layer, Base Dose, Pattern Period, Pattern Dose]
    % By default, we set no pattern (Pattern Period and Pattern Dose are 0)
    dispenserTableData = [1, 400, 0, 0];  % Default row
    dispenserTable = uitable(machineTab, 'Data', dispenserTableData, ...
        'ColumnName', {'Start Layer', 'Base Dose', 'Pattern Period', 'Pattern Dose'}, ...
        'ColumnEditable', [true true true true], ...
        'RowName', [], ...
        'Position', [10, 250, 300, 100]);
    
    % Add a button to add a new row to the dispenser table.
    addRowButton = uibutton(machineTab, 'push', 'Text', 'Add Row', ...
        'Position', [320, 250, 100, 30], ...
        'ButtonPushedFcn', @(btn, event) addRowCallback());
    
    function addRowCallback()
        currentData = dispenserTable.Data;
        if isempty(currentData)
            newData = [1, 400, 0, 0];
        else
            % Suggest a new row with a start layer one greater than the last row
            newStartLayer = currentData(end, 1) + 1;
            newData = [newStartLayer, 400, 0, 0];
        end
        dispenserTable.Data = [currentData; newData];
    end
    
    % Add a button to remove a row from the dispenser table.
    removeRowButton = uibutton(machineTab, 'push', 'Text', 'Remove Row', ...
        'Position', [320, 210, 100, 30], ...
        'ButtonPushedFcn', @(btn, event) removeRowCallback());
    
    function removeRowCallback()
        currentData = dispenserTable.Data;
        if isempty(currentData)
            return;
        end
        % If a row is selected, remove that row; otherwise remove the last row.
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

    % Checkbox for "Mirror X"
    mirrorXCheckbox = uicheckbox(machineTab, 'Text', 'Mirror X', 'Position', [10, 200, 100, 22]);
    mirrorXCheckbox.Value = true;  % Set "Mirror X" to be checked by default
    
    % Checkbox for "Mirror Y"
    mirrorYCheckbox = uicheckbox(machineTab, 'Text', 'Mirror Y', 'Position', [10, 170, 100, 22]);

    %recoaterInterval = recoaterField.Value;

    
    advancedTab = uitab(tgroup, 'Title', 'Advanced');
    
    % Add UI components for Advanced Settings:
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


    % Create submit button
    submitButton = uibutton(fig, 'push', 'Text', 'Submit', 'Position', [300, 10, 100, 30], ...
                            'ButtonPushedFcn', @(btn, event) onSubmit());

    % Initialize the output variables
    processParameters = [];
    machineParameters = [];

    % Pause the UI here and wait for the user to submit their input
    uiwait(fig);

    % Nested function for handling the submit action
     function onSubmit()
        % Get the data from the process parameters table
        processParameters = processTable.Data;

        % Get the machine settings, including the new fields
        machineParameters = dispenserTable.Data;
        % Optional: Sort the rows by the start layer in ascending order
        machineParameters = sortrows(machineParameters, 1);
        % Retrieve the checkbox states
        mirrorX = mirrorXCheckbox.Value;
        mirrorY = mirrorYCheckbox.Value;

        % --- NEW CODE: Get Advanced Settings ---
        advancedParams.galvoSpeedScale = galvoScaleField.Value;
        advancedParams.recoatTo = recoatField.Value;
        advancedParams.pistonRetraction = pistonRetractionField.Value;
        advancedParams.crossflowSetting = crossflowField.Value;
        advancedParams.VFDsetting = VFDField.Value;
        advancedParams.oxygenSetting = oxygenField.Value;
        advancedParams.jumpSetting = jumpSpeedField.Value;
        
        recoaterInterval = recoaterField.Value;
        processingRange = [startLayerField.Value, stopLayerField.Value];

        % Close the figure
        delete(fig);
     end
end


function [power, feedrate] = suggest_parameters(object_name,layerHeight)

%customLayerHeight = 50;

    if layerHeight > 45 && layerHeight < 55
        % Default parameters (contour)
        power = 120;  % Default Power
        feedrate = 950;  % Default Feedrate
    
        % Check the object naming convention 
        % Hatch
        if contains(object_name, '(Filling)', 'IgnoreCase', true)
            power = 190;
            feedrate = 950;
            
        elseif contains(object_name, '(Support)', 'IgnoreCase', true)
            power = 250;
            feedrate = 1100;
            
        elseif contains(object_name, '(SolidSupport)', 'IgnoreCase', true)
            power = 190;
            feedrate = 950;
    
        elseif contains(object_name, 'Overhang', 'IgnoreCase', true)
            power = 175;
            feedrate = 4000;
        end
    
    elseif layerHeight > 25 && layerHeight < 35
        % Default parameters (contour)
        power = 120;  % Default Power
        feedrate = 1500;  % Default Feedrate
    
        % Check the object naming convention 
        % Hatch
        if contains(object_name, '(Filling)', 'IgnoreCase', true)
            power = 190;
            feedrate = 1500;
            
        elseif contains(object_name, '(Support)', 'IgnoreCase', true)
            power = 250;
            feedrate = 2200;
            
        elseif contains(object_name, '(SolidSupport)', 'IgnoreCase', true)
            power = 190;
            feedrate = 1500;
    
        elseif contains(object_name, 'Overhang', 'IgnoreCase', true)
            power = 175;
            feedrate = 4000;
        end
    end
end


