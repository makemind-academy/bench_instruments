#!/usr/bin/env python3
"""bench-instruments: three SCPI instruments on one screen, the supply asked for a voltage, the bench limit clamping it."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from appplayer import AppPlayer  # noqa: E402
from mcpclient import Server  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "bench_server")
CAP = os.path.join(HERE, "captures")
SERVER_ID = "com.makemind.sample.bench"

with Server(["dart", "run", "bin/server.dart"], cwd=SERVER) as s:
    s.call("psu.output", {"on": True})
    s.call("psu.set", {"volts": 9})
    nine = s.call("bench.read")
    assert abs(float(nine["volts"]) - 9) < 0.5, nine
    s.call("psu.set", {"volts": 30})
    thirty = s.call("bench.read")
    assert float(thirty["volts"]) < 12.0, "the bench limit must clamp the supply"
    assert thirty["over"], thirty
    idn = s.call("bench.identify")["idn"]
    assert len(idn) == 3, idn

ap = AppPlayer()
ap.register_server(SERVER_ID, "Bench", cwd=SERVER)
ap.restart()
ap.open_server(SERVER_ID)
ap.wait_text("VOLTS")
ap.shot(f"{CAP}/01_bench.png")
ap.tap("Output on")
ap.wait_text("output on")
ap.tap("Set 9 V")
ap.wait_text("asked the supply for 9")
ap.shot(f"{CAP}/02_at_nine.png")
ap.tap("Set 30 V")
ap.wait_text("over the bench limit")
ap.shot(f"{CAP}/03_clamped.png")
print("bench-instruments: three instruments read, 9 V taken, 30 V clamped by the bench")
