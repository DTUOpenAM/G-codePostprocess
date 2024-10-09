clear

[inputFile, path] = uigetfile('*.cli');
if isequal(inputFile, 0)
   disp('User selected Cancel');
else
   disp(['User selected ', fullfile(path, inputFile)]);
end

% Custom input function for parameters
[processParameters, machineParameters, label_matches, mirrorX, mirrorY] = custom_cli_input(inputFile);


% Call processcli to generate the G-code and save it to files
processcli(inputFile, processParameters, machineParameters, mirrorX, mirrorY, label_matches);




function processcli(inputFile, processParameters, machineParameters, mirrorX, mirrorY, label_matches)
    % Extract the base filename without the extension
    [~, baseFileName, ~] = fileparts(inputFile);
    
    % Create a folder named after the base filename
    folderName = fullfile(pwd, baseFileName);
    if ~exist(folderName, 'dir')
        mkdir(folderName);
    end

    cli_data = fileread(inputFile);
    
    scaleFactor = 203.92;
    crossflowSetting = 70; % Percentage
     
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


    % Parallel processing of layers using parfor
    parfor layer_count = 1:numLayerCount
        % Initialize gcode for this layer
        gcode_str = '';

        % Output the current layer being processed
        fprintf('Processing layer %d of %d...\n', layer_count, numLayerCount);
        
        % Handle layer-specific commands
        if layer_count > 1 && layer_count < numLayerCount
            gcode_str = [gcode_str sprintf('movedosingby %d\n', dispenserValue)];
            gcode_str = [gcode_str sprintf('movebuildpistonby %d\n', layerHeight)];
            gcode_str = [gcode_str sprintf('moverecoaterto %d\n', 450)];
            gcode_str = [gcode_str sprintf('movebuildpistonby %d\n', layerHeight * 12)];
            gcode_str = [gcode_str sprintf('moverecoaterto %d\n', 0)];
            gcode_str = [gcode_str sprintf('movebuildpistonby %d\n', -layerHeight * 12 - 100)];
            gcode_str = [gcode_str sprintf('movebuildpistonby %d\n', 100)];
         
        elseif layer_count == 1
            gcode_str = [gcode_str sprintf('setcrossflowfanspeed %0.0f\n', 65536 * crossflowSetting / 100)];
            gcode_str = [gcode_str sprintf('setvfdspeed 40\n')];
            gcode_str = [gcode_str sprintf('setoxygenlevel 0.1\n')];
        end

        % Process the segments for this layer
        for j = 1:length(layers{layer_count})
            seg = layers{layer_count}{j};
            if startsWith(seg, 'POLYLINE/')
                data = str2double(strsplit(seg(10:end), ','));
                object_number = data(1);
                x_values = (data(4:2:end-1) * scalar_multiplier * mirrorHandleX) * scaleFactor + 32767;
                y_values = (data(5:2:end) * scalar_multiplier * mirrorHandleY) * scaleFactor + 32767;

                % Use the processParameters and label_matches to dynamically set power or speed
                power = processParameters{object_number-1, 3}/300*100;  % Get power for this object
                speed = processParameters{object_number-1, 4}*262.144;  % Get speed for this object

                gcode_str = [gcode_str sprintf('setlaserpower %0.0f\n', power)];
                gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', speed)];

                gcode_str = [gcode_str sprintf('jumpgalvoto %.f, %.f\n', x_values(1), y_values(1))];
                
                for i = 2:length(x_values)
                    gcode_str = [gcode_str sprintf('scangalvoto %.f, %.f\n', x_values(i), y_values(i))];
                end
            
            elseif startsWith(seg, 'HATCHES/')
                data = str2double(strsplit(seg(9:end), ','));
                object_number = data(1);
                x_values = (data(3:2:end-1) * scalar_multiplier * mirrorHandleX) * scaleFactor + 32767;
                y_values = (data(4:2:end) * scalar_multiplier * mirrorHandleY) * scaleFactor + 32767;

                % Apply the process parameters based on object label
                power = processParameters{object_number-1, 3}/300*100;  % Power for hatches
                speed = processParameters{object_number-1, 4}*262.144;  % Speed for hatches

                gcode_str = [gcode_str sprintf('setlaserpower %0.0f\n', power)];
                gcode_str = [gcode_str sprintf('setgalvospeed %0.0f\n', speed)];

                for i = 1:length(x_values)
                    if mod(i, 2) == 1
                        gcode_str = [gcode_str sprintf('jumpgalvoto %.f, %.f\n', x_values(i), y_values(i))];
                    else
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
            fprintf(fileID, 'Number of Layers: %d\n', numLayerCount);
            fprintf(fileID, 'Crossflow Fan Speed: %0.0f%%\n', crossflowSetting);
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




function [processParameters, machineParameters, label_matches, mirrorX, mirrorY] = custom_cli_input(cli_filename)
    % Read file content
    file_content = fileread(cli_filename);

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


    % Prepare the data for the table
    tableData = cell(numel(label_matches), 4); % Columns for Label, Power, Feedrate
    for i = 1:numel(label_matches)
        tableData{i, 1} = i+1;
        tableData{i, 2} = label_matches{i}{2}; % Label Name

        [power_sug, feedrate_sug] = suggest_parameters(label_matches{i}{2});
        tableData{i, 3} = power_sug; % Default Power
        tableData{i, 4} = feedrate_sug; % Default Feedrate
    end

    % Create the table in the "Process Parameters" tab
    processTable = uitable(processTab, 'Data', tableData, ...
                           'ColumnName', {'','Object', 'Power [W]', 'Feedrate [mm/s]'}, ...
                           'ColumnEditable', [false false true true], ...
                           'RowName', [], ...
                           'Position', [10 50 560 300]);

    % Create the "Machine Settings" tab
    machineTab = uitab(tgroup, 'Title', 'Machine Settings');

    % Add instructional text for the "Machine Settings" tab
    instructionTextMachine = ['Enter layer height in mm. ' ...
                                'Enter dosing for dispenser 1 and 2. P3 will use both dispensers. ' ...
                                'N[#] signifies the amount of powder. ' ...
                                'For multi-material dosing, specify the pattern. E.g., 5 and 3 will ' ...
                                'produce 5 layers of material 1, followed by 3 layers of material 2, etc. ' ...
                                'If choosing both dispenser (P3) the pattern has no effect.'];
    uilabel(machineTab, 'Text', instructionTextMachine, 'Position', [10, 450, 660, 100], 'HorizontalAlignment', 'center', 'WordWrap', 'on');


    % % Create UI components for "Dispenser" in the "Machine Settings" tab
    % uilabel(machineTab, 'Text', 'Dispenser:', 'Position', [10, 300, 100, 22]);
    % dispenserField = uieditfield(machineTab, 'text', 'Position', [110, 300, 100, 22], 'Value', '400');
    % 
    % Create UI components for "Dispenser" in the "Machine Settings" tab
    uilabel(machineTab, 'Text', 'Dispenser:', 'Position', [10, 300, 100, 22]);
    dispenserField = uieditfield(machineTab, 'numeric', 'Position', [110, 300, 100, 22], 'Value', 400);  % Changed to 'numeric'

    % Checkbox for "Mirror X"
    mirrorXCheckbox = uicheckbox(machineTab, 'Text', 'Mirror X', 'Position', [10, 200, 100, 22]);
    mirrorXCheckbox.Value = true;  % Set "Mirror X" to be checked by default
    
    % Checkbox for "Mirror Y"
    mirrorYCheckbox = uicheckbox(machineTab, 'Text', 'Mirror Y', 'Position', [10, 170, 100, 22]);


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
        machineParameters = [dispenserField.Value];
        % Retrieve the checkbox states
        mirrorX = mirrorXCheckbox.Value;
        mirrorY = mirrorYCheckbox.Value;

        % Close the figure
        delete(fig);
     end
end


function [power, feedrate] = suggest_parameters(object_name)
    % Default parameters (contour)
    power = 120;  % Default Power
    feedrate = 850;  % Default Feedrate

    % Check the object naming convention 
    % Hatch
    if contains(object_name, '(Filling)', 'IgnoreCase', true)
        power = 190;
        feedrate = 850;
        
    elseif contains(object_name, '(Support)', 'IgnoreCase', true)
        power = 250;
        feedrate = 1100;
        
    elseif contains(object_name, '(SolidSupport)', 'IgnoreCase', true)
        power = 190;
        feedrate = 850;
    end
end


