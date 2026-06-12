# Python Director Dev Notes

These notes cover the desktop director side of SyncREC. The director is a Python/Tkinter app that hosts the WebSocket control plane, shows rig status, schedules coordinated recording commands, receives preview photos, and manages video pulls from connected iPhones.

## Entry Points

- `director.py`: thin executable entry point.
- `director_app/gui.py`: Tkinter UI, device table, tabs, button actions, persistent UI state, and log output.
- `director_app/server.py`: asyncio WebSocket server, command routing, time-sync broadcast, pull queue, preview tracking, and camera-parameter sync routing.
- `director_app/models.py`: normalized device-state parsing and formatting helpers.
- `director_app/upload_server.py`: local HTTP upload receiver for preview photos and pulled videos.

Run the director from the repository root:

```sh
python3 director.py
```

The WebSocket server defaults to `0.0.0.0:8765`. The upload ingest server is started by the GUI when transfer or preview features need it.

## Runtime Model

The GUI runs on the main thread. The WebSocket server runs an asyncio loop in a background thread and posts events back to the GUI through a queue. GUI button handlers call thread-safe server methods, which then broadcast commands or send per-device commands to connected camera clients.

Connected clients identify their role as a camera or remote director candidate. Camera devices populate the main rig table. Remote director approval is handled separately so another phone can issue director controls when approved.

## Device State

Each camera status update is normalized into a `DeviceState` object. The director tracks:

- identity, role, connection timing, and pending acknowledgements;
- recording and armed state;
- battery, storage, and local video counts;
- pending uploads and transfer state;
- requested and actual capture mode;
- timecode and director-clock FPS;
- camera-parameter sync status and reports;
- preview-photo state and local preview paths;
- power policy, Guided Access, idle-timer, and transfer-awake state.

The header summary shows server state, number of connected cameras, how many devices are in sync with the current camera-parameter preset, recording count, armed count, and remote director status.

## Capture And Time Sync

The director stores the last selected capture mode in `director_app/state/take_numbers.json`. On launch, it initializes the director clock FPS from that capture mode so timecode display and outgoing time-sync packets start with the expected rate.

Time-sync packets are sent repeatedly while the server is running. They include the director's current wall-clock time, monotonic timing context, sequence number, and FPS. Camera clients use these packets to estimate clock offset and display/report timecode aligned to the director.

## Recording Flow

The main recording flow is:

1. Create a session payload from experiment name, take number, selected capture mode, and session time.
2. Optionally arm or prepare devices.
3. Broadcast scheduled prepare/start commands or a prepare-plus-commit sequence.
4. Broadcast scheduled stop commands.
5. Increment or persist take state as needed.

Most controls are available for all cameras or the selected camera, with the all-device action placed on the left and the selected-device action on the right in the UI.

## Preview Photos

Preview requests can target all devices or a selected device. The server assigns request IDs, configures an upload URL, tracks timeouts/retries, and records received image and metadata paths.

The GUI can open a selected preview, open the preview folder, or build a grid image from the latest preview batch when `ffmpeg` is available.

Preview outputs live under:

```text
director_app/captures/preview_photos/
```

## Video Pulls

Video pulls are queued so the director does not ask every phone to upload large 4K files at once. `DirectorServer.MAX_PULL_CONCURRENCY` defines the hard cap and the GUI exposes the active limit.

Pull commands include a job ID, selection policy, max file count, upload URL, and optional Auto-Lock-after-pull behavior. Devices release their active queue slot when a transfer exits, fails, or is cancelled. Upload output is written by the ingest server under the director capture folders.

## Camera-Parameter Sync

The director can copy a parameter preset from a selected phone, dry-run that preset against all phones, apply it, and validate results. Reports are persisted in:

```text
camera_param_presets/
camera_param_sync_reports/
```

The UI's parameter-sync count treats devices as in sync when the current status/report says `in_sync`, `exact_match`, `adjusted_match`, or non-dry-run `copied`.

## Persistent And Generated State

Key local state:

```text
director_app/state/take_numbers.json
director_app/captures/
camera_param_presets/
camera_param_sync_reports/
```

These directories contain run-specific state, received media, or reports rather than application source. Keep that distinction in mind when reviewing diffs.

## Lightweight Verification

For Python source checks without rewriting tracked bytecode:

```sh
python3 -c "import ast, pathlib; [ast.parse(pathlib.Path(p).read_text()) for p in ['director.py', 'director_app/gui.py', 'director_app/server.py', 'director_app/models.py', 'director_app/upload_server.py']]"
```

Avoid broad `compileall` runs in this repository because they can touch tracked `__pycache__` artifacts.
