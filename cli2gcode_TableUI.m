clear    


[inputFile,path] = uigetfile('*.cli');
if isequal(inputFile,0)
   disp('User selected Cancel');
else
   disp(['User selected ', fullfile(path,inputFile)]);
end


[processParameters, machineParameters, label_matches, mirrorX, mirrorY] = custom_cli_input(inputFile);

gcode = processcli(inputFile, processParameters, machineParameters, label_matches, mirrorX, mirrorY);



% Save Gcode to a file
    fileID_clean = extractBefore(inputFile, ".");
    fileID = fopen(convertCharsToStrings(fileID_clean) + '.g', 'w');
    fprintf(fileID, '%s', gcode);
    fclose(fileID);
    


    function gcode_str = processcli(inputFile, processParameters, machineParameters, label_matches, mirrorX, mirrorY)
    cli_data = fileread(inputFile);

    % Extract the scalar multiplier from the CLI file
    unitsPattern = '\$\$UNITS\/(\d+\.?\d*)';
    units = regexp(cli_data, unitsPattern, 'tokens');
    scalar_multiplier = str2double(units{1}{1});
    
    % Extract the layer count from the CLI file
    layersPattern = '\$\$LAYERS\/(\d+\.?\d*)';
    numLayers = regexp(cli_data, layersPattern, 'tokens');
    numLayerCount = str2double(numLayers{1}{1});

    % Add the pattern to extract layer height
    layerHeightPattern = '\$\$LAYER\/(\d+\.?\d*)';
    layerHeight = regexp(cli_data, layerHeightPattern, 'tokens');
    % Extract the second layer height (omit the first layer which is zero)
    layerHeightValue = str2double(layerHeight{2}{1}) * scalar_multiplier;

    pattern1 = machineParameters{1,4}; % Assuming machineParameters holds the pattern values as shown earlier
    pattern2 = machineParameters{2,4};
    dispensingOrder = createDispensingOrder(pattern1, pattern2, numLayerCount);

    % Split the data based on the '$$' pattern to maintain order
    segments = strsplit(cli_data, '$$');

    % Create an output string for Gcode
    gcode_str = "";
    layer_count = 0;

    % Variable to keep track of the last label processed
    lastLabelNumber = 1;

    mirrorHandleX = 0;
    mirrorHandleY = 0;

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


    % Convert parameter to cell array
    defaultLabel = {'default'};
    paramCell = [1, {defaultLabel, 0, 0, 100, 5000}; processParameters];
    

    processLabels = label_matches;

    for seg = segments(2:end) % skip the first one as it's a preamble or empty

        if startsWith(seg{1}, 'LAYER/')
            

            if layer_count > 1 && layer_count < numLayerCount - 1
                

                % Extract the layer height and count it
                gcode_str = gcode_str + sprintf('M10\n');
                gcode_str = gcode_str + newline;
                gcode_str = gcode_str + sprintf(';Layer %d [%.3fmm]\n', layer_count, layerHeightValue);
                gcode_str = gcode_str + sprintf('M1 %s\n', machineParameters{dispensingOrder(layer_count),2});
                gcode_str = gcode_str + sprintf('M2 T%.3f\n', layerHeightValue);
                gcode_str = gcode_str + sprintf('M3\n');
                gcode_str = gcode_str + newline;

              

            elseif layer_count == 0

                %layer_count = layer_count + 1;
                gcode_str = gcode_str + sprintf(';Gcode for open-source L-PBF, developed at DTU\n');
                gcode_str = gcode_str + sprintf(';Common Layer Interface (cli) file converted to gcode\n');
                gcode_str = gcode_str + sprintf(';Original file name: ' + convertCharsToStrings(inputFile) + '\n');
                gcode_str = gcode_str + sprintf(';Gcode created: ' + string(datetime("today")) + '\n');
                gcode_str = gcode_str + sprintf(';Layer height: %d \n', layerHeightValue);
                gcode_str = gcode_str + newline;
                gcode_str = gcode_str + sprintf(';Scan objects:\n');
                
                for lab = processLabels(1:end)
                    gcode_str = gcode_str + ';Label: ' + lab{1}{1} + ', ' + lab{1}{2} + newline;
                end

                gcode_str = gcode_str + newline;

                

            elseif layer_count == 1

                % Print layer one
                gcode_str = gcode_str + sprintf(';Beginning processing\n');
                gcode_str = gcode_str + sprintf('M0 P3\n');
                gcode_str = gcode_str + sprintf('M41\n');
                gcode_str = gcode_str + sprintf(';Layer %d\n', layer_count);
                

            end
            layer_count = layer_count + 1;

            

        elseif startsWith(seg{1}, 'POLYLINE/')
            data = str2double(strsplit(seg{1}(10:end), ','));
            object_number = data(1);
            x_values = data(4:2:end-1) * scalar_multiplier * mirrorHandleX;
            y_values = data(5:2:end) * scalar_multiplier * mirrorHandleY;
            
            if object_number ~= lastLabelNumber
                % Only add the polyline comment if the label number has changed
                gcode_str = gcode_str + newline;
                gcode_str = gcode_str + sprintf(';Polyline [Label %d]\n', object_number);
                gcode_str = gcode_str + sprintf('G1 P%d F%d\n', paramCell{object_number,3}, paramCell{object_number,6});

                
            end

            lastLabelNumber = object_number; % Update the last label number processed
            % Generate Gcode for the first line segment with D0
            gcode_str = gcode_str + sprintf('G1 X%.4f Y%.4f D0\n', x_values(1), y_values(1));
            
            % Generate Gcode for the subsequent line segments with D100, F
            for i = 2:length(x_values)
                if paramCell{object_number, 5} > 0 && paramCell{object_number, 6} > 0
                    if paramCell{object_number, 5} > 100
                        errordlg('Duty cycle cannot be over 100%','D error');
                    end
                    gcode_str = gcode_str + sprintf('G1 X%.4f Y%.4f D%d\n', x_values(i), y_values(i), paramCell{object_number, 5});
                else
                    errordlg('Entered non-positive value in D or F','D or F error');
                end
            end
            


        elseif startsWith(seg{1}, 'HATCHES/')
            data = str2double(strsplit(seg{1}(9:end), ','));
            object_number = data(1);
            x_values = data(3:2:end-1) * scalar_multiplier * mirrorHandleX;
            y_values = data(4:2:end) * scalar_multiplier * mirrorHandleY;

            if object_number ~= lastLabelNumber

                gcode_str = gcode_str + newline;
                gcode_str = gcode_str + sprintf(';Hatch [Label %d]\n', object_number);
                %P = processParameters(object_number,1);
                %F = processParameters(object_number,2);
                gcode_str = gcode_str + sprintf('G1 P%d F%d\n', paramCell{object_number,3}, paramCell{object_number,6});              

            end

            lastLabelNumber = object_number; % Update the last label number processed
            % Generate Gcode for the hatch line segments alternating between D0 and D100
            for i = 1:length(x_values)
                if mod(i, 2) == 1
                    gcode_str = gcode_str + sprintf('G1 X%.4f Y%.4f\n', x_values(i), y_values(i));
                else
                    gcode_str = gcode_str + sprintf('G1 X%.4f Y%.4f D%d\n', x_values(i), y_values(i), paramCell{object_number, 5});
                end
            end

        elseif startsWith(seg{1}, 'GEOMETRYEND')

                gcode_str = gcode_str + newline;
                gcode_str = gcode_str + sprintf(';End of Gcode.\n');
                gcode_str = gcode_str + sprintf(';Shutting down:\n');
                gcode_str = gcode_str + sprintf('P4 F0\n');
                gcode_str = gcode_str + sprintf('P3 T2\n');

        end
        
    end
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
    tableData = cell(numel(label_matches), 6); % Columns for Label, Power, Feedrate, Duty Cycle, Frequency
    for i = 1:numel(label_matches)
        tableData{i, 1} = i+1;
        tableData{i, 2} = label_matches{i}{2}; % Label Name
        tableData{i, 3} = 190; % Default Power
        tableData{i, 4} = 750; % Default Feedrate
        tableData{i, 5} = 100; % Default Duty Cycle
        tableData{i, 6} = 100000; % Default Frequency
    end
    
    % Create the table in the "Process Parameters" tab
    processTable = uitable(processTab, 'Data', tableData, ...
                           'ColumnName', {'', 'Object', 'Power [W]', 'Feedrate [mm/s]', 'Duty Cycle [%]', 'Frequency [Hz]'}, ...
                           'ColumnEditable', [false false true true true true], ...
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


    % Create UI components for "Dispenser 1" and its "Pattern" in the "Machine Settings" tab
    uilabel(machineTab, 'Text', 'Dispenser 1:', 'Position', [10, 300, 100, 22]);
    dispenser1Field = uieditfield(machineTab, 'text', 'Position', [110, 300, 100, 22], 'Value', 'P1 N3');
    
    uilabel(machineTab, 'Text', 'Pattern:', 'Position', [220, 300, 100, 22]);
    pattern1Field = uieditfield(machineTab, 'numeric', 'Position', [320, 300, 100, 22], 'Value', 1);
    
    % Create UI components for "Dispenser 2" and its "Pattern" in the "Machine Settings" tab
    uilabel(machineTab, 'Text', 'Dispenser 2:', 'Position', [10, 250, 100, 22]);
    dispenser2Field = uieditfield(machineTab, 'text', 'Position', [110, 250, 100, 22], 'Value', 'P2 N3');
    
    uilabel(machineTab, 'Text', 'Pattern:', 'Position', [220, 250, 100, 22]);
    pattern2Field = uieditfield(machineTab, 'numeric', 'Position', [320, 250, 100, 22], 'Value', 1);
    
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
    machineParameters = {};

    % Pause the UI here and wait for the user to submit their input
    uiwait(fig);

    % Nested function for handling the submit action
     function onSubmit()
        % Get the data from the process parameters table
        processParameters = processTable.Data;
    
        % Get the machine settings, including the new fields
        % Ensure each row has exactly four columns
        machineParameters = {
            'Dispenser1', dispenser1Field.Value, 'Pattern1', pattern1Field.Value; 
            'Dispenser2', dispenser2Field.Value, 'Pattern2', pattern2Field.Value; 
            'MultiMat', 0, '', '';  % Add empty strings to ensure the row has 4 elements
        };
    
        % Retrieve the checkbox states
        mirrorX = mirrorXCheckbox.Value;
        mirrorY = mirrorYCheckbox.Value;
    
        % Close the figure
        delete(fig);
    end

end



function dispensingOrder = createDispensingOrder(pattern1, pattern2, numLayerCount)
    % Initialize an empty array to hold the dispensing order
    dispensingOrder = [];
    
    % Create the dispensing order based on the pattern values
    % Assuming pattern1 = 5 and pattern2 = 4 would mean 5 layers of dispenser1 followed by 4 layers of dispenser2
    % Repeat this sequence for the number of layers required
    % If the number of layers is not known beforehand, you could create a sufficiently large sequence
    % or use a while loop to dynamically extend the sequence as needed

    % Example for a fixed number of total layers (e.g., 20):
    totalLayers = numLayerCount-2;
    currentLayer = 1;
    
    while currentLayer <= totalLayers
        % Add layers for dispenser1
        for i = 1:pattern1
            if currentLayer > totalLayers
                break;
            end
            dispensingOrder(end+1) = 1; % 1 represents dispenser1
            currentLayer = currentLayer + 1;
        end
        
        % Add layers for dispenser2
        for i = 1:pattern2
            if currentLayer > totalLayers
                break;
            end
            dispensingOrder(end+1) = 2; % 2 represents dispenser2
            currentLayer = currentLayer + 1;
        end
    end
end

