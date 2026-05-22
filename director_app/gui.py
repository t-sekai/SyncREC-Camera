from __future__ import annotations

import json
import queue
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from datetime import datetime
from pathlib import Path
from tkinter import Canvas, END, StringVar, Text, Tk, messagebox, ttk
from typing import Any

from .models import (
    parse_delay,
    parse_nonnegative_int,
    timecode_from_total_frames,
    timecode_text,
    yes_no,
)
from .server import DirectorServer
from .tentacle import TentacleReader
from .upload_server import UploadIngestServer, discover_advertised_host


CAPTURE_MODES = ("hd720p30", "hd1080p30", "hd1080p60", "uhd4k30", "uhd4k60")
CAPTURE_MODE_FILENAME_COMPONENTS = {
    "hd720p30": "720p30fps",
    "hd1080p30": "1080p30fps",
    "hd1080p60": "1080p60fps",
    "uhd4k30": "4k30fps",
    "uhd4k60": "4k60fps",
}
TAKE_NUMBERS_STATE_PATH = Path("director_app/state/take_numbers.json")
DEFAULT_PULL_CONCURRENCY = 3
MAX_PULL_CONCURRENCY = 8

DEVICE_COLUMNS = (
    "name",
    "device_id",
    "endpoint",
    "app",
    "armed",
    "recording",
    "battery",
    "storage",
    "videos",
    "mode",
    "actual_video",
    "tentacle",
    "timecode",
    "rig",
    "camera_params",
    "transfer",
    "preview",
    "preview_path",
    "last_seen",
    "pending",
)

DEVICE_DISPLAY_COLUMNS = (
    "name",
    "recording",
    "armed",
    "battery",
    "storage",
    "videos",
    "mode",
    "actual_video",
    "tentacle",
    "timecode",
    "rig",
    "camera_params",
    "transfer",
    "preview",
    "last_seen",
    "pending",
)

DEVICE_HEADINGS = {
    "name": "Camera",
    "device_id": "Device ID",
    "endpoint": "Endpoint",
    "app": "App",
    "armed": "Armed",
    "recording": "Recording",
    "battery": "Battery",
    "storage": "Free",
    "videos": "Videos",
    "mode": "Mode",
    "actual_video": "Actual Video",
    "tentacle": "Tentacle",
    "timecode": "Timecode",
    "rig": "Rig",
    "camera_params": "Camera Params",
    "transfer": "Transfer",
    "preview": "Preview",
    "preview_path": "Preview Path",
    "last_seen": "Seen",
    "pending": "Pending",
}

DEVICE_WIDTHS = {
    "name": 150,
    "device_id": 135,
    "endpoint": 150,
    "app": 110,
    "armed": 70,
    "recording": 92,
    "battery": 76,
    "storage": 82,
    "videos": 175,
    "mode": 105,
    "actual_video": 135,
    "tentacle": 125,
    "timecode": 145,
    "rig": 130,
    "camera_params": 215,
    "transfer": 210,
    "preview": 200,
    "preview_path": 260,
    "last_seen": 80,
    "pending": 220,
}


class DirectorGUI:
    def __init__(self, root: Tk):
        self.root = root
        self.root.title("Multi-Cam Director")
        self.root.geometry("1520x900")
        self.root.minsize(1180, 760)

        self.event_queue: queue.Queue[tuple[str, Any]] = queue.Queue()
        self.server = DirectorServer(self.event_queue)
        self.tentacle_reader = TentacleReader(self.event_queue)
        self.upload_server = UploadIngestServer(self.event_queue)

        self.host_var = StringVar(value="0.0.0.0")
        self.port_var = StringVar(value="8765")
        self.upload_host_var = StringVar(value="")
        self.upload_port_var = StringVar(value="8780")
        self._take_numbers_by_experiment: dict[str, int] = self._load_take_numbers()
        initial_experiment_name = self._load_last_experiment_name()
        self.experiment_name_var = StringVar(value=initial_experiment_name)
        self.take_number_var = StringVar(value=str(self._take_numbers_by_experiment.get(initial_experiment_name, 1)))
        self.start_delay_var = StringVar(value="2.0")
        self.stop_delay_var = StringVar(value="2.0")
        self.tentacle_name_var = StringVar(value="NeuROK")
        self.time_source_var = StringVar(value="laptop")
        self.laptop_fps_var = StringVar(value="30")
        self.pull_max_files_var = StringVar(value="0")
        self.pull_concurrency_var = StringVar(value=str(DEFAULT_PULL_CONCURRENCY))
        self.capture_mode_var = StringVar(value="hd1080p30")
        self.tentacle_state_var = StringVar(value="Tentacle: idle")
        self.tentacle_timecode_var = StringVar(value="Director timecode: --:--:--:--")
        self.pull_status_var = StringVar(value="Pull queue: idle")
        self.upload_endpoint_var = StringVar(value="Upload endpoint: stopped")
        self.camera_params_var = StringVar(value="Camera params: no preset")
        self.preview_status_var = StringVar(value="Preview photos: idle")
        self.server_status_var = StringVar(value="Server: stopped")
        self.server_summary_var = StringVar(value="Stopped")
        self.connected_summary_var = StringVar(value="0 cameras")
        self.recording_summary_var = StringVar(value="0 recording")
        self.armed_summary_var = StringVar(value="0 armed")
        self.remote_director_summary_var = StringVar(value="None")
        self.remote_director_status_var = StringVar(value="Remote Director: none")
        self.remote_director_request_var = StringVar(value="No pending remote director request")
        self.selected_device_var = StringVar(value="No camera selected")
        self._upload_url_for_clients = ""
        self._latest_devices_by_id: dict[str, dict[str, Any]] = {}
        self._pending_remote_director_id = ""
        self._active_remote_director_id = ""
        self._last_experiment_key = initial_experiment_name
        self._is_syncing_experiment_take = False
        self.workspace: ttk.PanedWindow | None = None

        self._tentacle_anchor_monotonic: float | None = None
        self._tentacle_anchor_total_frames: int | None = None
        self._tentacle_anchor_fps: int | None = None

        self._build_ui()
        self.experiment_name_var.trace_add("write", self._on_experiment_name_changed)
        self.take_number_var.trace_add("write", self._on_take_number_changed)
        self._apply_time_source_settings()
        self._schedule_pump()
        self._schedule_status_refresh()
        self._schedule_tentacle_clock()
        self.root.after(100, self.start_server)

        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    def _build_ui(self) -> None:
        self._configure_styles()

        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)

        shell = ttk.Frame(self.root, padding=12, style="App.TFrame")
        shell.grid(row=0, column=0, sticky="nsew")
        shell.columnconfigure(0, weight=1)
        shell.rowconfigure(1, weight=1)

        self._build_header(shell).grid(row=0, column=0, sticky="ew")

        workspace = ttk.PanedWindow(shell, orient="horizontal")
        self.workspace = workspace
        workspace.grid(row=1, column=0, sticky="nsew", pady=(10, 10))
        workspace.add(self._build_devices_panel(workspace), weight=3)
        workspace.add(self._build_operations_panel(workspace), weight=2)
        self.root.after_idle(self._set_initial_workspace_layout)

        self._build_log_panel(shell).grid(row=2, column=0, sticky="ew")

    def _set_initial_workspace_layout(self, attempt: int = 0) -> None:
        workspace = self.workspace
        if workspace is None:
            return

        width = workspace.winfo_width()
        if width <= 1:
            if attempt < 10:
                self.root.after(50, lambda: self._set_initial_workspace_layout(attempt + 1))
            return

        right_width = min(max(520, int(width * 0.34)), max(360, width - 620))
        left_width = max(420, width - right_width)
        try:
            workspace.sashpos(0, left_width)
        except Exception:
            pass

    def _configure_styles(self) -> None:
        self.root.configure(bg="#f4f6f8")
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except Exception:
            pass

        style.configure("App.TFrame", background="#f4f6f8")
        style.configure("Panel.TFrame", background="#ffffff")
        style.configure("Panel.TLabelframe", background="#ffffff", bordercolor="#d8dde3", relief="solid")
        style.configure("Panel.TLabelframe.Label", background="#ffffff", foreground="#17202a", font=("TkDefaultFont", 12, "bold"))
        style.configure("Title.TLabel", background="#f4f6f8", foreground="#101820", font=("TkDefaultFont", 22, "bold"))
        style.configure("Subtitle.TLabel", background="#f4f6f8", foreground="#53616f")
        style.configure("PanelTitle.TLabel", background="#ffffff", foreground="#17202a", font=("TkDefaultFont", 13, "bold"))
        style.configure("Muted.TLabel", background="#ffffff", foreground="#667789")
        style.configure("StatusValue.TLabel", background="#ffffff", foreground="#101820", font=("TkDefaultFont", 14, "bold"))
        style.configure("StatusCaption.TLabel", background="#ffffff", foreground="#667789")
        style.configure("Primary.TButton", padding=(12, 8))
        style.configure("Danger.TButton", padding=(12, 8))
        style.configure("Treeview", rowheight=28, fieldbackground="#ffffff", background="#ffffff", foreground="#17202a")
        style.configure("Treeview.Heading", font=("TkDefaultFont", 11, "bold"))
        style.map("Treeview", background=[("selected", "#2458a6")], foreground=[("selected", "#ffffff")])

    def _build_header(self, parent: ttk.Frame) -> ttk.Frame:
        header = ttk.Frame(parent, style="App.TFrame")
        header.columnconfigure(1, weight=1)

        title_group = ttk.Frame(header, style="App.TFrame")
        title_group.grid(row=0, column=0, sticky="w")
        ttk.Label(title_group, text="SyncREC Director", style="Title.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Label(title_group,
                  text="Rig control for foregrounded iPhones",
                  style="Subtitle.TLabel").grid(row=1, column=0, sticky="w", pady=(2, 0))

        stats = ttk.Frame(header, style="App.TFrame")
        stats.grid(row=0, column=1, sticky="e")
        for index, (caption, variable) in enumerate((
            ("Server", self.server_summary_var),
            ("Cameras", self.connected_summary_var),
            ("Recording", self.recording_summary_var),
            ("Armed", self.armed_summary_var),
            ("Remote", self.remote_director_summary_var),
        )):
            self._build_stat_card(stats, caption, variable).grid(row=0, column=index, padx=(10 if index else 0, 0))

        return header

    def _build_stat_card(self, parent: ttk.Frame, caption: str, variable: StringVar) -> ttk.Frame:
        card = ttk.Frame(parent, padding=(14, 10), style="Panel.TFrame")
        card.configure(width=160, height=64)
        card.grid_propagate(False)
        ttk.Label(card, text=caption, style="StatusCaption.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Label(card, textvariable=variable, style="StatusValue.TLabel").grid(row=1, column=0, sticky="w", pady=(3, 0))
        return card

    def _build_devices_panel(self, parent: ttk.PanedWindow) -> ttk.Frame:
        panel = ttk.Frame(parent, padding=12, style="Panel.TFrame")
        panel.columnconfigure(0, weight=1)
        panel.rowconfigure(1, weight=1)

        toolbar = ttk.Frame(panel, style="Panel.TFrame")
        toolbar.grid(row=0, column=0, sticky="ew", pady=(0, 10))
        toolbar.columnconfigure(0, weight=1)
        ttk.Label(toolbar, text="Cameras", style="PanelTitle.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Button(toolbar, text="Ping All", command=self.ping_all).grid(row=0, column=1, padx=(8, 0))
        ttk.Button(toolbar, text="Refresh Status", command=self.get_status_all).grid(row=0, column=2, padx=(8, 0))

        table_frame = ttk.Frame(panel, style="Panel.TFrame")
        table_frame.grid(row=1, column=0, sticky="nsew")
        table_frame.columnconfigure(0, weight=1)
        table_frame.rowconfigure(0, weight=1)

        self.tree = ttk.Treeview(
            table_frame,
            columns=DEVICE_COLUMNS,
            displaycolumns=DEVICE_DISPLAY_COLUMNS,
            show="headings",
            height=18,
            selectmode="browse",
        )
        for col in DEVICE_COLUMNS:
            self.tree.heading(col, text=DEVICE_HEADINGS.get(col, col))
            self.tree.column(col, width=DEVICE_WIDTHS.get(col, 120), anchor="center", stretch=False)
        self.tree.column("name", anchor="w", stretch=True)
        self.tree.column("camera_params", anchor="w")
        self.tree.column("transfer", anchor="w")
        self.tree.column("preview", anchor="w")
        self.tree.column("pending", anchor="w")

        y_scroll = ttk.Scrollbar(table_frame, orient="vertical", command=self.tree.yview)
        x_scroll = ttk.Scrollbar(table_frame, orient="horizontal", command=self.tree.xview)
        self.tree.configure(yscrollcommand=y_scroll.set, xscrollcommand=x_scroll.set)
        self.tree.grid(row=0, column=0, sticky="nsew")
        y_scroll.grid(row=0, column=1, sticky="ns")
        x_scroll.grid(row=1, column=0, sticky="ew")

        self.tree.tag_configure("recording", background="#fff0f0", foreground="#8b1e1e")
        self.tree.tag_configure("armed", background="#f2f7ff", foreground="#164276")
        self.tree.tag_configure("stale", background="#f7f7f7", foreground="#6f7780")
        self.tree.tag_configure("pending", foreground="#725100")
        self.tree.bind("<<TreeviewSelect>>", self._on_tree_select)
        self.tree.bind("<Double-1>", lambda _event: self.open_selected_preview_image())

        details = ttk.LabelFrame(panel, text="Selected Camera", padding=10, style="Panel.TLabelframe")
        details.grid(row=2, column=0, sticky="ew", pady=(10, 0))
        details.columnconfigure(0, weight=1)
        ttk.Label(details, textvariable=self.selected_device_var, style="PanelTitle.TLabel").grid(row=0, column=0, sticky="w")
        self.selected_detail_box = Text(
            details,
            height=5,
            wrap="word",
            relief="flat",
            borderwidth=0,
            background="#ffffff",
            foreground="#344250",
            padx=0,
            pady=6,
        )
        self.selected_detail_box.grid(row=1, column=0, sticky="ew")
        self.selected_detail_box.insert(END, "Select a camera row to inspect connection, recording, transfer, and preview details.")
        self.selected_detail_box.configure(state="disabled")

        return panel

    def _build_operations_panel(self, parent: ttk.PanedWindow) -> ttk.Frame:
        panel = ttk.Frame(parent, padding=12, style="Panel.TFrame")
        panel.columnconfigure(0, weight=1)
        panel.rowconfigure(0, weight=1)

        notebook = ttk.Notebook(panel)
        notebook.grid(row=0, column=0, sticky="nsew")
        notebook.add(self._build_setup_tab(notebook), text="Setup")
        notebook.add(self._build_record_tab(notebook), text="Record")
        notebook.add(self._build_media_tab(notebook), text="Media")
        notebook.add(self._build_camera_tab(notebook), text="Camera")
        return panel

    def _build_setup_tab(self, notebook: ttk.Notebook) -> ttk.Frame:
        tab = ttk.Frame(notebook, style="Panel.TFrame")
        tab.columnconfigure(0, weight=1)
        tab.rowconfigure(0, weight=1)

        canvas = Canvas(tab, borderwidth=0, highlightthickness=0, background="#ffffff")
        scroll = ttk.Scrollbar(tab, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=scroll.set)
        canvas.grid(row=0, column=0, sticky="nsew")
        scroll.grid(row=0, column=1, sticky="ns")

        content = ttk.Frame(canvas, padding=12, style="Panel.TFrame")
        content.columnconfigure(0, weight=1)
        content_window = canvas.create_window((0, 0), window=content, anchor="nw")

        def _resize_content(_event: Any | None = None) -> None:
            canvas.configure(scrollregion=canvas.bbox("all"))

        def _resize_window(event: Any) -> None:
            canvas.itemconfigure(content_window, width=event.width)

        def _on_mousewheel(event: Any) -> str:
            if event.delta:
                direction = -1 if event.delta > 0 else 1
            else:
                direction = -1 if getattr(event, "num", 0) == 4 else 1
            canvas.yview_scroll(direction, "units")
            return "break"

        def _bind_mousewheel(_event: Any) -> None:
            canvas.bind_all("<MouseWheel>", _on_mousewheel)
            canvas.bind_all("<Button-4>", _on_mousewheel)
            canvas.bind_all("<Button-5>", _on_mousewheel)

        def _unbind_mousewheel(_event: Any) -> None:
            canvas.unbind_all("<MouseWheel>")
            canvas.unbind_all("<Button-4>")
            canvas.unbind_all("<Button-5>")

        content.bind("<Configure>", _resize_content)
        canvas.bind("<Configure>", _resize_window)
        canvas.bind("<Enter>", _bind_mousewheel)
        canvas.bind("<Leave>", _unbind_mousewheel)

        server = ttk.LabelFrame(content, text="Server", padding=10, style="Panel.TLabelframe")
        server.grid(row=0, column=0, sticky="ew")
        for col in range(4):
            server.columnconfigure(col, weight=1)

        self._labeled_entry(server, "Host", self.host_var, row=0, column=0, width=16)
        self._labeled_entry(server, "Port", self.port_var, row=0, column=1, width=8)
        self._labeled_entry(server, "Upload Host", self.upload_host_var, row=1, column=0, width=16)
        self._labeled_entry(server, "Upload Port", self.upload_port_var, row=1, column=1, width=8)
        ttk.Button(server, text="Start Server", command=self.start_server, style="Primary.TButton").grid(
            row=0, column=2, sticky="ew", padx=(12, 0), pady=(0, 8)
        )
        ttk.Button(server, text="Stop Server", command=self.stop_server).grid(
            row=0, column=3, sticky="ew", padx=(8, 0), pady=(0, 8)
        )
        self.status_label = ttk.Label(server, textvariable=self.server_status_var, style="Muted.TLabel")
        self.status_label.grid(row=2, column=0, columnspan=4, sticky="w", pady=(8, 0))

        timecode = ttk.LabelFrame(content, text="Timecode", padding=10, style="Panel.TLabelframe")
        timecode.grid(row=1, column=0, sticky="ew", pady=(12, 0))
        for col in range(3):
            timecode.columnconfigure(col, weight=1)

        source_menu = self._labeled_combo(
            timecode,
            "Source",
            self.time_source_var,
            row=0,
            column=0,
            width=12,
            values=("tentacle", "laptop"),
        )
        source_menu.bind("<<ComboboxSelected>>", self._on_time_source_changed)
        fps_menu = self._labeled_combo(
            timecode,
            "Laptop FPS",
            self.laptop_fps_var,
            row=0,
            column=1,
            width=8,
            values=("30", "60"),
        )
        fps_menu.bind("<<ComboboxSelected>>", self._on_time_source_changed)
        self._labeled_entry(timecode, "Tentacle Name", self.tentacle_name_var, row=0, column=2, width=14)

        ttk.Button(timecode, text="Connect TC", command=self.start_tentacle).grid(
            row=1, column=0, sticky="ew", pady=(10, 0), padx=(0, 6)
        )
        ttk.Button(timecode, text="Stop TC", command=self.stop_tentacle).grid(
            row=1, column=1, sticky="ew", pady=(10, 0), padx=(6, 6)
        )
        self.tentacle_status_label = ttk.Label(timecode, textvariable=self.tentacle_state_var, style="Muted.TLabel")
        self.tentacle_status_label.grid(row=2, column=0, columnspan=3, sticky="w", pady=(12, 2))
        self.tentacle_timecode_label = ttk.Label(timecode, textvariable=self.tentacle_timecode_var, style="StatusValue.TLabel")
        self.tentacle_timecode_label.grid(row=3, column=0, columnspan=3, sticky="w")

        status = ttk.LabelFrame(content, text="Director Status", padding=10, style="Panel.TLabelframe")
        status.grid(row=2, column=0, sticky="ew", pady=(12, 0))
        status.columnconfigure(0, weight=1)
        self.upload_endpoint_label = ttk.Label(status, textvariable=self.upload_endpoint_var, style="Muted.TLabel", wraplength=380)
        self.upload_endpoint_label.grid(row=0, column=0, sticky="w")
        self.pull_status_label = ttk.Label(status, textvariable=self.pull_status_var, style="Muted.TLabel", wraplength=380)
        self.pull_status_label.grid(row=1, column=0, sticky="w", pady=(6, 0))

        remote = ttk.LabelFrame(content, text="Remote Director", padding=10, style="Panel.TLabelframe")
        remote.grid(row=3, column=0, sticky="ew", pady=(12, 0))
        remote.columnconfigure(0, weight=1)
        remote.columnconfigure(1, weight=1)
        self.remote_director_status_label = ttk.Label(
            remote,
            textvariable=self.remote_director_status_var,
            style="Muted.TLabel",
            wraplength=380,
        )
        self.remote_director_status_label.grid(row=0, column=0, columnspan=2, sticky="w")
        self.remote_director_request_label = ttk.Label(
            remote,
            textvariable=self.remote_director_request_var,
            style="Muted.TLabel",
            wraplength=380,
        )
        self.remote_director_request_label.grid(row=1, column=0, columnspan=2, sticky="w", pady=(6, 0))
        ttk.Button(remote, text="Approve Request", command=self.approve_remote_director).grid(
            row=2, column=0, sticky="ew", pady=(10, 0), padx=(0, 6)
        )
        ttk.Button(remote, text="Deny Request", command=self.deny_remote_director).grid(
            row=2, column=1, sticky="ew", pady=(10, 0), padx=(6, 0)
        )
        ttk.Button(remote, text="Release Active Remote Director", command=self.release_remote_director).grid(
            row=3, column=0, columnspan=2, sticky="ew", pady=(10, 0)
        )

        return tab

    def _build_record_tab(self, notebook: ttk.Notebook) -> ttk.Frame:
        tab = ttk.Frame(notebook, padding=12, style="Panel.TFrame")
        tab.columnconfigure(0, weight=1)

        timing = ttk.LabelFrame(tab, text="Scheduled Recording", padding=10, style="Panel.TLabelframe")
        timing.grid(row=0, column=0, sticky="ew")
        for col in range(2):
            timing.columnconfigure(col, weight=1)
        self._labeled_entry(timing, "Experiment", self.experiment_name_var, row=0, column=0, width=18)
        self._labeled_entry(timing, "Take", self.take_number_var, row=0, column=1, width=8)
        self._labeled_entry(timing, "Start Delay (s)", self.start_delay_var, row=1, column=0, width=8)
        self._labeled_entry(timing, "Stop Delay (s)", self.stop_delay_var, row=1, column=1, width=8)
        ttk.Button(timing, text="Prepare + Commit Start", command=self.start_all, style="Primary.TButton").grid(
            row=2, column=0, sticky="ew", pady=(10, 0), padx=(0, 6)
        )
        ttk.Button(timing, text="Prepare Stop", command=self.stop_all).grid(
            row=2, column=1, sticky="ew", pady=(10, 0), padx=(6, 0)
        )

        global_actions = ttk.LabelFrame(tab, text="All Cameras", padding=10, style="Panel.TLabelframe")
        global_actions.grid(row=1, column=0, sticky="ew", pady=(12, 0))
        self._button_grid(
            global_actions,
            (
                ("Arm Idle All", self.arm_all),
                ("Prepare Rec All", self.prepare_recording_all),
                ("Start Rec All", self.start_recording_all),
                ("Stop Rec All", self.stop_recording_all),
            ),
        )

        selected_actions = ttk.LabelFrame(tab, text="Selected Camera", padding=10, style="Panel.TLabelframe")
        selected_actions.grid(row=2, column=0, sticky="ew", pady=(12, 0))
        self._button_grid(
            selected_actions,
            (
                ("Arm Idle Selected", self.arm_selected),
                ("Prepare Selected", self.prepare_recording_selected),
                ("Start Selected", self.start_recording_selected),
                ("Stop Selected", self.stop_recording_selected),
            ),
        )
        return tab

    def _build_media_tab(self, notebook: ttk.Notebook) -> ttk.Frame:
        tab = ttk.Frame(notebook, padding=12, style="Panel.TFrame")
        tab.columnconfigure(0, weight=1)

        transfer = ttk.LabelFrame(tab, text="Video Transfer", padding=10, style="Panel.TLabelframe")
        transfer.grid(row=0, column=0, sticky="ew")
        transfer.columnconfigure(0, weight=1)
        transfer.columnconfigure(1, weight=1)
        self._labeled_entry(transfer, "Pull Max Files (0 = all)", self.pull_max_files_var, row=0, column=0, width=10)
        self._labeled_entry(transfer, "Pull Concurrency", self.pull_concurrency_var, row=0, column=1, width=10)
        ttk.Button(transfer, text="Pull Videos All", command=self.pull_all_devices, style="Primary.TButton").grid(
            row=1, column=0, sticky="ew", pady=(10, 0), padx=(0, 6)
        )
        ttk.Button(transfer, text="Delete Uploaded All", command=self.delete_uploaded_videos_all).grid(
            row=1, column=1, sticky="ew", pady=(10, 0), padx=(6, 0)
        )
        ttk.Button(transfer, text="Pull Videos Selected", command=self.pull_selected_device, style="Primary.TButton").grid(
            row=2, column=0, sticky="ew", pady=(10, 0), padx=(0, 6)
        )
        ttk.Button(transfer, text="Delete Uploaded Selected", command=self.delete_uploaded_videos_selected).grid(
            row=2, column=1, sticky="ew", pady=(10, 0), padx=(6, 0)
        )
        ttk.Button(transfer, text="Force Delete Selected", command=self.force_delete_videos_selected, style="Danger.TButton").grid(
            row=3, column=0, columnspan=2, sticky="ew", pady=(10, 0)
        )

        preview = ttk.LabelFrame(tab, text="Preview Photos", padding=10, style="Panel.TLabelframe")
        preview.grid(row=1, column=0, sticky="ew", pady=(12, 0))
        preview.columnconfigure(0, weight=1)
        preview.columnconfigure(1, weight=1)
        ttk.Button(preview, text="Preview Selected", command=self.preview_photo_selected).grid(
            row=0, column=0, sticky="ew", padx=(0, 6)
        )
        ttk.Button(preview, text="Open Selected Image", command=self.open_selected_preview_image).grid(
            row=0, column=1, sticky="ew", padx=(6, 0)
        )
        ttk.Button(preview, text="Preview All", command=self.preview_photos_all).grid(
            row=1, column=0, sticky="ew", pady=(10, 0), padx=(0, 6)
        )
        ttk.Button(preview, text="Open Grid-view Image", command=self.open_preview_grid_image).grid(
            row=1, column=1, sticky="ew", pady=(10, 0), padx=(6, 0)
        )
        ttk.Button(preview, text="Open Preview Folder", command=self.open_preview_folder).grid(
            row=2, column=0, columnspan=2, sticky="ew", pady=(10, 0)
        )
        self.preview_status_label = ttk.Label(preview, textvariable=self.preview_status_var, style="Muted.TLabel", wraplength=380)
        self.preview_status_label.grid(row=3, column=0, columnspan=2, sticky="w", pady=(12, 0))
        return tab

    def _build_camera_tab(self, notebook: ttk.Notebook) -> ttk.Frame:
        tab = ttk.Frame(notebook, padding=12, style="Panel.TFrame")
        tab.columnconfigure(0, weight=1)

        params = ttk.LabelFrame(tab, text="Camera Parameters", padding=10, style="Panel.TLabelframe")
        params.grid(row=0, column=0, sticky="ew")
        params.columnconfigure(0, weight=1)
        params.columnconfigure(1, weight=1)
        ttk.Button(params, text="Copy Params Selected", command=self.copy_camera_params_selected).grid(
            row=0, column=0, sticky="ew", padx=(0, 6)
        )
        ttk.Button(params, text="Dry Run Sync", command=self.dry_run_sync_camera_params).grid(
            row=0, column=1, sticky="ew", padx=(6, 0)
        )
        ttk.Button(params, text="Sync Params All", command=self.sync_camera_params_all).grid(
            row=1, column=0, columnspan=2, sticky="ew", pady=(10, 0)
        )
        ttk.Button(params, text="Lock Focus", command=self.lock_focus_selected).grid(
            row=2, column=0, sticky="ew", pady=(10, 0), padx=(0, 6)
        )
        ttk.Button(params, text="Unlock Focus", command=self.enable_auto_focus_selected).grid(
            row=2, column=1, sticky="ew", pady=(10, 0), padx=(6, 0)
        )
        ttk.Button(params, text="Lock Camera Params", command=self.lock_camera_param_locks_selected).grid(
            row=3, column=0, sticky="ew", pady=(10, 0), padx=(0, 6)
        )
        ttk.Button(params, text="Unlock Camera Params", command=self.unlock_camera_param_locks_selected).grid(
            row=3, column=1, sticky="ew", pady=(10, 0), padx=(6, 0)
        )
        self.camera_params_label = ttk.Label(params, textvariable=self.camera_params_var, style="Muted.TLabel", wraplength=380)
        self.camera_params_label.grid(row=4, column=0, columnspan=2, sticky="w", pady=(12, 0))

        mode = ttk.LabelFrame(tab, text="Capture Mode", padding=10, style="Panel.TLabelframe")
        mode.grid(row=1, column=0, sticky="ew", pady=(12, 0))
        mode.columnconfigure(0, weight=1)
        mode_menu = ttk.Combobox(mode,
                                 textvariable=self.capture_mode_var,
                                 width=14,
                                 values=CAPTURE_MODES,
                                 state="readonly")
        mode_menu.grid(row=0, column=0, sticky="ew")
        ttk.Button(mode, text="Set Mode Selected", command=self.set_capture_mode_selected).grid(
            row=1, column=0, sticky="ew", pady=(10, 0)
        )
        ttk.Button(mode, text="Set Mode All", command=self.set_capture_mode_all).grid(
            row=2, column=0, sticky="ew", pady=(10, 0)
        )
        return tab

    def _build_log_panel(self, parent: ttk.Frame) -> ttk.Frame:
        panel = ttk.LabelFrame(parent, text="Event Log", padding=10, style="Panel.TLabelframe")
        panel.columnconfigure(0, weight=1)

        toolbar = ttk.Frame(panel, style="Panel.TFrame")
        toolbar.grid(row=0, column=0, columnspan=2, sticky="ew", pady=(0, 8))
        toolbar.columnconfigure(0, weight=1)
        ttk.Label(toolbar, text="Server, upload, command, and timecode events", style="Muted.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Button(toolbar, text="Clear", command=self.clear_log).grid(row=0, column=1, sticky="e")

        self.log_box = Text(
            panel,
            height=8,
            wrap="word",
            relief="flat",
            borderwidth=1,
            background="#101820",
            foreground="#e8edf2",
            insertbackground="#e8edf2",
            padx=10,
            pady=8,
        )
        log_scroll = ttk.Scrollbar(panel, command=self.log_box.yview)
        self.log_box.configure(yscrollcommand=log_scroll.set, state="disabled")
        self.log_box.grid(row=1, column=0, sticky="ew")
        log_scroll.grid(row=1, column=1, sticky="ns")
        return panel

    def _labeled_entry(self,
                       parent: ttk.Frame,
                       label: str,
                       variable: StringVar,
                       row: int,
                       column: int,
                       width: int) -> ttk.Entry:
        group = ttk.Frame(parent, style="Panel.TFrame")
        group.grid(row=row, column=column, sticky="ew", padx=(0, 8), pady=(0, 8))
        group.columnconfigure(0, weight=1)
        ttk.Label(group, text=label, style="StatusCaption.TLabel").grid(row=0, column=0, sticky="w")
        entry = ttk.Entry(group, textvariable=variable, width=width)
        entry.grid(row=1, column=0, sticky="ew", pady=(3, 0))
        return entry

    def _labeled_combo(self,
                       parent: ttk.Frame,
                       label: str,
                       variable: StringVar,
                       row: int,
                       column: int,
                       width: int,
                       values: tuple[str, ...]) -> ttk.Combobox:
        group = ttk.Frame(parent, style="Panel.TFrame")
        group.grid(row=row, column=column, sticky="ew", padx=(0, 8), pady=(0, 8))
        group.columnconfigure(0, weight=1)
        ttk.Label(group, text=label, style="StatusCaption.TLabel").grid(row=0, column=0, sticky="w")
        combo = ttk.Combobox(group, textvariable=variable, width=width, values=values, state="readonly")
        combo.grid(row=1, column=0, sticky="ew", pady=(3, 0))
        return combo

    def _button_grid(self,
                     parent: ttk.Frame,
                     buttons: tuple[tuple[str, Any], ...],
                     columns: int = 2) -> None:
        for col in range(columns):
            parent.columnconfigure(col, weight=1)
        for index, (label, command) in enumerate(buttons):
            row = index // columns
            col = index % columns
            padx = (0, 6) if col == 0 and columns > 1 else (6, 0) if columns > 1 else (0, 0)
            ttk.Button(parent, text=label, command=command).grid(
                row=row,
                column=col,
                sticky="ew",
                padx=padx,
                pady=(0 if row == 0 else 10, 0),
            )

    def _schedule_pump(self) -> None:
        had_more = self._pump_events()
        self.root.after(10 if had_more else 100, self._schedule_pump)

    def _pump_events(self) -> bool:
        max_events = 40
        processed = 0
        latest_devices: list[dict[str, Any]] | None = None
        latest_tentacle_packet: dict[str, Any] | None = None
        log_lines: list[str] = []

        while processed < max_events:
            try:
                etype, payload = self.event_queue.get_nowait()
            except queue.Empty:
                break
            processed += 1

            if etype == "log":
                log_lines.append(str(payload))
            elif etype == "server_started":
                self.server_status_var.set(f"Server: running on ws://{payload['host']}:{payload['port']}")
                self.server_summary_var.set("Running")
            elif etype == "server_stopped":
                self.server_status_var.set("Server: stopped")
                self.server_summary_var.set("Stopped")
            elif etype == "devices_updated":
                latest_devices = payload
            elif etype == "remote_director_updated":
                if isinstance(payload, dict):
                    self._refresh_remote_director_status(payload)
            elif etype == "remote_director_control":
                if isinstance(payload, dict):
                    self._handle_remote_director_control(payload)
            elif etype == "preview_upload_received":
                if isinstance(payload, dict):
                    self.server.handle_preview_upload_received(payload)
            elif etype == "camera_params_status":
                self.camera_params_var.set(str(payload))
            elif etype == "tentacle_state":
                if self._time_source_is_laptop():
                    continue
                state = str(payload.get("state", "unknown")) if isinstance(payload, dict) else "unknown"
                self.tentacle_state_var.set(f"Tentacle: {state}")
                if not state.lower().startswith("connected"):
                    self.server.clear_timecode_anchor()
            elif etype == "tentacle_timecode":
                if self._time_source_is_laptop():
                    continue
                if isinstance(payload, dict):
                    latest_tentacle_packet = payload

        if log_lines:
            self._append_log_lines(log_lines)
        if latest_devices is not None:
            self._refresh_tree(latest_devices)
        if latest_tentacle_packet is not None:
            self._set_tentacle_anchor_from_packet(latest_tentacle_packet)
            self.server.update_timecode_anchor(latest_tentacle_packet)

        return not self.event_queue.empty()

    def _schedule_status_refresh(self) -> None:
        devices = self.server.snapshot_devices()
        self._refresh_tree(devices)
        self._refresh_remote_director_status(self.server.remote_director_status())
        self.server.publish_remote_director_state(self._remote_director_state_payload(devices))
        pull = self.server.pull_status()
        active_device_ids = pull.get("active_device_ids") or []
        active_count = int(pull.get("active_count") or 0)
        concurrency_limit = int(pull.get("concurrency_limit") or 1)
        queued = pull.get("queued_count", 0)

        if active_count:
            active_text = ", ".join(str(device_id) for device_id in active_device_ids[:3])
            if active_count > 3:
                active_text = f"{active_text}, +{active_count - 3} more"
            self.pull_status_var.set(
                f"Pull queue: active={active_count}/{concurrency_limit} [{active_text}] queued={queued}"
            )
        elif queued:
            self.pull_status_var.set(f"Pull queue: queued={queued}, waiting for an upload slot")
        else:
            self.pull_status_var.set(f"Pull queue: idle (concurrency={concurrency_limit})")

        self.root.after(1000, self._schedule_status_refresh)

    def _schedule_tentacle_clock(self) -> None:
        self._tick_tentacle_clock()
        self.root.after(200, self._schedule_tentacle_clock)

    def _set_tentacle_anchor_from_packet(self, packet: dict[str, Any]) -> None:
        fps = packet.get("fps")
        hours = packet.get("hours")
        minutes = packet.get("minutes")
        seconds = packet.get("seconds")
        frames = packet.get("frames")
        if not all(isinstance(v, int) for v in (fps, hours, minutes, seconds, frames)):
            tc = str(packet.get("timecode") or "")
            self.tentacle_timecode_var.set(f"Director timecode: {timecode_text(tc, None)}")
            return
        if fps <= 0:
            return

        total_frames = ((((hours * 60) + minutes) * 60) + seconds) * fps + frames
        self._tentacle_anchor_monotonic = time.monotonic()
        self._tentacle_anchor_total_frames = total_frames
        self._tentacle_anchor_fps = fps
        self._tick_tentacle_clock()

    def _tick_tentacle_clock(self) -> None:
        if self._time_source_is_laptop():
            fps = self._resolved_laptop_fps()
            now = time.time()
            total_frames = int((now % (24 * 60 * 60)) * fps)
            tc = timecode_from_total_frames(total_frames, fps)
            self.tentacle_timecode_var.set(f"Director timecode: {tc} @ {fps} fps")
            return

        if (
            self._tentacle_anchor_monotonic is None
            or self._tentacle_anchor_total_frames is None
            or self._tentacle_anchor_fps is None
            or self._tentacle_anchor_fps <= 0
        ):
            return

        fps = self._tentacle_anchor_fps
        elapsed = max(0.0, time.monotonic() - self._tentacle_anchor_monotonic)
        advanced_frames = int(elapsed * fps)
        total_frames = self._tentacle_anchor_total_frames + advanced_frames
        tc = timecode_from_total_frames(total_frames, fps)
        self.tentacle_timecode_var.set(f"Director timecode: {tc} @ {fps} fps")

    def _refresh_tree(self, devices: list[dict[str, Any]]) -> None:
        selected_device_id = ""
        selected_items = self.tree.selection()
        if selected_items:
            selected_device_id = str(selected_items[0])

        self._latest_devices_by_id = {
            str(d.get("device_id") or ""): d
            for d in devices
            if d.get("device_id")
        }
        self._update_device_summary(devices)

        existing_row_ids = set(self.tree.get_children())
        updated_row_ids: set[str] = set()
        now = time.time()
        for d in devices:
            device_id = str(d.get("device_id") or "")
            if not device_id:
                continue
            updated_row_ids.add(device_id)
            pending_acks = d.get("pending_acks") or {}
            pending = ", ".join(pending_acks.values()) if pending_acks else ""
            battery_value = d.get("battery")
            storage_value = d.get("storage_gb")
            battery = f"{battery_value * 100:.0f}%" if isinstance(battery_value, (int, float)) else "-"
            storage = f"{storage_value:.1f} GB" if isinstance(storage_value, (int, float)) else "-"
            local_videos = d.get("local_video_count")
            uploaded_videos = d.get("uploaded_video_count")
            pending_upload_videos = d.get("pending_upload_video_count")
            if isinstance(local_videos, int):
                if isinstance(uploaded_videos, int) and isinstance(pending_upload_videos, int):
                    videos = f"{local_videos} ({uploaded_videos} up/{pending_upload_videos} pending)"
                else:
                    videos = str(local_videos)
            else:
                videos = "-"
            capture_mode = str(d.get("capture_mode") or "")
            actual_width = d.get("actual_video_width")
            actual_height = d.get("actual_video_height")
            actual_fps = d.get("actual_video_fps")
            if isinstance(actual_width, int) and isinstance(actual_height, int) and isinstance(actual_fps, (int, float)):
                actual_video = f"{actual_width}x{actual_height} {actual_fps:.0f}fps"
            else:
                actual_video = ""
            age = max(0.0, now - float(d["last_seen_unix"]))
            last_seen = f"{age:.1f}s"
            transfer_state = str(d.get("transfer_state") or "")
            transfer_detail = str(d.get("transfer_detail") or "")
            transfer = transfer_state
            if transfer_detail:
                transfer = f"{transfer_state} ({transfer_detail})" if transfer_state else transfer_detail
            camera_params = str(d.get("camera_params_status") or "")
            camera_params_summary = str(d.get("camera_params_summary") or "")
            if camera_params_summary:
                camera_params = f"{camera_params}: {camera_params_summary}" if camera_params else camera_params_summary
            preview_state = str(d.get("preview_state") or "")
            preview_detail = str(d.get("preview_detail") or "")
            preview = preview_state
            if preview_detail:
                preview = f"{preview_state} ({preview_detail})" if preview_state else preview_detail
            preview_path = str(d.get("preview_image_path") or "")
            tags: list[str] = []
            if d.get("recording"):
                tags.append("recording")
            elif d.get("armed"):
                tags.append("armed")
            if age > 15.0:
                tags.append("stale")
            if pending:
                tags.append("pending")

            values = (
                d["name"],
                d["device_id"],
                d["endpoint"],
                d.get("app_display_version") or d.get("app_version") or "",
                yes_no(d["armed"]),
                yes_no(d["recording"]),
                battery,
                storage,
                videos,
                capture_mode,
                actual_video,
                d["tentacle_state"],
                timecode_text(d["timecode"], d["fps"]),
                str(d.get("rig_state") or ""),
                camera_params,
                transfer,
                preview,
                preview_path,
                last_seen,
                pending,
            )
            if device_id in existing_row_ids:
                self.tree.item(device_id, tags=tuple(tags), values=values)
            else:
                self.tree.insert("", END, iid=device_id, tags=tuple(tags), values=values)

        for stale_row_id in existing_row_ids - updated_row_ids:
            self.tree.delete(stale_row_id)

        if selected_device_id and selected_device_id in updated_row_ids:
            self.tree.selection_set(selected_device_id)
            self.tree.focus(selected_device_id)
        self._update_selected_device_detail()

    def _append_log(self, line: str) -> None:
        self._append_log_lines([line])

    def _append_log_lines(self, lines: list[str]) -> None:
        if not lines:
            return
        self.log_box.configure(state="normal")
        self.log_box.insert(END, "\n".join(lines) + "\n")
        self.log_box.see(END)
        self.log_box.configure(state="disabled")

    def clear_log(self) -> None:
        self.log_box.configure(state="normal")
        self.log_box.delete("1.0", END)
        self.log_box.configure(state="disabled")

    def _update_device_summary(self, devices: list[dict[str, Any]]) -> None:
        connected = len(devices)
        recording = sum(1 for d in devices if bool(d.get("recording")))
        armed = sum(1 for d in devices if bool(d.get("armed")))
        self.connected_summary_var.set(f"{connected} camera{'s' if connected != 1 else ''}")
        self.recording_summary_var.set(f"{recording} recording")
        self.armed_summary_var.set(f"{armed} armed")

    def _refresh_remote_director_status(self, snapshot: dict[str, Any]) -> None:
        active = snapshot.get("active") if isinstance(snapshot.get("active"), dict) else None
        pending = snapshot.get("pending") if isinstance(snapshot.get("pending"), list) else []
        pending_items = [item for item in pending if isinstance(item, dict)]

        self._active_remote_director_id = str(active.get("device_id") or "") if active else ""
        self._pending_remote_director_id = str(pending_items[0].get("device_id") or "") if pending_items else ""

        if active:
            name = str(active.get("name") or active.get("device_id") or "Remote director")
            endpoint = str(active.get("endpoint") or "-")
            if active.get("connected") is False:
                self.remote_director_summary_var.set("Disconnected")
                self.remote_director_status_var.set(
                    f"Remote Director: disconnected - {name}; will auto-approve on reconnect"
                )
            else:
                self.remote_director_summary_var.set("Active")
                self.remote_director_status_var.set(f"Remote Director: active - {name} ({endpoint})")
        else:
            self.remote_director_status_var.set("Remote Director: none active")
            if pending_items:
                self.remote_director_summary_var.set("Pending")
            else:
                self.remote_director_summary_var.set("None")

        if pending_items:
            first = pending_items[0]
            name = str(first.get("name") or first.get("device_id") or "Remote director")
            state = str(first.get("state") or "pending")
            detail = str(first.get("detail") or "")
            suffix = f"; +{len(pending_items) - 1} more" if len(pending_items) > 1 else ""
            detail_text = f" - {detail}" if detail else ""
            self.remote_director_request_var.set(f"Request: {name} ({state}){detail_text}{suffix}")
        else:
            self.remote_director_request_var.set("No pending remote director request")

    def _remote_director_state_payload(self, devices: list[dict[str, Any]]) -> dict[str, Any]:
        recording = sum(1 for d in devices if bool(d.get("recording")))
        armed = sum(1 for d in devices if bool(d.get("armed")))
        return {
            "experiment_name": self._current_experiment_name(),
            "take_number": self._current_take_number(),
            "start_delay": parse_delay(self.start_delay_var.get(), fallback=2.0),
            "stop_delay": parse_delay(self.stop_delay_var.get(), fallback=2.0),
            "connected_cameras": len(devices),
            "recording_cameras": recording,
            "armed_cameras": armed,
            "director_timecode": self.tentacle_timecode_var.get(),
        }

    def _reply_remote_director_control(self,
                                       request: dict[str, Any],
                                       ok: bool,
                                       detail: str,
                                       payload: dict[str, Any] | None = None) -> None:
        device_id = str(request.get("device_id") or "")
        request_id = str(request.get("request_id") or "")
        if not device_id or not request_id:
            return
        state = self._remote_director_state_payload(self.server.snapshot_devices())
        if payload:
            state.update(payload)
        self.server.send_remote_director_result(device_id=device_id,
                                                request_id=request_id,
                                                ok=ok,
                                                detail=detail,
                                                payload=state)
        self.server.publish_remote_director_state(state)

    def _handle_remote_director_control(self, request: dict[str, Any]) -> None:
        action = str(request.get("action") or "")
        payload = request.get("payload") if isinstance(request.get("payload"), dict) else {}

        try:
            if action == "set_experiment_name":
                experiment_name = str(payload.get("experiment_name") or "").strip()
                if not experiment_name:
                    self._reply_remote_director_control(request, False, "Experiment name is required.")
                    return
                self.experiment_name_var.set(experiment_name)
                self._reply_remote_director_control(request, True, f"Experiment set to {self._current_experiment_name()}.")
            elif action == "prepare_commit_start":
                experiment_name = str(payload.get("experiment_name") or "").strip()
                if experiment_name:
                    self.experiment_name_var.set(experiment_name)
                self.start_all()
                self._reply_remote_director_control(request, True, "Prepare + Commit Start sent.")
            elif action == "prepare_stop":
                self.stop_all()
                self._reply_remote_director_control(request, True, "Prepare Stop sent.")
            elif action == "arm_idle_all":
                self.arm_all()
                self._reply_remote_director_control(request, True, "Arm Idle All sent.")
            elif action == "get_state":
                self._reply_remote_director_control(request, True, "State refreshed.")
            else:
                self._reply_remote_director_control(request, False, f"Unknown remote director action: {action}")
        except Exception as exc:
            self._reply_remote_director_control(request, False, f"Remote director action failed: {exc}")

    def _on_tree_select(self, _event: Any | None = None) -> None:
        self._update_selected_device_detail()

    def _update_selected_device_detail(self) -> None:
        device_id = self._selected_device_id()
        device = self._latest_devices_by_id.get(device_id)
        if not device:
            self.selected_device_var.set("No camera selected")
            self._set_selected_detail_text(
                "Select a camera row to inspect connection, recording, transfer, and preview details."
            )
            return

        name = str(device.get("name") or "Unnamed camera")
        self.selected_device_var.set(f"{name}  |  {device_id}")
        battery = self._format_percent(device.get("battery"))
        storage = self._format_gb(device.get("storage_gb"))
        local = self._format_int(device.get("local_video_count"))
        uploaded = self._format_int(device.get("uploaded_video_count"))
        pending_upload = self._format_int(device.get("pending_upload_video_count"))
        actual_video = self._format_actual_video(device)
        camera_params = str(device.get("camera_params_status") or "")
        camera_params_summary = str(device.get("camera_params_summary") or "")
        if camera_params_summary:
            camera_params = f"{camera_params}: {camera_params_summary}" if camera_params else camera_params_summary

        lines = [
            f"Endpoint: {device.get('endpoint') or '-'}    App: {device.get('app_display_version') or device.get('app_version') or '-'}",
            (
                f"State: recording={yes_no(bool(device.get('recording')))}  "
                f"armed={yes_no(bool(device.get('armed')))}  "
                f"rig={device.get('rig_state') or '-'}  "
                f"last seen={self._format_last_seen(device)}"
            ),
            f"Media: battery={battery}  free={storage}  videos={local} ({uploaded} uploaded/{pending_upload} pending)",
            (
                f"Capture: requested={device.get('capture_mode') or '-'}  "
                f"actual={actual_video or '-'}  "
                f"timecode={timecode_text(str(device.get('timecode') or ''), device.get('fps')) or '-'}"
            ),
            (
                f"Transfer: {self._format_status_pair(device.get('transfer_state'), device.get('transfer_detail'))}    "
                f"Preview: {self._format_status_pair(device.get('preview_state'), device.get('preview_detail'))}"
            ),
            f"Camera params: {camera_params or '-'}",
        ]
        preview_path = str(device.get("preview_image_path") or "")
        if preview_path:
            lines.append(f"Preview image: {preview_path}")
        pending_acks = device.get("pending_acks") or {}
        if pending_acks:
            lines.append("Pending commands: " + ", ".join(str(value) for value in pending_acks.values()))
        self._set_selected_detail_text("\n".join(lines))

    def _set_selected_detail_text(self, text: str) -> None:
        self.selected_detail_box.configure(state="normal")
        self.selected_detail_box.delete("1.0", END)
        self.selected_detail_box.insert(END, text)
        self.selected_detail_box.configure(state="disabled")

    def _format_actual_video(self, device: dict[str, Any]) -> str:
        actual_width = device.get("actual_video_width")
        actual_height = device.get("actual_video_height")
        actual_fps = device.get("actual_video_fps")
        if isinstance(actual_width, int) and isinstance(actual_height, int) and isinstance(actual_fps, (int, float)):
            return f"{actual_width}x{actual_height} {actual_fps:.0f}fps"
        actual_mode = str(device.get("actual_capture_mode") or "")
        return actual_mode

    def _format_last_seen(self, device: dict[str, Any]) -> str:
        try:
            age = max(0.0, time.time() - float(device.get("last_seen_unix") or 0.0))
        except Exception:
            return "-"
        return f"{age:.1f}s"

    def _format_percent(self, value: Any) -> str:
        return f"{value * 100:.0f}%" if isinstance(value, (int, float)) else "-"

    def _format_gb(self, value: Any) -> str:
        return f"{value:.1f} GB" if isinstance(value, (int, float)) else "-"

    def _format_int(self, value: Any) -> str:
        return str(value) if isinstance(value, int) else "-"

    def _format_status_pair(self, state: Any, detail: Any) -> str:
        state_text = str(state or "")
        detail_text = str(detail or "")
        if state_text and detail_text:
            return f"{state_text} ({detail_text})"
        return state_text or detail_text or "-"

    def _time_source_is_laptop(self) -> bool:
        return self.time_source_var.get().strip().lower() == "laptop"

    def _resolved_laptop_fps(self) -> int:
        try:
            fps = int(self.laptop_fps_var.get().strip())
        except ValueError:
            fps = 30
        fps = 60 if fps == 60 else 30
        if self.laptop_fps_var.get() != str(fps):
            self.laptop_fps_var.set(str(fps))
        return fps

    def _apply_time_source_settings(self) -> None:
        source = "laptop" if self._time_source_is_laptop() else "tentacle"
        fps = self._resolved_laptop_fps()
        self.server.configure_time_source(source=source, fps=fps)

        if source == "laptop":
            self.tentacle_reader.stop()
            self.server.clear_timecode_anchor()
            self._tentacle_anchor_monotonic = None
            self._tentacle_anchor_total_frames = None
            self._tentacle_anchor_fps = None
            self.tentacle_state_var.set("Tentacle: bypassed (laptop clock)")
        else:
            self.tentacle_state_var.set("Tentacle: idle")
            self.tentacle_timecode_var.set("Director timecode: --:--:--:--")

    def _on_time_source_changed(self, _event: Any | None = None) -> None:
        self._apply_time_source_settings()

    def _load_take_numbers(self) -> dict[str, int]:
        try:
            with TAKE_NUMBERS_STATE_PATH.open("r", encoding="utf-8") as state_file:
                state = json.load(state_file)
        except FileNotFoundError:
            return {"experiment": 1}
        except Exception:
            return {"experiment": 1}

        raw_take_numbers = state.get("take_numbers_by_experiment") if isinstance(state, dict) else None
        if not isinstance(raw_take_numbers, dict):
            return {"experiment": 1}

        take_numbers: dict[str, int] = {}
        for raw_name, raw_take in raw_take_numbers.items():
            experiment_name = self._safe_recording_component(str(raw_name), fallback="experiment")
            try:
                take_number = int(raw_take)
            except Exception:
                continue
            take_numbers[experiment_name] = max(1, take_number)

        if "experiment" not in take_numbers:
            take_numbers["experiment"] = 1
        return take_numbers

    def _load_last_experiment_name(self) -> str:
        try:
            with TAKE_NUMBERS_STATE_PATH.open("r", encoding="utf-8") as state_file:
                state = json.load(state_file)
        except FileNotFoundError:
            return "experiment"
        except Exception:
            return "experiment"

        raw_name = state.get("last_experiment_name") if isinstance(state, dict) else None
        return self._safe_recording_component(str(raw_name or ""), fallback="experiment")

    def _persist_take_numbers(self) -> None:
        current_experiment = self._current_experiment_name()
        self._take_numbers_by_experiment[current_experiment] = self._current_take_number(current_experiment)
        self._write_take_numbers_state()

    def _write_take_numbers_state(self) -> None:
        payload = {
            "schema_version": 1,
            "last_experiment_name": self._current_experiment_name(),
            "take_numbers_by_experiment": dict(sorted(self._take_numbers_by_experiment.items())),
        }
        try:
            TAKE_NUMBERS_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
            TAKE_NUMBERS_STATE_PATH.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
        except Exception as exc:
            self._append_log(f"Unable to save take-number state: {exc}")

    def _on_experiment_name_changed(self, *_args: Any) -> None:
        if self._is_syncing_experiment_take:
            return

        current_key = self._current_experiment_name()
        if current_key == self._last_experiment_key:
            return

        next_take = self._take_numbers_by_experiment.get(current_key, 1)
        self._last_experiment_key = current_key
        self._is_syncing_experiment_take = True
        try:
            self.take_number_var.set(str(max(1, next_take)))
        finally:
            self._is_syncing_experiment_take = False
        self._write_take_numbers_state()

    def _on_take_number_changed(self, *_args: Any) -> None:
        if self._is_syncing_experiment_take:
            return

        raw_take = self.take_number_var.get().strip()
        if not raw_take.isdigit():
            return
        self._take_numbers_by_experiment[self._current_experiment_name()] = max(1, int(raw_take))
        self._write_take_numbers_state()

    def _current_experiment_name(self) -> str:
        return self._safe_recording_component(self.experiment_name_var.get(), fallback="experiment")

    def _current_take_number(self, experiment_name: str | None = None) -> int:
        fallback = self._take_numbers_by_experiment.get(experiment_name or self._current_experiment_name(), 1)
        take = max(1, parse_nonnegative_int(self.take_number_var.get(), fallback=fallback))
        if self.take_number_var.get().strip() != str(take):
            self.take_number_var.set(str(take))
        return take

    def _safe_recording_component(self,
                                  value: str,
                                  fallback: str,
                                  allow_underscore: bool = False,
                                  max_length: int = 120) -> str:
        trimmed = (value or "").strip()
        output: list[str] = []
        last_was_separator = False
        for ch in trimmed:
            if ch.isascii() and ch.isalnum():
                output.append(ch)
                last_was_separator = False
            elif allow_underscore and ch == "_":
                output.append(ch)
                last_was_separator = False
            elif not last_was_separator:
                output.append("-")
                last_was_separator = True

        cleaned = "".join(output).strip("-_")
        return cleaned[:max_length] if cleaned else fallback

    def _capture_mode_filename_component(self) -> str:
        mode = self.capture_mode_var.get().strip()
        return CAPTURE_MODE_FILENAME_COMPONENTS.get(
            mode,
            self._safe_recording_component(mode, fallback="capturemode"),
        )

    def _recording_session_payload(self) -> dict[str, Any]:
        experiment_name = self._current_experiment_name()
        take_number = self._current_take_number(experiment_name)
        capture_mode = self._capture_mode_filename_component()
        session_time = datetime.utcnow().strftime("%Y%m%d")
        session_folder_name = self._safe_recording_component(
            f"{experiment_name}_{take_number}_{capture_mode}_{session_time}",
            fallback=f"experiment_{take_number}_{capture_mode}_{session_time}",
            allow_underscore=True,
        )

        self._take_numbers_by_experiment[experiment_name] = take_number
        self._persist_take_numbers()
        return {
            "session_id": f"session-{session_folder_name}",
            "experimentName": experiment_name,
            "experiment_name": experiment_name,
            "takeNumber": take_number,
            "take_number": take_number,
            "captureMode": capture_mode,
            "capture_mode": capture_mode,
            "sessionTime": session_time,
            "session_time": session_time,
            "sessionFolderName": session_folder_name,
            "session_folder_name": session_folder_name,
        }

    def _increment_take_after_recording_trigger(self, payload: dict[str, Any]) -> None:
        experiment_name = str(payload.get("experimentName") or "experiment")
        try:
            next_take = int(payload.get("takeNumber") or 1) + 1
        except Exception:
            next_take = self._take_numbers_by_experiment.get(experiment_name, 1) + 1
        next_take = max(1, next_take)
        self._take_numbers_by_experiment[experiment_name] = next_take
        if self._current_experiment_name() == experiment_name:
            self.take_number_var.set(str(next_take))
        self._persist_take_numbers()

    def _capture_mode_fps(self, mode: str) -> int | None:
        normalized = mode.strip().lower()
        if normalized.endswith("60"):
            return 60
        if normalized.endswith("30"):
            return 30
        return None

    def _sync_laptop_fps_to_capture_mode(self, mode: str) -> None:
        fps = self._capture_mode_fps(mode)
        if fps is None:
            return
        self.laptop_fps_var.set(str(fps))
        if self._time_source_is_laptop():
            self.server.configure_time_source(source="laptop", fps=fps)
            self._tick_tentacle_clock()
            self._append_log(f"Laptop timecode FPS set to {fps} for capture mode {mode}.")

    def start_server(self) -> None:
        host = self.host_var.get().strip() or "0.0.0.0"
        try:
            port = int(self.port_var.get().strip())
        except ValueError:
            self._append_log("Invalid port.")
            return
        try:
            upload_port = int(self.upload_port_var.get().strip())
        except ValueError:
            self._append_log("Invalid upload port.")
            return

        self.server_status_var.set(f"Server: starting on ws://{host}:{port}")
        self.server_summary_var.set("Starting")
        self.server.start(host, port)
        self._apply_time_source_settings()

        if self.upload_server.start(bind_host=host, port=upload_port):
            configured_upload_host = self.upload_host_var.get().strip()
            advertised_host = configured_upload_host or discover_advertised_host(host)
            self._upload_url_for_clients = self.upload_server.upload_url_for_clients(advertised_host=advertised_host)
            self.server.configure_preview_upload_url(self._upload_url_for_clients)
            self.upload_endpoint_var.set(f"Upload endpoint: {self._upload_url_for_clients}")
            if not configured_upload_host and advertised_host in {"127.0.0.1", "::1"}:
                self._append_log("Upload host auto-detected as loopback. Set Upload Host to your LAN IP for iPhone access.")
        else:
            self._upload_url_for_clients = ""
            self.server.configure_preview_upload_url("")
            self.upload_endpoint_var.set("Upload endpoint: failed to start")

    def stop_server(self) -> None:
        self.server_status_var.set("Server: stopping")
        self.server_summary_var.set("Stopping")
        self.upload_server.stop()
        self._upload_url_for_clients = ""
        self.server.configure_preview_upload_url("")
        self.upload_endpoint_var.set("Upload endpoint: stopped")
        self.server.stop()
        if not self.server.is_running:
            self.server_status_var.set("Server: stopped")
            self.server_summary_var.set("Stopped")

    def ping_all(self) -> None:
        self.server.send_command_all("ping", {})

    def get_status_all(self) -> None:
        self.server.send_command_all("get_status", {})

    def approve_remote_director(self) -> None:
        if not self._pending_remote_director_id:
            self._append_log("No pending remote director request to approve.")
            return
        self.server.approve_remote_director(self._pending_remote_director_id)

    def deny_remote_director(self) -> None:
        if not self._pending_remote_director_id:
            self._append_log("No pending remote director request to deny.")
            return
        self.server.deny_remote_director(self._pending_remote_director_id)

    def release_remote_director(self) -> None:
        if not self._active_remote_director_id:
            self._append_log("No active remote director to release.")
            return
        self.server.release_remote_director()

    def start_tentacle(self) -> None:
        if self._time_source_is_laptop():
            self._append_log("Time source is set to laptop. Switch to 'tentacle' to connect BLE timecode.")
            return
        target_name = self.tentacle_name_var.get().strip() or "NeuROK"
        self.tentacle_reader.start(target_name)

    def stop_tentacle(self) -> None:
        self.tentacle_reader.stop()
        self.server.clear_timecode_anchor()
        self._tentacle_anchor_monotonic = None
        self._tentacle_anchor_total_frames = None
        self._tentacle_anchor_fps = None
        self.tentacle_timecode_var.set("Director timecode: --:--:--:--")

    def arm_all(self) -> None:
        self.server.send_command_all("arm_idle", {})

    def arm_selected(self) -> None:
        self._send_selected_command("arm_idle", {})

    def prepare_recording_all(self) -> None:
        self.server.send_command_all("prepare_recording", self._recording_session_payload())

    def start_recording_all(self) -> None:
        payload = self._recording_session_payload()
        self.server.send_command_all("start_recording", payload)
        self._increment_take_after_recording_trigger(payload)

    def stop_recording_all(self) -> None:
        session_id = datetime.utcnow().strftime("session-%Y%m%d-%H%M%S")
        self.server.send_command_all("stop_recording", {"session_id": session_id})

    def prepare_recording_selected(self) -> None:
        self._send_selected_command("prepare_recording", self._recording_session_payload())

    def start_recording_selected(self) -> None:
        payload = self._recording_session_payload()
        if self._send_selected_command("start_recording", payload):
            self._increment_take_after_recording_trigger(payload)

    def stop_recording_selected(self) -> None:
        session_id = datetime.utcnow().strftime("session-%Y%m%d-%H%M%S")
        self._send_selected_command("stop_recording", {"session_id": session_id})

    def start_all(self) -> None:
        delay = parse_delay(self.start_delay_var.get(), fallback=2.0)
        start_at_ms = int((time.time() + delay) * 1000)
        payload = self._recording_session_payload()
        payload["start_at_unix_ms"] = start_at_ms

        # Two-step for safer coordination.
        self.server.send_command_sequence_all([
            ("prepare_start", payload),
            ("commit_start", payload),
        ])
        self._increment_take_after_recording_trigger(payload)

    def stop_all(self) -> None:
        delay = parse_delay(self.stop_delay_var.get(), fallback=2.0)
        stop_at_ms = int((time.time() + delay) * 1000)
        session_id = datetime.utcnow().strftime("session-%Y%m%d-%H%M%S")
        payload = {"session_id": session_id, "stop_at_unix_ms": stop_at_ms}
        self.server.send_command_all("prepare_stop", payload)

    def pull_selected_device(self) -> None:
        selected = self.tree.selection()
        if not selected:
            self._append_log("Select one device row before pulling videos.")
            return

        device_id = str(selected[0])
        max_files, concurrency = self._pull_upload_settings()
        if not self.upload_server.is_running or not self._upload_url_for_clients:
            self._append_log("Upload endpoint is not running. Start server first.")
            return

        self.server.configure_pull_concurrency(concurrency)
        self.server.queue_pull_videos(device_id=device_id,
                                      max_files=max_files,
                                      policy="new_only",
                                      upload_url=self._upload_url_for_clients)

    def pull_all_devices(self) -> None:
        if not self.upload_server.is_running or not self._upload_url_for_clients:
            self._append_log("Upload endpoint is not running. Start server first.")
            return

        max_files, concurrency = self._pull_upload_settings()
        devices = self.server.snapshot_devices()
        device_ids: list[str] = []
        skipped_recording: list[str] = []
        skipped_busy: list[str] = []

        for device in devices:
            device_id = str(device.get("device_id") or "")
            if not device_id:
                continue
            name = self._device_display_name(device)
            if bool(device.get("recording")):
                skipped_recording.append(name)
                continue
            if self._device_transfer_is_active(device):
                skipped_busy.append(name)
                continue
            device_ids.append(device_id)

        if not device_ids:
            self._append_log("No idle connected devices are available for Pull Videos All.")
            return

        self.server.queue_pull_videos_many(device_ids=device_ids,
                                           max_files=max_files,
                                           policy="new_only",
                                           upload_url=self._upload_url_for_clients,
                                           concurrency_limit=concurrency)
        detail = f"Queued Pull Videos All for {len(device_ids)} device(s) with concurrency {concurrency}."
        if skipped_recording:
            detail += f" Skipped recording: {', '.join(skipped_recording)}."
        if skipped_busy:
            detail += f" Skipped busy transfers: {', '.join(skipped_busy)}."
        self._append_log(detail)

    def delete_uploaded_videos_selected(self) -> None:
        device_id = self._selected_device_id()
        if not device_id:
            self._append_log("Select one device row before deleting uploaded videos.")
            return
        if not messagebox.askyesno(
            "Delete Uploaded Videos",
            "Delete local videos on the selected iPhone that are marked uploaded? Videos not marked uploaded will remain.",
        ):
            return
        self.server.send_command_to_device(device_id, "delete_uploaded_videos", {})

    def delete_uploaded_videos_all(self) -> None:
        devices = self.server.snapshot_devices()
        device_ids: list[str] = []
        skipped_recording: list[str] = []
        skipped_busy: list[str] = []
        for device in devices:
            device_id = str(device.get("device_id") or "")
            if not device_id:
                continue
            name = self._device_display_name(device)
            if bool(device.get("recording")):
                skipped_recording.append(name)
                continue
            if self._device_transfer_is_active(device):
                skipped_busy.append(name)
                continue
            device_ids.append(device_id)

        if not device_ids:
            self._append_log("No idle connected devices are available for Delete Uploaded All.")
            return
        if not messagebox.askyesno(
            "Delete Uploaded Videos",
            f"Delete local videos marked uploaded on {len(device_ids)} idle iPhone(s)? Videos not marked uploaded will remain.",
        ):
            return

        for device_id in device_ids:
            self.server.send_command_to_device(device_id, "delete_uploaded_videos", {})
        detail = f"Sent Delete Uploaded All to {len(device_ids)} device(s)."
        if skipped_recording:
            detail += f" Skipped recording: {', '.join(skipped_recording)}."
        if skipped_busy:
            detail += f" Skipped busy transfers: {', '.join(skipped_busy)}."
        self._append_log(detail)

    def _pull_upload_settings(self) -> tuple[int, int]:
        max_files = parse_nonnegative_int(self.pull_max_files_var.get(), fallback=0)
        concurrency = parse_nonnegative_int(self.pull_concurrency_var.get(), fallback=DEFAULT_PULL_CONCURRENCY)
        concurrency = max(1, min(MAX_PULL_CONCURRENCY, concurrency))
        if self.pull_concurrency_var.get().strip() != str(concurrency):
            self.pull_concurrency_var.set(str(concurrency))
        return max_files, concurrency

    def _device_transfer_is_active(self, device: dict[str, Any]) -> bool:
        transfer_state = str(device.get("transfer_state") or "").lower()
        return transfer_state in {"starting", "uploading", "progress"}

    def _device_display_name(self, device: dict[str, Any]) -> str:
        return str(device.get("name") or device.get("device_id") or "Unknown")

    def force_delete_videos_selected(self) -> None:
        device_id = self._selected_device_id()
        if not device_id:
            self._append_log("Select one device row before force-deleting videos.")
            return
        if not messagebox.askyesno(
            "Force Delete Videos",
            "Force-delete all local videos on the selected iPhone, including videos not marked uploaded?",
        ):
            return
        self.server.send_command_to_device(device_id, "force_delete_videos", {})

    def preview_photo_selected(self) -> None:
        device_id = self._selected_device_id()
        if not device_id:
            self._append_log("Select one device row before requesting a preview photo.")
            return
        if not self.upload_server.is_running or not self._upload_url_for_clients:
            self._append_log("Upload endpoint is not running. Start server first.")
            return

        self.server.configure_preview_upload_url(self._upload_url_for_clients)
        self.preview_status_var.set(f"Preview photos: requesting selected device {device_id}")
        self.server.request_preview_photo(device_id)

    def preview_photos_all(self) -> None:
        if not self.upload_server.is_running or not self._upload_url_for_clients:
            self._append_log("Upload endpoint is not running. Start server first.")
            return

        self.server.configure_preview_upload_url(self._upload_url_for_clients)
        self.preview_status_var.set("Preview photos: requesting all devices")
        self.server.request_preview_photos_all()

    def open_preview_folder(self) -> None:
        self._open_path(Path("director_app/captures/preview_photos"))

    def open_preview_grid_image(self) -> None:
        devices = self.server.snapshot_devices()
        grid_path = self._build_preview_grid_image(devices)
        if grid_path is None:
            self._append_log("No received preview images are available for a grid view.")
            return
        self.preview_status_var.set(f"Preview photos: grid view {grid_path}")
        self._open_path(grid_path)

    def _build_preview_grid_image(self, devices: list[dict[str, Any]]) -> Path | None:
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            self._append_log("Unable to create preview grid PNG: ffmpeg is not installed.")
            return None

        candidates: list[dict[str, Any]] = []
        for device in devices:
            image_path = Path(str(device.get("preview_image_path") or ""))
            if not image_path.is_file():
                continue
            candidates.append(device)

        if not candidates:
            return None

        latest_by_batch: dict[str, float] = {}
        for device in candidates:
            batch_id = str(device.get("preview_batch_id") or "")
            latest_by_batch[batch_id] = max(latest_by_batch.get(batch_id, 0), float(device.get("preview_updated_unix") or 0))
        latest_batch_id = max(latest_by_batch, key=latest_by_batch.get)
        batch_devices = [
            device
            for device in candidates
            if str(device.get("preview_batch_id") or "") == latest_batch_id
        ]
        if not batch_devices:
            batch_devices = candidates
        batch_devices.sort(key=lambda device: str(device.get("name") or device.get("device_id") or ""))

        count = len(batch_devices)
        columns = 1
        while columns * columns < count:
            columns += 1
        rows = (count + columns - 1) // columns
        cell_width = 320
        cell_height = 480

        inputs: list[str] = []
        filters: list[str] = []
        stack_inputs: list[str] = []
        layouts: list[str] = []

        output_dir = Path("director_app/captures/preview_photos") / (latest_batch_id or "latest")
        output_dir.mkdir(parents=True, exist_ok=True)
        output_path = output_dir / "grid_view.png"
        with tempfile.TemporaryDirectory(prefix="preview_grid_") as temp_dir:
            inputs.clear()
            filters.clear()
            stack_inputs.clear()
            layouts.clear()

            for index, device in enumerate(batch_devices):
                row = index // columns
                column = index % columns
                x = column * cell_width
                y = row * cell_height
                image_input = index * 2
                label_input = image_input + 1
                image_path = Path(str(device.get("preview_image_path") or ""))
                label_path = Path(temp_dir) / f"label_{index}.png"
                label = str(device.get("name") or device.get("device_id") or "Camera")
                self._write_label_overlay_png(label_path, label, cell_width, cell_height)

                inputs.extend(["-i", str(image_path), "-i", str(label_path)])
                filters.append(
                    f"[{image_input}:v]"
                    f"scale={cell_width}:{cell_height}:force_original_aspect_ratio=increase,"
                    f"crop={cell_width}:{cell_height},setsar=1"
                    f"[base{index}]"
                )
                filters.append(f"[{label_input}:v]format=rgba[label{index}]")
                filters.append(f"[base{index}][label{index}]overlay=0:0:format=auto[tile{index}]")
                stack_inputs.append(f"[tile{index}]")
                layouts.append(f"{x}_{y}")

            if len(stack_inputs) == 1:
                filters.append(
                    f"{stack_inputs[0]}"
                    f"format=rgb24[out]"
                )
            else:
                filters.append(
                    f"{''.join(stack_inputs)}"
                    f"xstack=inputs={len(stack_inputs)}:layout={'|'.join(layouts)}:"
                    f"fill=0x101820,"
                    f"format=rgb24[out]"
                )

            command = [
                ffmpeg,
                "-y",
                *inputs,
                "-filter_complex",
                ";".join(filters),
                "-map",
                "[out]",
                "-frames:v",
                "1",
                "-update",
                "1",
                str(output_path),
            ]
            try:
                subprocess.run(command, check=True, capture_output=True, text=True)
            except subprocess.CalledProcessError as exc:
                detail = (exc.stderr or exc.stdout or str(exc)).strip().splitlines()[-1:]
                self._append_log(f"Unable to create preview grid PNG: {detail[0] if detail else exc}")
                return None
            return output_path

    def _write_label_overlay_png(self, path: Path, text: str, width: int, height: int) -> None:
        pixels = bytearray([0, 0, 0, 0] * (width * height))
        scale = 5
        normalized = " ".join(text.replace("\n", " ").replace("\r", " ").upper().split())
        max_chars = max(1, (width - 24) // (6 * scale))
        if len(normalized) > max_chars:
            if max_chars <= 3:
                normalized = normalized[:max_chars]
            else:
                normalized = normalized[: max_chars - 3].rstrip() + "..."
        self._draw_bitmap_text(pixels, normalized, width, height, 10, 10, scale, (0, 0, 0), alpha=160, bold=True)
        self._draw_bitmap_text(pixels, normalized, width, height, 8, 8, scale, (230, 0, 0), alpha=255, bold=True)
        self._write_rgba_png(path, width, height, pixels)

    def _draw_bitmap_text(
        self,
        pixels: bytearray,
        text: str,
        width: int,
        height: int,
        x: int,
        y: int,
        scale: int,
        color: tuple[int, int, int],
        alpha: int | None = None,
        bold: bool = False,
    ) -> None:
        channels = 4 if alpha is not None else 3
        cursor_x = x
        for char in text:
            glyph = self._bitmap_for_char(char)
            for row_index, row in enumerate(glyph):
                for col_index, bit in enumerate(row):
                    if bit == " ":
                        continue
                    px = cursor_x + (col_index * scale)
                    py = y + (row_index * scale)
                    extra_width = 1 if bold else 0
                    for dy in range(scale):
                        for dx in range(scale + extra_width):
                            target_x = px + dx
                            target_y = py + dy
                            if 0 <= target_x < width and 0 <= target_y < height:
                                offset = ((target_y * width) + target_x) * channels
                                if alpha is None:
                                    pixels[offset : offset + 3] = bytes(color)
                                else:
                                    pixels[offset : offset + 4] = bytes((*color, alpha))
            cursor_x += 6 * scale

    def _bitmap_for_char(self, char: str) -> tuple[str, ...]:
        glyphs: dict[str, tuple[str, ...]] = {
            "A": (" ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"),
            "B": ("#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### "),
            "C": (" ####", "#    ", "#    ", "#    ", "#    ", "#    ", " ####"),
            "D": ("#### ", "#   #", "#   #", "#   #", "#   #", "#   #", "#### "),
            "E": ("#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####"),
            "F": ("#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    "),
            "G": (" ####", "#    ", "#    ", "#  ##", "#   #", "#   #", " ####"),
            "H": ("#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"),
            "I": ("#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "#####"),
            "J": ("#####", "    #", "    #", "    #", "#   #", "#   #", " ### "),
            "K": ("#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #"),
            "L": ("#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####"),
            "M": ("#   #", "## ##", "# # #", "#   #", "#   #", "#   #", "#   #"),
            "N": ("#   #", "##  #", "# # #", "#  ##", "#   #", "#   #", "#   #"),
            "O": (" ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "),
            "P": ("#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    "),
            "Q": (" ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #"),
            "R": ("#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #"),
            "S": (" ####", "#    ", "#    ", " ### ", "    #", "    #", "#### "),
            "T": ("#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "),
            "U": ("#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "),
            "V": ("#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  "),
            "W": ("#   #", "#   #", "#   #", "#   #", "# # #", "## ##", "#   #"),
            "X": ("#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #"),
            "Y": ("#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  "),
            "Z": ("#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####"),
            "0": (" ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### "),
            "1": ("  #  ", " ##  ", "# #  ", "  #  ", "  #  ", "  #  ", "#####"),
            "2": (" ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####"),
            "3": ("#### ", "    #", "    #", " ### ", "    #", "    #", "#### "),
            "4": ("#   #", "#   #", "#   #", "#####", "    #", "    #", "    #"),
            "5": ("#####", "#    ", "#    ", "#### ", "    #", "    #", "#### "),
            "6": (" ### ", "#    ", "#    ", "#### ", "#   #", "#   #", " ### "),
            "7": ("#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   "),
            "8": (" ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### "),
            "9": (" ### ", "#   #", "#   #", " ####", "    #", "    #", " ### "),
            " ": ("     ", "     ", "     ", "     ", "     ", "     ", "     "),
            "-": ("     ", "     ", "     ", "#####", "     ", "     ", "     "),
            "_": ("     ", "     ", "     ", "     ", "     ", "     ", "#####"),
            ".": ("     ", "     ", "     ", "     ", "     ", " ##  ", " ##  "),
            ":": ("     ", " ##  ", " ##  ", "     ", " ##  ", " ##  ", "     "),
            "/": ("    #", "    #", "   # ", "  #  ", " #   ", "#    ", "#    "),
            "(": ("   # ", "  #  ", " #   ", " #   ", " #   ", "  #  ", "   # "),
            ")": (" #   ", "  #  ", "   # ", "   # ", "   # ", "  #  ", " #   "),
        }
        return glyphs.get(char, glyphs[" "])

    def _write_rgb_png(self, path: Path, width: int, height: int, pixels: bytearray) -> None:
        def chunk(tag: bytes, data: bytes) -> bytes:
            checksum = zlib.crc32(tag + data) & 0xFFFFFFFF
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", checksum)

        scanlines = [
            b"\x00" + bytes(pixels[(row * width * 3) : ((row + 1) * width * 3)])
            for row in range(height)
        ]
        payload = b"".join(
            [
                b"\x89PNG\r\n\x1a\n",
                chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)),
                chunk(b"IDAT", zlib.compress(b"".join(scanlines))),
                chunk(b"IEND", b""),
            ]
        )
        path.write_bytes(payload)

    def _write_rgba_png(self, path: Path, width: int, height: int, pixels: bytearray) -> None:
        def chunk(tag: bytes, data: bytes) -> bytes:
            checksum = zlib.crc32(tag + data) & 0xFFFFFFFF
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", checksum)

        scanlines = [
            b"\x00" + bytes(pixels[(row * width * 4) : ((row + 1) * width * 4)])
            for row in range(height)
        ]
        payload = b"".join(
            [
                b"\x89PNG\r\n\x1a\n",
                chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)),
                chunk(b"IDAT", zlib.compress(b"".join(scanlines))),
                chunk(b"IEND", b""),
            ]
        )
        path.write_bytes(payload)

    def open_selected_preview_image(self) -> None:
        selected = self.tree.selection()
        if not selected:
            self._append_log("Select one device row before opening a preview image.")
            return
        values = self.tree.item(selected[0], "values")
        columns = list(self.tree["columns"])
        try:
            path_index = columns.index("preview_path")
        except ValueError:
            self._append_log("Preview path column is unavailable.")
            return
        if not values or len(values) <= path_index:
            self._append_log("No preview image path is available for the selected row.")
            return
        preview_path = str(values[path_index])
        if not preview_path:
            self._append_log("No preview image path is available for the selected row.")
            return
        self._open_path(Path(preview_path))

    def _selected_device_id(self) -> str:
        selected = self.tree.selection()
        if not selected:
            return ""
        return str(selected[0])

    def _send_selected_command(self, command: str, payload: dict[str, Any]) -> bool:
        device_id = self._selected_device_id()
        if not device_id:
            self._append_log(f"Select one device row before sending {command}.")
            return False
        self.server.send_command_to_device(device_id, command, payload)
        return True

    def _open_path(self, path: Path) -> None:
        try:
            path.mkdir(parents=True, exist_ok=True) if path.suffix == "" else None
            if sys.platform == "darwin":
                subprocess.Popen(["open", str(path)])
            elif sys.platform.startswith("win"):
                subprocess.Popen(["cmd", "/c", "start", "", str(path)])
            else:
                subprocess.Popen(["xdg-open", str(path)])
        except Exception as exc:
            self._append_log(f"Unable to open {path}: {exc}")

    def copy_camera_params_selected(self) -> None:
        selected = self.tree.selection()
        if not selected:
            self._append_log("Select one device row before copying camera params.")
            return

        device_id = str(selected[0])
        self.camera_params_var.set(f"Camera params: copying from {device_id}")
        self.server.copy_camera_params(device_id)

    def dry_run_sync_camera_params(self) -> None:
        self.camera_params_var.set("Camera params: dry run sync started")
        self.server.sync_camera_params_all(dry_run=True)

    def sync_camera_params_all(self) -> None:
        self.camera_params_var.set("Camera params: sync started")
        self.server.sync_camera_params_all(dry_run=False)

    def enable_auto_focus_selected(self) -> None:
        self._send_selected_command("set_focus_mode", {"mode": "continuous_auto_focus"})

    def lock_focus_selected(self) -> None:
        self._send_selected_command("lock_focus", {"mode": "locked"})

    def lock_camera_param_locks_selected(self) -> None:
        self._send_selected_command("lock_camera_param_locks", {})

    def unlock_camera_param_locks_selected(self) -> None:
        self._send_selected_command("release_camera_param_locks", {"preserve_focus": True})

    def set_capture_mode_selected(self) -> None:
        mode = self.capture_mode_var.get().strip()
        if not mode:
            self._append_log("Select a capture mode before sending.")
            return
        self._sync_laptop_fps_to_capture_mode(mode)
        self._send_selected_command("set_capture_mode", {"mode": mode})

    def set_capture_mode_all(self) -> None:
        mode = self.capture_mode_var.get().strip()
        if not mode:
            self._append_log("Select a capture mode before broadcasting.")
            return
        self._sync_laptop_fps_to_capture_mode(mode)
        self.server.send_command_all("set_capture_mode", {"mode": mode})

    def on_close(self) -> None:
        self._persist_take_numbers()
        self.tentacle_reader.stop()
        self.server.clear_timecode_anchor()
        self.upload_server.stop()
        self.server.stop()
        self.root.destroy()


def main() -> None:
    root = Tk()
    style = ttk.Style(root)
    try:
        style.theme_use("clam")
    except Exception:
        pass
    DirectorGUI(root)
    root.mainloop()
