from __future__ import annotations

import queue
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from tkinter import END, StringVar, Text, Tk, messagebox, ttk
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
        self.start_delay_var = StringVar(value="2.0")
        self.stop_delay_var = StringVar(value="2.0")
        self.tentacle_name_var = StringVar(value="NeuROK")
        self.time_source_var = StringVar(value="laptop")
        self.laptop_fps_var = StringVar(value="30")
        self.pull_max_files_var = StringVar(value="0")
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
        self.selected_device_var = StringVar(value="No camera selected")
        self._upload_url_for_clients = ""
        self._latest_devices_by_id: dict[str, dict[str, Any]] = {}
        self.workspace: ttk.PanedWindow | None = None

        self._tentacle_anchor_monotonic: float | None = None
        self._tentacle_anchor_total_frames: int | None = None
        self._tentacle_anchor_fps: int | None = None

        self._build_ui()
        self._apply_time_source_settings()
        self._schedule_pump()
        self._schedule_status_refresh()
        self._schedule_tentacle_clock()

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
        tab = ttk.Frame(notebook, padding=12, style="Panel.TFrame")
        tab.columnconfigure(0, weight=1)

        server = ttk.LabelFrame(tab, text="Server", padding=10, style="Panel.TLabelframe")
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

        timecode = ttk.LabelFrame(tab, text="Timecode", padding=10, style="Panel.TLabelframe")
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

        status = ttk.LabelFrame(tab, text="Director Status", padding=10, style="Panel.TLabelframe")
        status.grid(row=2, column=0, sticky="ew", pady=(12, 0))
        status.columnconfigure(0, weight=1)
        self.upload_endpoint_label = ttk.Label(status, textvariable=self.upload_endpoint_var, style="Muted.TLabel", wraplength=380)
        self.upload_endpoint_label.grid(row=0, column=0, sticky="w")
        self.pull_status_label = ttk.Label(status, textvariable=self.pull_status_var, style="Muted.TLabel", wraplength=380)
        self.pull_status_label.grid(row=1, column=0, sticky="w", pady=(6, 0))

        return tab

    def _build_record_tab(self, notebook: ttk.Notebook) -> ttk.Frame:
        tab = ttk.Frame(notebook, padding=12, style="Panel.TFrame")
        tab.columnconfigure(0, weight=1)

        timing = ttk.LabelFrame(tab, text="Scheduled Recording", padding=10, style="Panel.TLabelframe")
        timing.grid(row=0, column=0, sticky="ew")
        for col in range(2):
            timing.columnconfigure(col, weight=1)
        self._labeled_entry(timing, "Start Delay (s)", self.start_delay_var, row=0, column=0, width=8)
        self._labeled_entry(timing, "Stop Delay (s)", self.stop_delay_var, row=0, column=1, width=8)
        ttk.Button(timing, text="Prepare + Commit Start", command=self.start_all, style="Primary.TButton").grid(
            row=1, column=0, sticky="ew", pady=(10, 0), padx=(0, 6)
        )
        ttk.Button(timing, text="Prepare Stop", command=self.stop_all).grid(
            row=1, column=1, sticky="ew", pady=(10, 0), padx=(6, 0)
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
        ttk.Button(transfer, text="Pull Videos Selected", command=self.pull_selected_device, style="Primary.TButton").grid(
            row=1, column=0, columnspan=2, sticky="ew", pady=(10, 0)
        )
        ttk.Button(transfer, text="Delete Uploaded Selected", command=self.delete_uploaded_videos_selected).grid(
            row=2, column=0, sticky="ew", pady=(10, 0), padx=(0, 6)
        )
        ttk.Button(transfer, text="Force Delete Selected", command=self.force_delete_videos_selected, style="Danger.TButton").grid(
            row=2, column=1, sticky="ew", pady=(10, 0), padx=(6, 0)
        )

        preview = ttk.LabelFrame(tab, text="Preview Photos", padding=10, style="Panel.TLabelframe")
        preview.grid(row=1, column=0, sticky="ew", pady=(12, 0))
        preview.columnconfigure(0, weight=1)
        preview.columnconfigure(1, weight=1)
        ttk.Button(preview, text="Preview Selected", command=self.preview_photo_selected).grid(
            row=0, column=0, sticky="ew", padx=(0, 6)
        )
        ttk.Button(preview, text="Preview All", command=self.preview_photos_all).grid(
            row=0, column=1, sticky="ew", padx=(6, 0)
        )
        ttk.Button(preview, text="Open Preview Folder", command=self.open_preview_folder).grid(
            row=1, column=0, sticky="ew", pady=(10, 0), padx=(0, 6)
        )
        ttk.Button(preview, text="Open Selected Image", command=self.open_selected_preview_image).grid(
            row=1, column=1, sticky="ew", pady=(10, 0), padx=(6, 0)
        )
        self.preview_status_label = ttk.Label(preview, textvariable=self.preview_status_var, style="Muted.TLabel", wraplength=380)
        self.preview_status_label.grid(row=2, column=0, columnspan=2, sticky="w", pady=(12, 0))
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
        self._refresh_tree(self.server.snapshot_devices())
        pull = self.server.pull_status()
        active_device = pull.get("active_device_id", "")
        active_job = pull.get("active_job_id", "")
        queued = pull.get("queued_count", 0)

        if active_device:
            self.pull_status_var.set(
                f"Pull queue: active={active_device} job={active_job} queued={queued}"
            )
        elif queued:
            self.pull_status_var.set(f"Pull queue: queued={queued}, waiting for active job")
        else:
            self.pull_status_var.set("Pull queue: idle")

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
        session_id = datetime.utcnow().strftime("session-%Y%m%d-%H%M%S")
        self.server.send_command_all("prepare_recording", {"session_id": session_id})

    def start_recording_all(self) -> None:
        session_id = datetime.utcnow().strftime("session-%Y%m%d-%H%M%S")
        self.server.send_command_all("start_recording", {"session_id": session_id})

    def stop_recording_all(self) -> None:
        session_id = datetime.utcnow().strftime("session-%Y%m%d-%H%M%S")
        self.server.send_command_all("stop_recording", {"session_id": session_id})

    def prepare_recording_selected(self) -> None:
        session_id = datetime.utcnow().strftime("session-%Y%m%d-%H%M%S")
        self._send_selected_command("prepare_recording", {"session_id": session_id})

    def start_recording_selected(self) -> None:
        session_id = datetime.utcnow().strftime("session-%Y%m%d-%H%M%S")
        self._send_selected_command("start_recording", {"session_id": session_id})

    def stop_recording_selected(self) -> None:
        session_id = datetime.utcnow().strftime("session-%Y%m%d-%H%M%S")
        self._send_selected_command("stop_recording", {"session_id": session_id})

    def start_all(self) -> None:
        delay = parse_delay(self.start_delay_var.get(), fallback=2.0)
        start_at_ms = int((time.time() + delay) * 1000)
        session_id = datetime.utcnow().strftime("session-%Y%m%d-%H%M%S")
        payload = {"session_id": session_id, "start_at_unix_ms": start_at_ms}

        # Two-step for safer coordination.
        self.server.send_command_all("prepare_start", payload)
        self.server.send_command_all("commit_start", payload)

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
        max_files = parse_nonnegative_int(self.pull_max_files_var.get(), fallback=0)
        if not self.upload_server.is_running or not self._upload_url_for_clients:
            self._append_log("Upload endpoint is not running. Start server first.")
            return

        self.server.queue_pull_videos(device_id=device_id,
                                      max_files=max_files,
                                      policy="new_only",
                                      upload_url=self._upload_url_for_clients)

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

    def _send_selected_command(self, command: str, payload: dict[str, Any]) -> None:
        device_id = self._selected_device_id()
        if not device_id:
            self._append_log(f"Select one device row before sending {command}.")
            return
        self.server.send_command_to_device(device_id, command, payload)

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
