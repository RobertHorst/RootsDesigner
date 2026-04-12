MATLAB App Designer for generating graphs and tables for analyzing a family of Roots 
blower profiles.
The program also optionally creates csv files defining splines that can be loaded into 
Autodesk Fusion for creating the 3d models.
The Roots profiles are based on a circle rolling inside and outside the pitch
curve of identical noncircular gears.
% Usage:  RootsProfileApp
%
% Mode toggle (above tabs):
%   Set Shaft Spacing  — input ss, compute shell diameter
%   Set Shell Diameter — input shell_d, solve for shaft spacing via fzero
%
% Two tabs:
%   Interactive — adjust parameters, press Compute, view 6-angle profiles
%   Batch       — load/edit parameter table, Run All, click result row to plot

For more information see:
Horst, Robert. "A family of high-flow Roots blower profiles based on non-circular gears 
and the coin rotation paradox." 
engrXiv, https://doi.org/10.31224/4850 (2025).


License
Copyright © 2026 Horst Tech LLC

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to use, copy, modify, and merge the Software for personal, academic, or non-commercial purposes only, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

Commercial use, sale, sublicensing, or distribution for profit is strictly prohibited.

No intellectual property rights are transferred or implied by making this code publicly available.
THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT, OR OTHERWISE, ARISING FROM, OUT OF, OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
