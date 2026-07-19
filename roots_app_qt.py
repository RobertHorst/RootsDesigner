"""PySide6 GUI port of RootsProfileApp.m — full feature parity with the
MATLAB App Designer app: mode toggle (shaft spacing / shell diameter),
Interactive tab (parameters, Compute, Export Spline, 12-row Results panel,
six-angle rotor mesh plot), and Batch tab (editable parameter table, Load
Defaults, Add/Delete row, Run All, Plot marked rows, Export CSV).

The math is unchanged from roots_profile.py (the vectorized NumPy/SciPy
core) — this module only adds the GUI.

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
from scipy.optimize import brentq

from roots_profile import flow_convert, lobe_rmax_from_ss, roots_compute, rotate_shift

APP_NAME = "Roots Profile Designer"
APP_VENDOR = "Horst Tech LLC"
VERSION = "0.3.0"
VERSION_DATE = "2026-07-17"

RESULT_NAMES = [
    "Shaft Spacing", "Lobe Rmax", "Lobe Rmin", "Lobe Width",
    "Shell Diameter", "Area Efficiency", "Lambda",
    "Min Gap", "Avg Gap", "Max Angle Dev", "Flow Loss", "Flow Net",
]

BATCH_INPUT_HEADERS = ["Plot?", "Lobes", "ex", "offset", "rotor_H", "shell_gap", "ss", "points"]
BATCH_RESULT_HEADERS = [
    "SS", "Rmax", "Rmin", "Width", "Shell_D", "Area_Eff",
    "Flow_Loss", "Flow_Net", "Min_Gap", "Avg_Gap", "Max_Angle_Dev", "Lambda",
]

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

PALETTE = [
    (0.15, 0.35, 0.70), (0.85, 0.25, 0.15), (0.20, 0.65, 0.30),
    (0.85, 0.55, 0.10), (0.55, 0.25, 0.70), (0.10, 0.60, 0.65),
    (0.85, 0.40, 0.55), (0.40, 0.40, 0.40),
]


def _solve_ss_for_shell_d(nodes, ex, offset, shellgap, shell_d_target, points):
    """Solve for shaft spacing that yields the target shell diameter."""
    target_rmax = shell_d_target / 2 - shellgap
    if target_rmax <= 0:
        raise ValueError("Shell diameter too small for shell gap.")

    def f(ss_val):
        return lobe_rmax_from_ss(nodes, ex, offset, ss_val, points) - target_rmax

    ss_lo = max(2 * offset + 1, 5)
    ss_hi = shell_d_target * 2
    return brentq(f, ss_lo, ss_hi)


class ComputeWorker(QThread):
    """Runs one rootsCompute (with optional shaft-spacing solve) off the UI thread."""

    finished = Signal(dict)
    failed = Signal(str)

    def __init__(self, params, parent=None):
        super().__init__(parent)
        self.params = params

    def run(self):
        p = self.params
        try:
            if p["mode"] == "sd":
                ss = _solve_ss_for_shell_d(
                    p["nodes"], p["ex"], p["offset"], p["shellgap"],
                    p["ss_or_shelld"], p["points"])
            else:
                ss = p["ss_or_shelld"]

            r = roots_compute(p["nodes"], p["ex"], p["offset"], p["rotor_H"],
                               p["shellgap"], ss, p["points"])
            r["ss"] = ss
            r["nodes"] = p["nodes"]
            self.finished.emit(r)
        except Exception as exc:  # noqa: BLE001 — surface any failure to the UI
            self.failed.emit(str(exc))


class BatchWorker(QThread):
    """Runs a list of parameter sets sequentially, reporting per-row progress."""

    rowDone = Signal(int, object)  # row index, result dict or None on failure
    progress = Signal(int, int)  # completed, total
    finished = Signal()

    def __init__(self, rows, mode, parent=None):
        super().__init__(parent)
        self.rows = rows  # list of dicts: nodes, ex, offset, rotor_H, shellgap, col6, points
        self.mode = mode
        self._cancelled = False

    def cancel(self):
        self._cancelled = True

    def run(self):
        n = len(self.rows)
        for i, row in enumerate(self.rows):
            if self._cancelled:
                break
            try:
                if self.mode == "sd":
                    ss = _solve_ss_for_shell_d(
                        row["nodes"], row["ex"], row["offset"], row["shellgap"],
                        row["col6"], row["points"])
                else:
                    ss = row["col6"]
                r = roots_compute(row["nodes"], row["ex"], row["offset"],
                                   row["rotor_H"], row["shellgap"], ss, row["points"])
                r["ss"] = ss
                r["nodes"] = row["nodes"]
                self.rowDone.emit(i, r)
            except Exception:  # noqa: BLE001 — mark row as failed, keep going
                self.rowDone.emit(i, None)
            self.progress.emit(i + 1, n)
        self.finished.emit()


class RootsProfileWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(f"{APP_NAME}  v{VERSION}  —  {APP_VENDOR}")
        self.resize(1460, 870)

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
        left_widget.setMinimumWidth(420)
        left_widget.setMaximumWidth(460)
        left_panel = QVBoxLayout(left_widget)
        main_layout.addWidget(left_widget, 0)

        # --- Mode toggle -------------------------------------------------
        mode_row = QHBoxLayout()
        self.ss_radio = QRadioButton("Set Shaft Spacing")
        self.sd_radio = QRadioButton("Set Shell Diameter")
        self.ss_radio.setChecked(True)
        self.mode_group = QButtonGroup(self)
        self.mode_group.addButton(self.ss_radio)
        self.mode_group.addButton(self.sd_radio)
        self.ss_radio.toggled.connect(self._on_mode_changed)
        mode_row.addWidget(self.ss_radio)
        mode_row.addWidget(self.sd_radio)
        mode_row.addStretch()
        left_panel.addLayout(mode_row)

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

        self.offset_field = QDoubleSpinBox()
        self.offset_field.setRange(0.01, 15)
        self.offset_field.setDecimals(2)
        self.offset_field.setValue(2.72)
        form.addRow("Offset (mm)", self.offset_field)

        self.rotor_h_field = QDoubleSpinBox()
        self.rotor_h_field.setRange(1, 1000)
        self.rotor_h_field.setDecimals(1)
        self.rotor_h_field.setValue(100)
        form.addRow("Rotor Height (mm)", self.rotor_h_field)

        self.shellgap_field = QDoubleSpinBox()
        self.shellgap_field.setRange(0, 20)
        self.shellgap_field.setDecimals(1)
        self.shellgap_field.setValue(2)
        form.addRow("Shell Gap (mm)", self.shellgap_field)

        self.ss_field = QDoubleSpinBox()
        self.ss_field.setRange(10, 300)
        self.ss_field.setDecimals(1)
        self.ss_field.setValue(80.4)
        self.switch_label = QLabel("Shaft Spacing (mm)")
        form.addRow(self.switch_label, self.ss_field)

        self.points_combo = QComboBox()
        self.points_combo.addItems(["180", "360", "720", "1001"])
        self.points_combo.setCurrentText("1001")
        form.addRow("Points", self.points_combo)

        self.units_combo = QComboBox()
        self.units_combo.addItems(["CFM", "CMM", "CMH"])
        self.units_combo.setCurrentText("CMM")
        form.addRow("Flow Units (@ 1K RPM)", self.units_combo)

        for w in (self.lobes_spin, self.ex_field, self.offset_field,
                  self.rotor_h_field, self.shellgap_field, self.ss_field):
            w.valueChanged.connect(self._mark_modified)
        self.points_combo.currentTextChanged.connect(self._mark_modified)
        self.units_combo.currentTextChanged.connect(self._mark_modified)

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
        self.result_name_labels = []
        self.result_value_labels = []
        for i, name in enumerate(RESULT_NAMES):
            name_lbl = QLabel(name)
            name_lbl.setStyleSheet("color: #595959;")
            val_lbl = QLabel("—")
            val_lbl.setStyleSheet("font-weight: bold;")
            grid.addWidget(name_lbl, i, 0)
            grid.addWidget(val_lbl, i, 1)
            self.result_name_labels.append(name_lbl)
            self.result_value_labels.append(val_lbl)
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
        run_btn = QPushButton("Run All")
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
        layout.addWidget(self.batch_status_label)

        return tab

    # ------------------------------------------------------------------
    #  Mode toggle / status helpers
    # ------------------------------------------------------------------
    def _mark_modified(self, *_args):
        self.status_label.setText("Modified")
        self.status_label.setStyleSheet("color: #CC8000;")

    def _is_sd_mode(self):
        return self.sd_radio.isChecked()

    def _on_mode_changed(self):
        if self._is_sd_mode():
            self.switch_label.setText("Shell Diameter (mm)")
            self.ss_field.setRange(10, 1000)
            self.ss_field.setValue(130)
            self.batch_input_table.setHorizontalHeaderItem(6, QTableWidgetItem("shell_d"))
            self.defaults_btn.setEnabled(False)
        else:
            self.switch_label.setText("Shaft Spacing (mm)")
            self.ss_field.setRange(10, 300)
            self.ss_field.setValue(80.4)
            self.batch_input_table.setHorizontalHeaderItem(6, QTableWidgetItem("ss"))
            self.defaults_btn.setEnabled(True)

        for lbl in self.result_value_labels:
            lbl.setText("—")

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
            "offset": self.offset_field.value(),
            "rotor_H": self.rotor_h_field.value(),
            "shellgap": self.shellgap_field.value(),
            "ss_or_shelld": self.ss_field.value(),
            "points": int(self.points_combo.currentText()),
            "mode": "sd" if self._is_sd_mode() else "ss",
        }

    def _on_compute_clicked(self):
        params = self._gather_interactive_params()
        self.compute_btn.setEnabled(False)
        self.status_label.setText("Computing…")
        self.status_label.setStyleSheet("color: #595959;")
        QApplication.setOverrideCursor(Qt.WaitCursor)

        self._compute_worker = ComputeWorker(params)
        self._compute_worker.finished.connect(self._on_compute_finished)
        self._compute_worker.failed.connect(self._on_compute_failed)
        self._compute_worker.finished.connect(self._compute_worker.deleteLater)
        self._compute_worker.failed.connect(self._compute_worker.deleteLater)
        self._compute_worker.start()

    def _on_compute_finished(self, r):
        QApplication.restoreOverrideCursor()
        self.compute_btn.setEnabled(True)

        nodes = r["nodes"]
        ss = r["ss"]
        units = self.units_combo.currentText()
        fl = flow_convert(r["CFM_loss"], units)
        fn = flow_convert(r["CFM_net"], units)

        vals = [
            f"{ss:.2f} mm", f"{r['lobe_rmax']:.1f} mm", f"{r['lobe_rmin']:.1f} mm",
            f"{r['lobe_w']:.1f} mm", f"{r['shell_d']:.1f} mm", f"{r['area_eff']:.3f}",
            f"{r['lamb']:.3f}", f"{r['min_gap']:.2f} mm", f"{r['avg_gap']:.2f} mm",
            f"{r['max_angle_dev']:.3f} deg", f"{fl:.2f} {units}", f"{fn:.2f} {units}",
        ]
        for lbl, v in zip(self.result_value_labels, vals):
            lbl.setText(v)

        if self._is_sd_mode():
            self.result_name_labels[0].setStyleSheet("color: #1A4DB2;")
            self.result_value_labels[0].setStyleSheet("font-weight: bold; color: #1A4DB2;")
        else:
            self.result_name_labels[0].setStyleSheet("color: #595959;")
            self.result_value_labels[0].setStyleSheet("font-weight: bold; color: black;")

        self.last_xy = r["xy"]
        self.last_nodes = nodes
        self.last_ss = ss
        self._plot_profiles(r["xy"], nodes, ss)

        self.status_label.setText("Done.")
        self.status_label.setStyleSheet("color: #339933;")

    def _on_compute_failed(self, message):
        QApplication.restoreOverrideCursor()
        self.compute_btn.setEnabled(True)
        self.status_label.setText(f"Error: {message}")
        self.status_label.setStyleSheet("color: #D92626;")

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
        self.batch_input_table.setRowCount(len(DEFAULT_BATCH_ROWS))
        for i, row_vals in enumerate(DEFAULT_BATCH_ROWS):
            self._set_batch_row(i, i == len(DEFAULT_BATCH_ROWS) - 1, row_vals)
        self.batch_status_label.setText("20 default rows loaded.")

    def _add_row(self):
        p = self._gather_interactive_params()
        row = self.batch_input_table.rowCount()
        self.batch_input_table.insertRow(row)
        self._set_batch_row(row, False, [
            p["nodes"], p["ex"], p["offset"], p["rotor_H"],
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
                "nodes": int(vals[0]), "ex": vals[1], "offset": vals[2],
                "rotor_H": vals[3], "shellgap": vals[4], "col6": vals[5],
                "points": int(vals[6]),
            })
        return rows

    def _run_all(self):
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
        self._batch_worker = BatchWorker(rows, mode)
        self._batch_worker.rowDone.connect(self._on_batch_row_done)
        self._batch_worker.progress.connect(self._on_batch_progress)
        self._batch_worker.finished.connect(self._on_batch_finished)
        self._batch_progress_dlg.canceled.connect(self._batch_worker.cancel)
        self._batch_worker.start()

    def _on_batch_progress(self, done, total):
        if self._batch_progress_dlg is not None:
            self._batch_progress_dlg.setLabelText(f"Set {done} / {total} …")
            self._batch_progress_dlg.setValue(done)

    def _on_batch_row_done(self, row, r):
        units = self.units_combo.currentText()
        if r is None:
            values = [float("nan")] * len(BATCH_RESULT_HEADERS)
        else:
            fl = flow_convert(r["CFM_loss"], units)
            fn = flow_convert(r["CFM_net"], units)
            values = [r["ss"], r["lobe_rmax"], r["lobe_rmin"], r["lobe_w"],
                      r["shell_d"], r["area_eff"], fl, fn, r["min_gap"],
                      r["avg_gap"], r["max_angle_dev"], r["lamb"]]
            self.batch_xy_cache[row] = r["xy"]
            self.batch_node_cache[row] = r["nodes"]
            self.batch_ss_cache[row] = r["ss"]

        for c, v in enumerate(values):
            item = QTableWidgetItem("nan" if v != v else f"{v:.4f}")
            self.batch_results_table.setItem(row, c, item)

    def _on_batch_finished(self):
        if self._batch_progress_dlg is not None:
            self._batch_progress_dlg.close()
            self._batch_progress_dlg = None
        n = self.batch_input_table.rowCount()
        self.batch_status_label.setText(
            f"Done — {n} sets.  Select Plot? then press Plot.")
        self._plot_marked_profiles()

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
        headers = (["Lobes", "ex", "offset", "rotor_H", "shellgap", col6_hdr, "points"]
                   + BATCH_RESULT_HEADERS)

        with open(path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(headers)
            for r in range(self.batch_input_table.rowCount()):
                in_vals = [self.batch_input_table.item(r, c).text() for c in range(1, 8)]
                out_vals = []
                for c in range(self.batch_results_table.columnCount()):
                    item = self.batch_results_table.item(r, c)
                    out_vals.append(item.text() if item is not None else "")
                writer.writerow(in_vals + out_vals)

        self.batch_status_label.setText(f"Saved: {path}")


def main():
    app = QApplication(sys.argv)
    win = RootsProfileWindow()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
