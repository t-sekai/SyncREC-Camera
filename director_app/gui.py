from __future__ import annotations

import queue
import time
from datetime import datetime
from tkinter import BOTH, END, LEFT, RIGHT, TOP, X, Y, StringVar, Text, Tk, ttk
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


class DirectorGUI:
    def __init__(self, root: Tk):
        self.root = root
        self.root.title("Multi-Cam Director")
        self.root.geometry("1320x740")

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
        self.time_source_var = StringVar(value="tentacle")
        self.laptop_fps_var = StringVar(value="30")
        self.pull_max_files_var = StringVar(value="0")
        self.tentacle_state_var = StringVar(value="Tentacle: idle")
        self.tentacle_timecode_var = StringVar(value="Director timecode: --:--:--:--")
        self.pull_status_var = StringVar(value="Pull queue: idle")
        self.upload_endpoint_var = StringVar(value="Upload endpoint: stopped")
        self.camera_params_var = StringVar(value="Camera params: no preset")
        self._upload_url_for_clients = ""

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
        controls = ttk.Frame(self.root, padding=8)
        controls.pack(side=TOP, fill=X)

        ttk.Label(controls, text="Host:").pack(side=LEFT)
        ttk.Entry(controls, textvariable=self.host_var, width=15).pack(side=LEFT, padx=(4, 10))
        ttk.Label(controls, text="Port:").pack(side=LEFT)
        ttk.Entry(controls, textvariable=self.port_var, width=8).pack(side=LEFT, padx=(4, 10))
        ttk.Label(controls, text="Upload Host:").pack(side=LEFT)
        ttk.Entry(controls, textvariable=self.upload_host_var, width=14).pack(side=LEFT, padx=(4, 10))
        ttk.Label(controls, text="Upload Port:").pack(side=LEFT)
        ttk.Entry(controls, textvariable=self.upload_port_var, width=8).pack(side=LEFT, padx=(4, 10))

        ttk.Button(controls, text="Start Server", command=self.start_server).pack(side=LEFT, padx=3)
        ttk.Button(controls, text="Stop Server", command=self.stop_server).pack(side=LEFT, padx=3)
        ttk.Button(controls, text="Ping All", command=self.ping_all).pack(side=LEFT, padx=(10, 3))
        ttk.Label(controls, text="Time Source:").pack(side=LEFT, padx=(12, 3))
        source_menu = ttk.Combobox(controls,
                                   textvariable=self.time_source_var,
                                   width=10,
                                   values=("tentacle", "laptop"),
                                   state="readonly")
        source_menu.pack(side=LEFT, padx=(2, 4))
        source_menu.bind("<<ComboboxSelected>>", self._on_time_source_changed)
        ttk.Label(controls, text="Laptop FPS:").pack(side=LEFT, padx=(8, 3))
        fps_entry = ttk.Entry(controls, textvariable=self.laptop_fps_var, width=4)
        fps_entry.pack(side=LEFT, padx=(2, 6))
        fps_entry.bind("<FocusOut>", self._on_time_source_changed)
        fps_entry.bind("<Return>", self._on_time_source_changed)
        ttk.Label(controls, text="Tentacle Name:").pack(side=LEFT, padx=(16, 3))
        ttk.Entry(controls, textvariable=self.tentacle_name_var, width=12).pack(side=LEFT, padx=(2, 4))
        ttk.Button(controls, text="Connect TC", command=self.start_tentacle).pack(side=LEFT, padx=3)
        ttk.Button(controls, text="Stop TC", command=self.stop_tentacle).pack(side=LEFT, padx=3)

        ttk.Separator(self.root).pack(fill=X, padx=8, pady=6)

        actions = ttk.Frame(self.root, padding=(8, 2))
        actions.pack(side=TOP, fill=X)

        ttk.Button(actions, text="Arm All", command=self.arm_all).pack(side=LEFT, padx=3)
        ttk.Label(actions, text="Start Delay (s):").pack(side=LEFT, padx=(12, 3))
        ttk.Entry(actions, textvariable=self.start_delay_var, width=8).pack(side=LEFT)
        ttk.Button(actions, text="Prepare + Commit Start", command=self.start_all).pack(side=LEFT, padx=3)

        ttk.Label(actions, text="Stop Delay (s):").pack(side=LEFT, padx=(12, 3))
        ttk.Entry(actions, textvariable=self.stop_delay_var, width=8).pack(side=LEFT)
        ttk.Button(actions, text="Prepare Stop", command=self.stop_all).pack(side=LEFT, padx=3)

        ttk.Separator(self.root).pack(fill=X, padx=8, pady=6)

        transfer_actions = ttk.Frame(self.root, padding=(8, 2))
        transfer_actions.pack(side=TOP, fill=X)
        ttk.Label(transfer_actions, text="Pull Max Files (0=all):").pack(side=LEFT, padx=(0, 4))
        ttk.Entry(transfer_actions, textvariable=self.pull_max_files_var, width=8).pack(side=LEFT)
        ttk.Button(transfer_actions,
                   text="Pull Videos (Selected)",
                   command=self.pull_selected_device).pack(side=LEFT, padx=6)

        camera_param_actions = ttk.Frame(self.root, padding=(8, 2))
        camera_param_actions.pack(side=TOP, fill=X)
        ttk.Button(camera_param_actions,
                   text="Copy Params Selected",
                   command=self.copy_camera_params_selected).pack(side=LEFT, padx=3)
        ttk.Button(camera_param_actions,
                   text="Dry Run Sync",
                   command=self.dry_run_sync_camera_params).pack(side=LEFT, padx=3)
        ttk.Button(camera_param_actions,
                   text="Sync Params All",
                   command=self.sync_camera_params_all).pack(side=LEFT, padx=3)
        ttk.Label(camera_param_actions, textvariable=self.camera_params_var).pack(side=LEFT, padx=(12, 3))

        columns = (
            "name",
            "device_id",
            "endpoint",
            "app",
            "armed",
            "recording",
            "battery",
            "storage",
            "tentacle",
            "timecode",
            "camera_params",
            "transfer",
            "last_seen",
            "pending",
        )
        self.tree = ttk.Treeview(self.root, columns=columns, show="headings", height=18)
        for col in columns:
            self.tree.heading(col, text=col)

        widths = {
            "name": 120,
            "device_id": 130,
            "endpoint": 140,
            "app": 80,
            "armed": 65,
            "recording": 80,
            "battery": 70,
            "storage": 75,
            "tentacle": 110,
            "timecode": 120,
            "camera_params": 180,
            "transfer": 180,
            "last_seen": 90,
            "pending": 210,
        }
        for col, width in widths.items():
            self.tree.column(col, width=width, anchor="center")

        self.tree.pack(fill=BOTH, expand=True, padx=8, pady=(6, 8))

        bottom = ttk.Frame(self.root, padding=8)
        bottom.pack(side=TOP, fill=BOTH, expand=True)

        self.status_label = ttk.Label(bottom, text="Server: stopped")
        self.status_label.pack(anchor="w", pady=(0, 6))
        self.tentacle_status_label = ttk.Label(bottom, textvariable=self.tentacle_state_var)
        self.tentacle_status_label.pack(anchor="w", pady=(0, 2))
        self.tentacle_timecode_label = ttk.Label(bottom, textvariable=self.tentacle_timecode_var)
        self.tentacle_timecode_label.pack(anchor="w", pady=(0, 2))
        self.pull_status_label = ttk.Label(bottom, textvariable=self.pull_status_var)
        self.pull_status_label.pack(anchor="w", pady=(0, 2))
        self.upload_endpoint_label = ttk.Label(bottom, textvariable=self.upload_endpoint_var)
        self.upload_endpoint_label.pack(anchor="w", pady=(0, 2))
        self.camera_params_label = ttk.Label(bottom, textvariable=self.camera_params_var)
        self.camera_params_label.pack(anchor="w", pady=(0, 6))

        self.log_box = Text(bottom, height=12, wrap="word")
        self.log_box.pack(side=LEFT, fill=BOTH, expand=True)

        log_scroll = ttk.Scrollbar(bottom, command=self.log_box.yview)
        log_scroll.pack(side=RIGHT, fill=Y)
        self.log_box.configure(yscrollcommand=log_scroll.set)

    def _schedule_pump(self) -> None:
        self._pump_events()
        self.root.after(100, self._schedule_pump)

    def _pump_events(self) -> None:
        while True:
            try:
                etype, payload = self.event_queue.get_nowait()
            except queue.Empty:
                break

            if etype == "log":
                self._append_log(str(payload))
            elif etype == "server_started":
                self.status_label.configure(text=f"Server: running on ws://{payload['host']}:{payload['port']}")
            elif etype == "server_stopped":
                self.status_label.configure(text="Server: stopped")
            elif etype == "devices_updated":
                self._refresh_tree(payload)
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
                    self._set_tentacle_anchor_from_packet(payload)
                    self.server.update_timecode_anchor(payload)

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
        self.root.after(50, self._schedule_tentacle_clock)

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
            selected_values = self.tree.item(selected_items[0], "values")
            if selected_values and len(selected_values) >= 2:
                selected_device_id = str(selected_values[1])

        self.tree.delete(*self.tree.get_children())
        now = time.time()
        selected_row_id = ""
        for d in devices:
            pending = ", ".join(d["pending_acks"].values()) if d["pending_acks"] else ""
            battery = f"{d['battery']*100:.0f}%" if isinstance(d["battery"], float) else "-"
            storage = f"{d['storage_gb']:.1f} GB" if isinstance(d["storage_gb"], float) else "-"
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

            item_id = self.tree.insert(
                "",
                END,
                values=(
                    d["name"],
                    d["device_id"],
                    d["endpoint"],
                    d["app_version"],
                    yes_no(d["armed"]),
                    yes_no(d["recording"]),
                    battery,
                    storage,
                    d["tentacle_state"],
                    timecode_text(d["timecode"], d["fps"]),
                    camera_params,
                    transfer,
                    last_seen,
                    pending,
                ),
            )
            if selected_device_id and str(d["device_id"]) == selected_device_id:
                selected_row_id = item_id

        if selected_row_id:
            self.tree.selection_set(selected_row_id)
            self.tree.focus(selected_row_id)
            self.tree.see(selected_row_id)

    def _append_log(self, line: str) -> None:
        self.log_box.insert(END, line + "\n")
        self.log_box.see(END)

    def _time_source_is_laptop(self) -> bool:
        return self.time_source_var.get().strip().lower() == "laptop"

    def _resolved_laptop_fps(self) -> int:
        try:
            fps = int(self.laptop_fps_var.get().strip())
        except ValueError:
            fps = 30
        fps = min(max(fps, 1), 120)
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

        self.server.start(host, port)
        self._apply_time_source_settings()

        if self.upload_server.start(bind_host=host, port=upload_port):
            configured_upload_host = self.upload_host_var.get().strip()
            advertised_host = configured_upload_host or discover_advertised_host(host)
            self._upload_url_for_clients = self.upload_server.upload_url_for_clients(advertised_host=advertised_host)
            self.upload_endpoint_var.set(f"Upload endpoint: {self._upload_url_for_clients}")
            if not configured_upload_host and advertised_host in {"127.0.0.1", "::1"}:
                self._append_log("Upload host auto-detected as loopback. Set Upload Host to your LAN IP for iPhone access.")
        else:
            self._upload_url_for_clients = ""
            self.upload_endpoint_var.set("Upload endpoint: failed to start")

    def stop_server(self) -> None:
        self.upload_server.stop()
        self._upload_url_for_clients = ""
        self.upload_endpoint_var.set("Upload endpoint: stopped")
        self.server.stop()

    def ping_all(self) -> None:
        self.server.send_command_all("ping", {})

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
        self.server.send_command_all("arm", {})

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

        values = self.tree.item(selected[0], "values")
        if not values or len(values) < 2:
            self._append_log("Unable to read selected row.")
            return

        device_id = str(values[1])
        max_files = parse_nonnegative_int(self.pull_max_files_var.get(), fallback=0)
        if not self.upload_server.is_running or not self._upload_url_for_clients:
            self._append_log("Upload endpoint is not running. Start server first.")
            return

        self.server.queue_pull_videos(device_id=device_id,
                                      max_files=max_files,
                                      policy="new_only",
                                      upload_url=self._upload_url_for_clients)

    def copy_camera_params_selected(self) -> None:
        selected = self.tree.selection()
        if not selected:
            self._append_log("Select one device row before copying camera params.")
            return

        values = self.tree.item(selected[0], "values")
        if not values or len(values) < 2:
            self._append_log("Unable to read selected row.")
            return

        device_id = str(values[1])
        self.camera_params_var.set(f"Camera params: copying from {device_id}")
        self.server.copy_camera_params(device_id)

    def dry_run_sync_camera_params(self) -> None:
        self.camera_params_var.set("Camera params: dry run sync started")
        self.server.sync_camera_params_all(dry_run=True)

    def sync_camera_params_all(self) -> None:
        self.camera_params_var.set("Camera params: sync started")
        self.server.sync_camera_params_all(dry_run=False)

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
