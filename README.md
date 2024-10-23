# Netfabb Gcode PostProcess Setup and Guide

## Setting up Netfabb

1. Download the 3MF file from the post-processors
GitHub page and save them in a known folder. E.g., …/Documents/NetfabbSetup
2. Add a new machine
3. Click the Pencil icon at the top right corner of the "My Machines" window.
4. Change the name to "LOOP” in the top textbox (the very top).
5. Check the "Customized machine" box at the bottom and change the Z-height to 150mm.
6. Click on "Save machine."
7. Under Template open the LOOP 
the "LOOP_NoBuild.3MF” you saved previously.
8. Click on "Save"
9. Done



<p align="center"><img src="misc/Start.png" height="400" alt="Netfabb screenshot" /></p>
<h3 align="center">Netfabb LOOP build plate</h3>

<p align="center"><img src="misc/Add machine.png" height="400" alt="Netfabb screenshot" /></p>
<h3 align="center">Netfabb LOOP build plate</h3>

<p align="center"><img src="misc/Edit machine.png" height="400" alt="Netfabb screenshot" /></p>
<h3 align="center">Netfabb LOOP build plate</h3>

<p align="center"><img src="misc/No Build Zone.png" height="400" alt="Netfabb screenshot" /></p>
<h3 align="center">Netfabb LOOP build plate</h3>

<p align="center"><img src="misc/Result build plate.png" height="400" alt="Netfabb screenshot" /></p>
<h3 align="center">Netfabb LOOP build plate</h3>

<p align="center"><img src="misc/Select build plate.png" height="400" alt="Netfabb screenshot" /></p>
<h3 align="center">Netfabb LOOP build plate</h3>

<p align="center"><img src="misc/Finished.png" height="400" alt="Netfabb screenshot" /></p>
<h3 align="center">Netfabb LOOP build plate</h3>


## Using the post-processor

The post-processor is written in Matlab, and will in the foreseeable future be rewritten in Python and/or be integrated directly into the system software.

1. Run the script and select you CLI file. 
2. Select parameters per scan object. To select process parameters per scan object, they must be labeled according to the CLI standard.
3. Select machine paramters
4. Hit submit and wait for processing

The result is a folder and .zip folder containing the job file. Currently, each layer is exported in their own .txt and the next layer is explicitly loaded in the last line.
