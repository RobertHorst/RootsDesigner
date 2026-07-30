Latest stable release: v0.3.2

RootsDesigner for generating graphs and tables for analyzing a family of Roots 
blower profiles. The program also optionally creates csv files defining splines that 
can be loaded into Autodesk Fusion for creating the 3d models.
The Roots profiles are based on a circle rolling inside and outside the pitch
curve of identical noncircular gears.

v0.3.0 adds Max Angle Deviation to the outputs and adds a Python version with the same
functionality as the Matlab version.  See the Install file for the Python installation
instructions.

v0.3.1 fixes a Windows-only crash on startup (PySide6's Qt DLLs were not being found on
PC); no functional changes. Confirmed working on macOS, Windows, and expected to work
on Linux.

v0.3.2 fixes a bug in Max Angle Deviation: for some geometries (most visibly 2-lobe
rotors) the search for the interference angle only checked the far end of its search
window, so it could report the search boundary (e.g. 90 deg) instead of the true,
much smaller crossing angle. Affects both the MATLAB and Python versions; other
outputs (Min Gap, Avg Gap, etc.) were not affected.

For more information see:
Horst, Robert. "A family of high-flow Roots blower profiles based on non-circular gears 
and the coin rotation paradox." 
engrXiv, https://doi.org/10.31224/4850 (2026).

License
This project is licensed under the Horst Tech Non‑Commercial Software License.  
Internal use (including by companies) is permitted; use in commercial products or paid services is not.  
See the License.txt file for full terms