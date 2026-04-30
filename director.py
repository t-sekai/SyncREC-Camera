#!/usr/bin/env python3
"""
Laptop director for multi-iPhone recording control.

This script is a thin entrypoint. Implementation lives under `director_app/`:
- `director_app.server`: WebSocket server and command routing
- `director_app.tentacle`: Tentacle BLE reader
- `director_app.gui`: Tkinter UI
"""

from director_app.gui import main


if __name__ == "__main__":
    main()
