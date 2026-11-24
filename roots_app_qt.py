"""PySide6 GUI port of RootsProfileApp.m — full feature parity with the
MATLAB App Designer app: mode toggle (shaft spacing / shell diameter;
starts in Set Shell Diameter), Return to Defaults button,
Interactive tab (parameters, Compute, Export Spline, 15-row Results panel,
six-angle rotor mesh plot), and Batch tab (editable parameter table, Load
Defaults, Add/Delete row, Run All, Plot marked rows, Export CSV).

The math lives in roots_profile.py (the vectorized NumPy/SciPy core) —
this module only adds the GUI. Settings shared by both tabs (above the
tabs): profile method (Averaged or Noslip rolling), units (SI or Imperial),
rotor speed (RPM) and discharge-opening diameter for the outlet velocity.

Usage:
    python3 roots_app_qt.py

Copyright 2026, Robert Horst, Horst Tech LLC
"""

import csv
import sys

import numpy as np

try:
    # matplotlib >= 3.5: unified Qt backend (works with PySide6/PyQt6/PySide2/PyQt5)
    from matplotlib.backends.backend_qtagg import FigureCanvasQTAgg
except ImportError:
    # matplotlib < 3.5: only the Qt5-named backend module exists
    from matplotlib.backends.backend_qt5agg import FigureCanvasQTAgg
from matplotlib.figure import Figure
from PySide6.QtCore import QThread, Qt, Signal
from PySide6.QtGui import QColor
from PySide6.QtWidgets import (
    QAbstractItemView,
    QApplication,
    QButtonGroup,
    QComboBox,
    QDoubleSpinBox,
    QFileDialog,
    QFormLayout,
    QGridLayout,
    QGroupBox,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QMainWindow,
    QScrollArea,
    QFrame,
    QMessageBox,
    QProgressDialog,
    QPushButton,
    QRadioButton,
    QSpinBox,
    QTabWidget,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)
from roots_profile import (
    Cancelled,
    METHODS,
    flow_from_cmm,
    flow_units,
    INPUT_DEFAULTS,
    INPUT_KINDS,
    design_compute,
    format_results,
    rotate_shift,
    velocity_from_mps,
    velocity_units,
)

APP_NAME = "Roots Profile Designer"
APP_VENDOR = "Horst Tech LLC"
VERSION = "0.4.0"
VERSION_DATE = "2026-11-20"

N_RESULT_ROWS = 17  # rows returned by roots_profile.format_results

BATCH_INPUT_HEADERS = ["Plot?", "Lobes", "ex", "offset", "rotor_H", "shell_gap", "ss", "points"]
BATCH_RESULT_HEADERS = [
    "Offset", "Min_Gap", "Avg_Gap", "Max_Angle_Dev",
    "SS", "Shell_D", "Rmax", "Rmin", "Width", "Lambda_r", "Lambda_w",
    "Area_Eff", "Velocity", "Flow_Loss", "Flow_Net",
]
# Columns that are meaningless (shown as 0, in red) when the lobes interfere.
BATCH_BAD_COLS = {1, 2, 3, 12, 13, 14}
BATCH_KIND_COL = {"min_gap": 1, "max_angle_dev": 3}
BATCH_INPUT_COL_NAMES = {"offset": "offset", "min_gap": "min_gap",
                         "max_angle_dev": "max_angle_dev"}
INPUT_FIELD_RANGES = {"offset": (0.01, 1000.0, 3), "min_gap": (0.01, 1000.0, 3),
                      "max_angle_dev": (0.01, 90.0, 3)}
RED = "#D92626"
BLUE = "#1A4DB2"

_SG = 2
DEFAULT_BATCH_ROWS = [
    (2, 0.000, 1.00, 100, _SG, 80.4, 1001),
    (2, 0.089, 1.17, 100, _SG, 80.4, 1001),
    (2, 0.170, 1.70, 100, _SG, 80.4, 1001),
    (2, 0.245, 2.545, 100, _SG, 80.4, 1001),
    (2, 0.300, 3.40, 100, _SG, 80.4, 1001),
    (3, 0.000, 1.00, 100, _SG, 80.4, 1001),
    (3, 0.089, 1.18, 100, _SG, 80.4, 1001),
    (3, 0.170, 1.76, 100, _SG, 80.4, 1001),
    (3, 0.245, 2.72, 100, _SG, 80.4, 1001),
    (3, 0.300, 3.675, 100, _SG, 80.4, 1001),
    (4, 0.000, 1.00, 100, _SG, 80.4, 1001),
    (4, 0.089, 1.19, 100, _SG, 80.4, 1001),
    (4, 0.170, 1.85, 100, _SG, 80.4, 1001),
    (4, 0.245, 2.95, 100, _SG, 80.4, 1001),
    (4, 0.300, 4.00, 100, _SG, 80.4, 1001),
    (5, 0.000, 1.00, 100, _SG, 80.4, 1001),
    (5, 0.089, 1.20, 100, _SG, 80.4, 1001),
    (5, 0.170, 1.95, 100, _SG, 80.4, 1001),
    (5, 0.245, 3.15, 100, _SG, 80.4, 1001),
    (5, 0.300, 4.30, 100, _SG, 80.4, 1001),
]

# Batch defaults in Set Shell Diameter mode: Table 3 of the paper
# (130 mm housing, 2 mm shell gap; column 6 is the shell diameter).
DEFAULT_BATCH_ROWS_SD = [
    (2, 0.000, 1.00, 100, _SG, 130, 1001),
    (3, 0.000, 1.00, 100, _SG, 130, 1001),
    (4, 0.000, 1.00, 100, _SG, 130, 1001),
    (5, 0.000, 1.00, 100, _SG, 130, 1001),
    (2, 0.245, 2.42, 100, _SG, 130, 1001),
    (3, 0.245, 2.72, 100, _SG, 130, 1001),
    (4, 0.245, 3.06, 100, _SG, 130, 1001),
    (5, 0.245, 3.39, 100, _SG, 130, 1001),
]

# Start-up values restored by "Return to Defaults".
DEFAULTS = dict(
    mode="sd", shell_d=130.0, ss=80.4, method="averaged", rpm=1000.0,
    input_kind="offset",
    outlet_d=51.0, lobes=3, ex=0.245, offset=2.72, rotor_H=100.0,
    shellgap=2.0, points="1001",
)

PALETTE = [
    (0.15, 0.35, 0.70), (0.85, 0.25, 0.15), (0.20, 0.65, 0.30),
    (0.85, 0.55, 0.10), (0.55, 0.25, 0.70), (0.10, 0.60, 0.65),
    (0.85, 0.40, 0.55), (0.40, 0.40, 0.40),
]


class ComputeWorker(QThread):
    """Runs one rootsCompute (with optional shaft-spacing solve) off the UI thread."""

    # (Named so they do not hide QThread.finished, which the window uses to
    # know when the thread has really stopped.)
    computed = Signal(dict)
    failed = Signal(str)

    def __init__(self, params, parent=None):
        super().__init__(parent)
        self.params = params
        self._cancelled = False

    def cancel(self):
        self._cancelled = True

    def run(self):
        p = self.params
        try:
            r = design_compute(p["nodes"], p["ex"], p["input_kind"],
                               p["input_value"], p["rotor_H"], p["shellgap"],
                               p["mode"], p["ss_or_shelld"], p["points"],
                               method=p["method"], rpm=p["rpm"],
                               outlet_d=p["outlet_d"],
                               cancel=lambda: self._cancelled)
            self.computed.emit(r)
        except Cancelled:
            pass
        except Exception as exc:  # noqa: BLE001 — surface any failure to the UI
            self.failed.emit(str(exc))


class BatchWorker(QThread):
    """Runs a list of parameter sets sequentially, reporting per-row progress."""

    rowDone = Signal(int, object)  # row index, result dict or error message
    progress = Signal(int, int)  # completed, total
    # Completion is QThread.finished (emitted after run() has returned).

    def __init__(self, rows, mode, settings, parent=None):
        super().__init__(parent)
        self.rows = rows  # list of dicts: nodes, ex, input, rotor_H, shellgap, col6, points
        self.mode = mode
        self.settings = settings  # dict: method, rpm, outlet_d, input_kind
        self._cancelled = False

    def cancel(self):
        self._cancelled = True

    def run(self):
        n = len(self.rows)
        for i, row in enumerate(self.rows):
            if self._cancelled:
                break
            try:
                st = self.settings
                r = design_compute(row["nodes"], row["ex"], st["input_kind"],
                                   row["input"], row["rotor_H"], row["shellgap"],
                                   self.mode, row["col6"], row["points"],
                                   method=st["method"], rpm=st["rpm"],
                                   outlet_d=st["outlet_d"],
                                   cancel=lambda: self._cancelled)
                self.rowDone.emit(i, r)
            except Cancelled:
                break
            except Exception as exc:  # noqa: BLE001 — mark row as failed, keep going
                self.rowDone.emit(i, str(exc))
            self.progress.emit(i + 1, n)


class RootsProfileWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(f"{APP_NAME}  v{VERSION}  —  {APP_VENDOR}")
        self.resize(1460, 920)

        self.last_xy = None
        self.last_nodes = 3
        self.last_ss = 80.4

        self.batch_xy_cache = {}
        self.batch_node_cache = {}
        self.batch_ss_cache = {}

        self._compute_worker = None
        self._batch_worker = None
        self._batch_progress_dlg = None

        self._build_ui()
        self._on_mode_changed()

    # ------------------------------------------------------------------
    #  UI construction
    # ------------------------------------------------------------------
    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        main_layout = QHBoxLayout(central)

        left_widget = QWidget()
        left_panel = QVBoxLayout(left_widget)
        # Scrollable, so the Results panel is never cut off on small screens.
        left_scroll = QScrollArea()
        left_scroll.setWidget(left_widget)
        left_scroll.setWidgetResizable(True)
        left_scroll.setFrameShape(QFrame.NoFrame)
        left_scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        left_scroll.setMinimumWidth(440)
        left_scroll.setMaximumWidth(480)
        main_layout.addWidget(left_scroll, 0)

        # --- Mode toggle -------------------------------------------------
        mode_row = QHBoxLayout()
        self.ss_radio = QRadioButton("Set Shaft Spacing")
        self.sd_radio = QRadioButton("Set Shell Diameter")
        self.sd_radio.setChecked(DEFAULTS["mode"] == "sd")
        self.ss_radio.setChecked(DEFAULTS["mode"] != "sd")
        self.mode_group = QButtonGroup(self)
        self.mode_group.addButton(self.ss_radio)
        self.mode_group.addButton(self.sd_radio)
        self.ss_radio.toggled.connect(self._on_mode_changed)
        mode_row.addWidget(self.ss_radio)
        mode_row.addWidget(self.sd_radio)
        mode_row.addStretch()
        self.reset_btn = QPushButton("Return to Defaults")
        self.reset_btn.setToolTip(
            "Set Shell Diameter mode (130 mm), 1000 RPM, rotor height 100 mm,\n"
            "Averaged method and the default 3-lobe parameters.\n"
            "The Units choice is kept.")
        self.reset_btn.clicked.connect(self._return_to_defaults)
        mode_row.addWidget(self.reset_btn)
        left_panel.addLayout(mode_row)

        # --- Settings shared by both tabs -------------------------------
        settings_box = QGroupBox("Settings")
        sform = QFormLayout(settings_box)
        sform.setVerticalSpacing(3)
        sform.setContentsMargins(8, 4, 8, 4)

        self.method_combo = QComboBox()
        for key, label in METHODS.items():
            self.method_combo.addItem(label, key)
        self.method_combo.setCurrentIndex(0)  # Averaged (paper Eqs 5-6)
        self.method_combo.setToolTip(
            "Averaged: fixed-ratio construction of the paper (default).\n"
            "Noslip rolling: circle rolls without slip on the pitch curve.")
        sform.addRow("Profile Method", self.method_combo)

        self.input_combo = QComboBox()
        for key, (label, unit) in INPUT_KINDS.items():
            self.input_combo.addItem(f"{label} ({unit})", key)
        self.input_combo.setToolTip(
            "Which clearance value you enter. The other two are computed:\n"
            "with Min Gap or Max Angle Dev the offset is solved for.")
        sform.addRow("Design Input", self.input_combo)

        self.units_combo = QComboBox()
        self.units_combo.addItems(["SI", "Imperial"])
        self.units_combo.setCurrentText("SI")
        self.units_combo.setToolTip(
            "SI: flow in CMM (m^3/min), velocity in m/s.\n"
            "Imperial: flow in CFM, velocity in ft/min.\n"
            "Dimensions are always entered in mm.")
        sform.addRow("Units", self.units_combo)

        self.rpm_field = QDoubleSpinBox()
        self.rpm_field.setRange(1, 100000)
        self.rpm_field.setDecimals(0)
        self.rpm_field.setSingleStep(100)
        self.rpm_field.setValue(1000)
        sform.addRow("Rotor Speed (RPM)", self.rpm_field)

        self.outlet_field = QDoubleSpinBox()
        self.outlet_field.setRange(1, 2000)
        self.outlet_field.setDecimals(1)
        self.outlet_field.setValue(51.0)
        self.outlet_field.setToolTip(
            "Diameter of the discharge opening, used to convert net flow\n"
            "to mean outlet velocity.")
        sform.addRow("Outlet Diameter (mm)", self.outlet_field)

        self.method_combo.currentIndexChanged.connect(self._mark_modified)
        self.input_combo.currentIndexChanged.connect(self._on_input_kind_changed)
        self.units_combo.currentTextChanged.connect(self._mark_modified)
        self.rpm_field.valueChanged.connect(self._mark_modified)
        self.outlet_field.valueChanged.connect(self._mark_modified)
        left_panel.addWidget(settings_box)

        # --- Tabs ----------------------------------------------------------
        self.tabs = QTabWidget()
        left_panel.addWidget(self.tabs, 1)
        self.tabs.addTab(self._build_interactive_tab(), "Interactive")
        self.tabs.addTab(self._build_batch_tab(), "Batch")

        # --- Plot panel ------------------------------------------------
        plot_box = QGroupBox("Rotor Profiles at Rotation Angles")
        plot_layout = QVBoxLayout(plot_box)
        self.fig = Figure(figsize=(11, 7))
        self.axes = self.fig.subplots(2, 3)
        self.canvas = FigureCanvasQTAgg(self.fig)
        plot_layout.addWidget(self.canvas)
        main_layout.addWidget(plot_box, 1)

    def _build_interactive_tab(self):
        tab = QWidget()
        layout = QVBoxLayout(tab)

        # --- Parameters ---
        params_box = QGroupBox("Parameters")
        form = QFormLayout(params_box)
        form.setVerticalSpacing(3)
        form.setContentsMargins(8, 4, 8, 4)

        self.lobes_spin = QSpinBox()
        self.lobes_spin.setRange(2, 10)
        self.lobes_spin.setValue(3)
        form.addRow("Lobes", self.lobes_spin)

        self.ex_field = QDoubleSpinBox()
        self.ex_field.setRange(0, 0.5)
        self.ex_field.setDecimals(3)
        self.ex_field.setSingleStep(0.01)
        self.ex_field.setValue(0.245)
        form.addRow("Eccentricity (ex)", self.ex_field)

        # Holds the offset, min gap or max angle dev (Settings > Design Input)
        self.offset_field = QDoubleSpinBox()
        lo, hi, dec = INPUT_FIELD_RANGES["offset"]
        self.offset_field.setRange(lo, hi)
        self.offset_field.setDecimals(dec)
        self.offset_field.setValue(INPUT_DEFAULTS["offset"])
        self.offset_label = QLabel("Offset (mm)")
        form.addRow(self.offset_label, self.offset_field)

        self.rotor_h_field = QDoubleSpinBox()
        self.rotor_h_field.setRange(1, 1e6)
        self.rotor_h_field.setDecimals(1)
        self.rotor_h_field.setValue(100)
        form.addRow("Rotor Height (mm)", self.rotor_h_field)

        self.shellgap_field = QDoubleSpinBox()
        self.shellgap_field.setRange(0, 1e4)
        self.shellgap_field.setDecimals(1)
        self.shellgap_field.setValue(2)
        form.addRow("Shell Gap (mm)", self.shellgap_field)

        self.ss_field = QDoubleSpinBox()
        self.ss_field.setRange(1, 1e6)
        self.ss_field.setDecimals(1)
        self.ss_field.setValue(80.4)
        self.switch_label = QLabel("Shaft Spacing (mm)")
        form.addRow(self.switch_label, self.ss_field)

        self.points_combo = QComboBox()
        self.points_combo.addItems(["180", "360", "720", "1001"])
        self.points_combo.setCurrentText("1001")
        form.addRow("Points", self.points_combo)

        for w in (self.lobes_spin, self.ex_field, self.offset_field,
                  self.rotor_h_field, self.shellgap_field, self.ss_field):
            w.valueChanged.connect(self._mark_modified)
        self.points_combo.currentTextChanged.connect(self._mark_modified)

        layout.addWidget(params_box)

        # --- Buttons row ---
        btn_row = QHBoxLayout()
        self.compute_btn = QPushButton("Compute")
        self.compute_btn.setStyleSheet(
            "font-weight: bold; background-color: #3378CC; color: white;")
        self.compute_btn.clicked.connect(self._on_compute_clicked)
        btn_row.addWidget(self.compute_btn)

        self.export_spline_btn = QPushButton("Export Spline")
        self.export_spline_btn.clicked.connect(self._on_export_spline_clicked)
        btn_row.addWidget(self.export_spline_btn)

        self.status_label = QLabel("")
        btn_row.addWidget(self.status_label, 1)
        layout.addLayout(btn_row)

        # --- Results panel ---
        results_box = QGroupBox("Results")
        grid = QGridLayout(results_box)
        grid.setVerticalSpacing(1)
        grid.setContentsMargins(8, 4, 8, 4)
        self.result_name_labels = []
        self.result_value_labels = []
        for i in range(N_RESULT_ROWS):
            name_lbl = QLabel("")
            val_lbl = QLabel("")
            grid.addWidget(name_lbl, i, 0)
            grid.addWidget(val_lbl, i, 1)
            self.result_name_labels.append(name_lbl)
            self.result_value_labels.append(val_lbl)
        self._clear_results()
        layout.addWidget(results_box)
        layout.addStretch()
        return tab

    def _build_batch_tab(self):
        tab = QWidget()
        layout = QVBoxLayout(tab)

        self.batch_input_table = QTableWidget(0, len(BATCH_INPUT_HEADERS))
        self.batch_input_table.setHorizontalHeaderLabels(BATCH_INPUT_HEADERS)
        self.batch_input_table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeToContents)
        self.batch_input_table.horizontalHeader().setStretchLastSection(False)
        self.batch_input_table.itemChanged.connect(self._on_batch_input_item_changed)
        layout.addWidget(self.batch_input_table, 1)

        btn_row1 = QHBoxLayout()
        self.defaults_btn = QPushButton("Defaults")
        self.defaults_btn.clicked.connect(self._load_defaults)
        btn_row1.addWidget(self.defaults_btn)

        add_btn = QPushButton("Add Row")
        add_btn.clicked.connect(self._add_row)
        btn_row1.addWidget(add_btn)

        del_btn = QPushButton("Delete")
        del_btn.clicked.connect(self._delete_row)
        btn_row1.addWidget(del_btn)
        layout.addLayout(btn_row1)

        btn_row2 = QHBoxLayout()
        self.run_btn = run_btn = QPushButton("Run All")
        run_btn.setStyleSheet("font-weight: bold; background-color: #38993D; color: white;")
        run_btn.clicked.connect(self._run_all)
        btn_row2.addWidget(run_btn)

        plot_btn = QPushButton("Plot")
        plot_btn.setStyleSheet("font-weight: bold; background-color: #3378CC; color: white;")
        plot_btn.clicked.connect(self._plot_marked_profiles)
        btn_row2.addWidget(plot_btn)

        export_btn = QPushButton("Export")
        export_btn.clicked.connect(self._export_batch)
        btn_row2.addWidget(export_btn)
        layout.addLayout(btn_row2)

        self.batch_results_table = QTableWidget(0, len(BATCH_RESULT_HEADERS))
        self.batch_results_table.setHorizontalHeaderLabels(BATCH_RESULT_HEADERS)
        self.batch_results_table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeToContents)
        self.batch_results_table.horizontalHeader().setStretchLastSection(False)
        self.batch_results_table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.batch_results_table.itemSelectionChanged.connect(self._on_batch_result_row_selected)
        layout.addWidget(self.batch_results_table, 1)

        self.batch_status_label = QLabel("Load defaults or add rows to begin.")
        self.batch_status_label.setWordWrap(True)
        layout.addWidget(self.batch_status_label)

        return tab

    # ------------------------------------------------------------------
    #  Mode toggle / status helpers
    # ------------------------------------------------------------------
    def _mark_modified(self, *_args):
        if not hasattr(self, "status_label"):
            return
        self.status_label.setText("Modified")
        self.status_label.setStyleSheet("color: #CC8000;")

    def _return_to_defaults(self):
        d = DEFAULTS
        self.method_combo.setCurrentIndex(self.method_combo.findData(d["method"]))
        self.rpm_field.setValue(d["rpm"])
        self.outlet_field.setValue(d["outlet_d"])
        self.lobes_spin.setValue(d["lobes"])
        self.ex_field.setValue(d["ex"])
        self.input_combo.setCurrentIndex(self.input_combo.findData(d["input_kind"]))
        self.offset_field.setValue(d["offset"])
        self.rotor_h_field.setValue(d["rotor_H"])
        self.shellgap_field.setValue(d["shellgap"])
        self.points_combo.setCurrentText(d["points"])
        radio = self.sd_radio if d["mode"] == "sd" else self.ss_radio
        if radio.isChecked():
            self._on_mode_changed()  # still reset the field and clear results
        else:
            radio.setChecked(True)  # triggers _on_mode_changed
        self.status_label.setText("Defaults restored.")
        self.status_label.setStyleSheet("color: #595959;")

    def _input_kind(self):
        return self.input_combo.currentData()

    def _on_input_kind_changed(self, *_args):
        kind = self._input_kind()
        label, unit = INPUT_KINDS[kind]
        lo, hi, dec = INPUT_FIELD_RANGES[kind]
        self.offset_label.setText(f"{label} ({unit})")
        self.offset_field.setRange(lo, hi)
        self.offset_field.setDecimals(dec)
        self.offset_field.setValue(INPUT_DEFAULTS[kind])
        self.batch_input_table.setHorizontalHeaderItem(
            3, QTableWidgetItem(BATCH_INPUT_COL_NAMES[kind]))
        # Column 3 of the batch table changes meaning: clear the batch data.
        self.batch_input_table.setRowCount(0)
        self.batch_results_table.setRowCount(0)
        self.batch_xy_cache.clear()
        self.batch_node_cache.clear()
        self.batch_ss_cache.clear()
        self._clear_results()
        self._mark_modified()

    def _result_layout(self):
        """Row names and styles of the Results panel, with blank values."""
        blank = dict(offset=0, min_gap=0, avg_gap=0, max_angle_dev=0,
                     shell_d=0, lobe_rmax=0, lobe_rmin=0, lobe_w=0,
                     lambda_r=0, lambda_w=0, area_eff=0, CMM_loss=0,
                     CMM_net=0, velocity_mps=0, rpm=self.rpm_field.value())
        return format_results(blank, 0, self.units_combo.currentText(),
                              self._input_kind(),
                              "sd" if self._is_sd_mode() else "ss")

    def _show_results(self, rows):
        for i, ((name, val, style), nlbl, vlbl) in enumerate(
                zip(rows, self.result_name_labels, self.result_value_labels)):
            nlbl.setText(name)
            vlbl.setText(val)
            top = "" if i == 0 else " padding-top: 4px;"
            if style == "header":
                nlbl.setStyleSheet(f"font-weight: bold; color: #222222;{top}")
                vlbl.setStyleSheet("")
                continue
            nlbl.setStyleSheet("color: %s; padding-left: 10px;"
                               % (BLUE if style == "solved" else "#595959"))
            color = {"solved": BLUE, "bad": RED}.get(style, "black")
            size = " font-size: 14px;" if name == "Flow Net" else ""
            vlbl.setStyleSheet(f"font-weight: bold; color: {color};{size}")

    def _clear_results(self):
        rows = [(n, "" if s == "header" else "—", s)
                for n, _, s in self._result_layout()]
        self._show_results(rows)

    def _is_sd_mode(self):
        return self.sd_radio.isChecked()

    def _on_mode_changed(self):
        if self._is_sd_mode():
            self.switch_label.setText("Shell Diameter (mm)")
            self.ss_field.setRange(1, 1e6)
            self.ss_field.setValue(DEFAULTS["shell_d"])
            self.batch_input_table.setHorizontalHeaderItem(6, QTableWidgetItem("shell_d"))
        else:
            self.switch_label.setText("Shaft Spacing (mm)")
            self.ss_field.setRange(1, 1e6)
            self.ss_field.setValue(DEFAULTS["ss"])
            self.batch_input_table.setHorizontalHeaderItem(6, QTableWidgetItem("ss"))

        self._clear_results()

        self.batch_input_table.setRowCount(0)
        self.batch_results_table.setRowCount(0)
        self.batch_xy_cache.clear()
        self.batch_node_cache.clear()
        self.batch_ss_cache.clear()
        self._mark_modified()

    # ------------------------------------------------------------------
    #  Interactive tab: Compute
    # ------------------------------------------------------------------
    def _gather_interactive_params(self):
        return {
            "nodes": self.lobes_spin.value(),
            "ex": self.ex_field.value(),
            "input_kind": self._input_kind(),
            "input_value": self.offset_field.value(),
            "rotor_H": self.rotor_h_field.value(),
            "shellgap": self.shellgap_field.value(),
            "ss_or_shelld": self.ss_field.value(),
            "points": int(self.points_combo.currentText()),
            "mode": "sd" if self._is_sd_mode() else "ss",
            **self._gather_settings(),
        }

    def _gather_settings(self):
        return {
            "input_kind": self._input_kind(),
            "method": self.method_combo.currentData(),
            "rpm": self.rpm_field.value(),
            "outlet_d": self.outlet_field.value(),
        }

    def _on_compute_clicked(self):
        params = self._gather_interactive_params()
        self.compute_btn.setEnabled(False)
        self.status_label.setText("Computing…")
        self.status_label.setStyleSheet("color: #595959;")
        QApplication.setOverrideCursor(Qt.WaitCursor)

        worker = ComputeWorker(params)
        worker.computed.connect(self._on_compute_finished)
        worker.failed.connect(self._on_compute_failed)
        # Delete the thread object only once the thread has stopped.
        worker.finished.connect(self._on_compute_thread_done)
        self._compute_worker = worker
        worker.start()

    def _on_compute_thread_done(self):
        worker = self.sender()
        if worker is self._compute_worker:
            self._compute_worker = None
        if worker is not None:
            worker.deleteLater()

    def closeEvent(self, event):
        # Stop worker threads before the window (and Python) goes away: a
        # QThread object destroyed while its thread still runs aborts the
        # whole process.
        if self._batch_worker is not None:
            self._batch_worker.cancel()
            self._batch_worker.wait()
        if self._compute_worker is not None:
            self._compute_worker.cancel()
            self._compute_worker.wait()
        super().closeEvent(event)

    def _on_compute_finished(self, r):
        QApplication.restoreOverrideCursor()
        self.compute_btn.setEnabled(True)

        nodes = r["nodes"]
        ss = r["ss"]
        units = self.units_combo.currentText()

        self._show_results(format_results(r, ss, units, r["input_kind"],
                                          r["mode"]))

        self.last_xy = r["xy"]
        self.last_nodes = nodes
        self.last_ss = ss
        self._plot_profiles(r["xy"], nodes, ss)

        self.status_label.setToolTip(r.get("solve_note") or "")
        if r["interfere"]:
            self.status_label.setText("Lobes interfere.")
            self.status_label.setStyleSheet(f"color: {RED}; font-weight: bold;")
        elif r.get("solve_note"):
            self.status_label.setText("Target not exact (see message)")
            self.status_label.setStyleSheet(f"color: {RED}; font-weight: bold;")
            QMessageBox.information(self, "Compute", r["solve_note"])
        else:
            self.status_label.setText("Done.")
            self.status_label.setStyleSheet("color: #339933;")

    def _on_compute_failed(self, message):
        QApplication.restoreOverrideCursor()
        self.compute_btn.setEnabled(True)
        # No valid result: blank every value, in red, so nothing from an
        # earlier run can be mistaken for this one.
        rows = [(n, "" if s == "header" else "\u2014", s if s == "header" else "bad")
                for n, _, s in self._result_layout()]
        self._show_results(rows)
        self.last_xy = None
        self.status_label.setText("Error (see message)")
        self.status_label.setToolTip(message)
        self.status_label.setStyleSheet(f"color: {RED}; font-weight: bold;")
        QMessageBox.warning(self, "Compute", message)

    # ------------------------------------------------------------------
    #  Plotting
    # ------------------------------------------------------------------
    def _plot_profiles(self, xy, nodes, ss):
        starta = 0
        startb = 180 + 180 / nodes
        ang_delta = (180 / nodes) / 5
        maxR = np.max(np.abs(xy)) + ss / 2 + 10

        for idx, ax in enumerate(self.axes.flat):
            ax.cla()
            ang = idx * ang_delta
            r1 = rotate_shift(xy, starta + ang, [-ss / 2, 0])
            r2 = rotate_shift(xy, startb - ang, [ss / 2, 0])
            ax.plot(r1[:, 0], r1[:, 1], "-", color=(0.15, 0.35, 0.70), linewidth=1.2)
            ax.plot(r2[:, 0], r2[:, 1], "-", color=(0.75, 0.22, 0.17), linewidth=1.2)
            ax.set_aspect("equal")
            ax.set_xlim(-maxR, maxR)
            ax.set_ylim(-maxR * 0.70, maxR * 0.70)
            ax.set_title(f"{ang:.1f} deg", fontsize=10)
            ax.grid(True, alpha=0.15)

        self.fig.tight_layout()
        self.canvas.draw_idle()

    def _plot_marked_profiles(self):
        if self.batch_input_table.rowCount() == 0:
            self.batch_status_label.setText("No rows to plot.")
            return
        if not self.batch_xy_cache:
            self.batch_status_label.setText("Run batch first, then plot.")
            return

        marked = [row for row in range(self.batch_input_table.rowCount())
                  if self._row_plot_checked(row) and row in self.batch_xy_cache]
        if not marked:
            self.batch_status_label.setText("No row marked Plot? = Yes.")
            return

        first_nodes = self.batch_node_cache[marked[0]]
        ang_delta = (180 / first_nodes) / 5

        maxR = 0.0
        for row in marked:
            xy = self.batch_xy_cache[row]
            ss = self.batch_ss_cache[row]
            maxR = max(maxR, np.max(np.abs(xy)) + ss / 2 + 10)

        for ax in self.axes.flat:
            ax.cla()

        for m, row in enumerate(marked):
            xy = self.batch_xy_cache[row]
            nodes = self.batch_node_cache[row]
            ss = self.batch_ss_cache[row]
            col = PALETTE[m % len(PALETTE)]
            starta = 0
            startb = 180 + 180 / nodes
            for idx, ax in enumerate(self.axes.flat):
                ang = idx * ang_delta
                r1 = rotate_shift(xy, starta + ang, [-ss / 2, 0])
                r2 = rotate_shift(xy, startb - ang, [ss / 2, 0])
                ax.plot(r1[:, 0], r1[:, 1], "-", color=col, linewidth=1.2)
                ax.plot(r2[:, 0], r2[:, 1], "-", color=col, linewidth=1.2)

        for idx, ax in enumerate(self.axes.flat):
            ax.set_aspect("equal")
            ax.set_xlim(-maxR, maxR)
            ax.set_ylim(-maxR * 0.70, maxR * 0.70)
            ang = idx * ang_delta
            ax.set_title(f"{ang:.1f} deg", fontsize=10)
            ax.grid(True, alpha=0.15)

        self.fig.tight_layout()
        self.canvas.draw_idle()
        self.batch_status_label.setText(f"Plotted {len(marked)} marked profile(s).")

    # ------------------------------------------------------------------
    #  Export Spline
    # ------------------------------------------------------------------
    def _on_export_spline_clicked(self):
        if self.last_xy is None:
            QMessageBox.warning(self, "Export", "No profile computed yet. Press Compute first.")
            return
        path, _ = QFileDialog.getSaveFileName(self, "Export Spline Points", "", "CSV Files (*.csv)")
        if not path:
            return
        scale = 10.0
        xy = self.last_xy
        out = np.round(np.column_stack([xy / scale, np.zeros(xy.shape[0])]) * 1000) / 1000
        np.savetxt(path, out, delimiter=",", fmt="%.3f")
        self.status_label.setText(f"Spline -> {path}")
        self.status_label.setStyleSheet("color: #339933;")

    # ------------------------------------------------------------------
    #  Batch tab
    # ------------------------------------------------------------------
    def _row_plot_checked(self, row):
        item = self.batch_input_table.item(row, 0)
        return item is not None and item.checkState() == Qt.Checked

    def _set_batch_row(self, row, plot_flag, values):
        self.batch_input_table.blockSignals(True)
        check_item = QTableWidgetItem()
        check_item.setFlags(Qt.ItemIsUserCheckable | Qt.ItemIsEnabled | Qt.ItemIsSelectable)
        check_item.setCheckState(Qt.Checked if plot_flag else Qt.Unchecked)
        self.batch_input_table.setItem(row, 0, check_item)
        for col, v in enumerate(values, start=1):
            self.batch_input_table.setItem(row, col, QTableWidgetItem(str(v)))
        self.batch_input_table.blockSignals(False)

    def _on_batch_input_item_changed(self, item):
        if item.column() != 0:
            return
        if item.checkState() != Qt.Checked:
            return
        self.batch_input_table.blockSignals(True)
        for row in range(self.batch_input_table.rowCount()):
            if row == item.row():
                continue
            other = self.batch_input_table.item(row, 0)
            if other is not None:
                other.setCheckState(Qt.Unchecked)
        self.batch_input_table.blockSignals(False)

    def _load_defaults(self):
        if self._is_sd_mode():
            rows, what = DEFAULT_BATCH_ROWS_SD, "130 mm housing (paper Table 3)"
        else:
            rows, what = DEFAULT_BATCH_ROWS, "80.4 mm shaft spacing (paper Table 1)"
        kind = self._input_kind()
        if kind != "offset":
            # Same cases, with the chosen design input in column 3.
            rows = [r[:2] + (INPUT_DEFAULTS[kind],) + r[3:] for r in rows]
            label, unit = INPUT_KINDS[kind]
            what += f", {label} {INPUT_DEFAULTS[kind]:g} {unit}"
        self.batch_input_table.setRowCount(len(rows))
        for i, row_vals in enumerate(rows):
            self._set_batch_row(i, i == len(rows) - 1, row_vals)
        self.batch_status_label.setText(f"{len(rows)} default rows loaded: {what}.")

    def _add_row(self):
        p = self._gather_interactive_params()
        row = self.batch_input_table.rowCount()
        self.batch_input_table.insertRow(row)
        self._set_batch_row(row, False, [
            p["nodes"], p["ex"], p["input_value"], p["rotor_H"],
            p["shellgap"], p["ss_or_shelld"], p["points"],
        ])
        self.batch_status_label.setText("Row added.")

    def _delete_row(self):
        n = self.batch_input_table.rowCount()
        if n == 0:
            return
        row = self.batch_input_table.currentRow()
        if row < 0:
            row = n - 1
        self.batch_input_table.removeRow(row)
        self.batch_status_label.setText("Row deleted.")

    def _read_batch_rows(self):
        rows = []
        n = self.batch_input_table.rowCount()
        for r in range(n):
            try:
                vals = [float(self.batch_input_table.item(r, c).text()) for c in range(1, 8)]
            except (ValueError, AttributeError) as exc:
                raise ValueError(f"Row {r + 1}: invalid number ({exc})") from exc
            rows.append({
                "nodes": int(vals[0]), "ex": vals[1], "input": vals[2],
                "rotor_H": vals[3], "shellgap": vals[4], "col6": vals[5],
                "points": int(vals[6]),
            })
        return rows

    def _run_all(self):
        if self._batch_worker is not None:
            return  # a batch is already running
        if self.batch_input_table.rowCount() == 0:
            self.batch_status_label.setText("No rows. Load defaults or add rows.")
            return
        try:
            rows = self._read_batch_rows()
        except ValueError as exc:
            QMessageBox.warning(self, "Run All", str(exc))
            return

        self.batch_results_table.setRowCount(len(rows))
        self.batch_xy_cache.clear()
        self.batch_node_cache.clear()
        self.batch_ss_cache.clear()

        self._batch_progress_dlg = QProgressDialog("Starting…", "Cancel", 0, len(rows), self)
        self._batch_progress_dlg.setWindowTitle("Batch Processing")
        self._batch_progress_dlg.setWindowModality(Qt.WindowModal)
        self._batch_progress_dlg.setMinimumDuration(0)

        mode = "sd" if self._is_sd_mode() else "ss"
        self._batch_settings = dict(self._gather_settings(),
                                    units=self.units_combo.currentText())
        self._batch_errors = []
        self._batch_worker = BatchWorker(rows, mode, self._batch_settings)
        self._batch_worker.rowDone.connect(self._on_batch_row_done)
        self._batch_worker.progress.connect(self._on_batch_progress)
        self._batch_worker.finished.connect(self._on_batch_finished)
        self._batch_progress_dlg.canceled.connect(self._batch_worker.cancel)
        self.run_btn.setEnabled(False)
        self._batch_worker.start()

    def _on_batch_progress(self, done, total):
        if self._batch_progress_dlg is not None:
            self._batch_progress_dlg.setLabelText(f"Set {done} / {total} …")
            self._batch_progress_dlg.setValue(done)

    def _on_batch_row_done(self, row, r):
        units = self._batch_settings["units"]
        if not isinstance(r, dict):
            # Failed row: every cell says "error" in red; hover for the reason.
            for c in range(len(BATCH_RESULT_HEADERS)):
                item = QTableWidgetItem("error")
                item.setForeground(QColor(RED))
                item.setToolTip(str(r))
                self.batch_results_table.setItem(row, c, item)
            self._batch_errors.append(row + 1)
            return
        else:
            fl = flow_from_cmm(r["CMM_loss"], units)
            fn = flow_from_cmm(r["CMM_net"], units)
            vel = velocity_from_mps(r["velocity_mps"], units)
            values = [r["offset"], r["min_gap"], r["avg_gap"], r["max_angle_dev"],
                      r["ss"], r["shell_d"], r["lobe_rmax"], r["lobe_rmin"],
                      r["lobe_w"], r["lambda_r"], r["lambda_w"], r["area_eff"],
                      vel, fl, fn]
            self.batch_xy_cache[row] = r["xy"]
            self.batch_node_cache[row] = r["nodes"]
            self.batch_ss_cache[row] = r["ss"]

        bad = r["interfere"]
        note = r.get("solve_note")
        kind_col = BATCH_KIND_COL.get(r["input_kind"])
        for c, v in enumerate(values):
            item = QTableWidgetItem("nan" if v != v else f"{v:.4f}")
            if (bad and c in BATCH_BAD_COLS) or (note and c == kind_col):
                item.setForeground(QColor(RED))
            if note and c == kind_col:
                item.setToolTip(note)
            self.batch_results_table.setItem(row, c, item)
        if note:
            self._batch_errors.append(row + 1)

    def _on_batch_finished(self):
        worker, self._batch_worker = self._batch_worker, None
        # Read before closing the progress dialog: closing it emits canceled.
        cancelled = worker is not None and worker._cancelled
        if worker is not None:
            worker.deleteLater()
        if self._batch_progress_dlg is not None:
            self._batch_progress_dlg.close()
            self._batch_progress_dlg = None
        self.run_btn.setEnabled(True)
        n = self.batch_input_table.rowCount()
        msg = f"Done — {n} sets.  Select Plot? then press Plot."
        if cancelled:
            msg = "Batch cancelled."
        if self._batch_errors:
            rows = ", ".join(str(k) for k in sorted(self._batch_errors))
            msg = (f"Done — {n} sets. Row(s) {rows} failed or missed the "
                   f"target (red; hover a cell for the reason).")
        self._plot_marked_profiles()
        self.batch_status_label.setText(msg)

    def _on_batch_result_row_selected(self):
        rows = self.batch_results_table.selectionModel().selectedRows()
        if not rows:
            return
        row = rows[0].row()
        if row not in self.batch_xy_cache:
            return
        self._plot_profiles(self.batch_xy_cache[row], self.batch_node_cache[row],
                             self.batch_ss_cache[row])
        self.batch_status_label.setText(f"Showing row {row + 1}.")

    def _export_batch(self):
        if self.batch_results_table.rowCount() == 0:
            QMessageBox.warning(self, "Export", "No results. Run batch first.")
            return
        path, _ = QFileDialog.getSaveFileName(self, "Export Batch Results", "", "CSV Files (*.csv)")
        if not path:
            return

        col6_hdr = "shell_d_input" if self._is_sd_mode() else "ss_input"
        st = getattr(self, "_batch_settings", None) or dict(
            self._gather_settings(), units=self.units_combo.currentText())
        fu, vu = flow_units(st["units"]), velocity_units(st["units"])
        result_hdrs = [h if h not in ("Flow_Loss", "Flow_Net", "Velocity")
                       else f"{h}_{fu if h != 'Velocity' else vu.replace('/', '_')}"
                       for h in BATCH_RESULT_HEADERS]
        in_hdr = BATCH_INPUT_COL_NAMES[st["input_kind"]] + "_input"
        headers = (["Lobes", "ex", in_hdr, "rotor_H", "shellgap", col6_hdr, "points"]
                   + result_hdrs + ["method", "rpm", "outlet_d"])

        with open(path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(headers)
            for r in range(self.batch_input_table.rowCount()):
                in_vals = [self.batch_input_table.item(r, c).text() for c in range(1, 8)]
                out_vals = []
                for c in range(self.batch_results_table.columnCount()):
                    item = self.batch_results_table.item(r, c)
                    out_vals.append(item.text() if item is not None else "")
                writer.writerow(in_vals + out_vals
                                + [METHODS[st["method"]], st["rpm"], st["outlet_d"]])

        self.batch_status_label.setText(f"Saved: {path}")


def main():
    app = QApplication(sys.argv)
    win = RootsProfileWindow()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
