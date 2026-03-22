#!/usr/bin/env python3
"""
mindlink.py — MindLink data pipeline
Reads Grove GSR sensor, streams JSON frames over WebSocket

Usage:
    python3 mindlink.py [host:port]
    python3 mindlink.py 0.0.0.0:5000     # default
"""

import sys
import json
import time
import asyncio
import websockets
from aiohttp import web

# ── device ID ──────────────────────────────────────────────────────────────
def read_device_id() -> str:
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("Serial"):
                    return line.split(":")[1].strip()
    except Exception:
        pass
    return "unknown"

DEVICE_ID = read_device_id()

# ── config ─────────────────────────────────────────────────────────────────
SAMPLE_RATE_HZ = 20
SAMPLE_S       = 1.0 / SAMPLE_RATE_HZ

EMA_FAST       = 0.15    # smoothing
EMA_SLOW       = 0.005   # baseline tracker  τ ≈ 10 s
WARMUP_SAMPLES = 100     # ~5 s before TA accumulator starts

GSR_RREF       = 100_000.0  # Grove GSR v1.2 reference resistor (100 kΩ)
GSR_VSUPPLY    = 3.3
ADC_MAX        = 1023.0
ADC_CLAMP_LO   = 1
ADC_CLAMP_HI   = 1022
# ───────────────────────────────────────────────────────────────────────────


def adc_to_us(raw: int) -> float:
    raw = max(ADC_CLAMP_LO, min(ADC_CLAMP_HI, raw))
    v   = (raw / ADC_MAX) * GSR_VSUPPLY
    r   = GSR_RREF * ((GSR_VSUPPLY / v) - 1.0)
    return round((1.0 / r) * 1e6, 3)


def read_raw() -> int:
    from grove.adc import ADC
    return ADC().read(0)


def next_frame(state: dict) -> dict:
    raw = read_raw()

    state["smoothed"] = EMA_FAST * raw               + (1 - EMA_FAST) * state["smoothed"]
    state["baseline"] = EMA_SLOW * state["smoothed"] + (1 - EMA_SLOW) * state["baseline"]

    prev_delta        = state["delta"]
    state["delta"]    = state["smoothed"] - state["baseline"]
    velocity          = state["delta"] - prev_delta
    state["count"]   += 1

    warmed = state["count"] > WARMUP_SAMPLES
    if warmed and state["baseline"] > state["smoothed"]:
        state["ta"] += (state["baseline"] - state["smoothed"]) * 0.001

    return {
        "device":    DEVICE_ID,
        "t":         int((time.monotonic() - state["t0"]) * 1000),
        "raw":       raw,
        "raw_uS":    adc_to_us(raw),
        "smoothed":  int(state["smoothed"]),
        "smooth_uS": adc_to_us(int(state["smoothed"])),
        "baseline":  int(state["baseline"]),
        "delta":     int(state["delta"]),
        "velocity":  int(velocity),
        "ta":        round(state["ta"], 4),
        "warmed":    warmed,
    }


# ── shared state (latest frame, set by WebSocket loop) ─────────────────────
_latest_frame: dict = {}


async def stream(websocket):
    print(f"[MindLink] client connected: {websocket.remote_address}")

    seed              = read_raw()
    state             = {
        "smoothed": float(seed),
        "baseline": float(seed),
        "delta":    0.0,
        "ta":       0.0,
        "count":    0,
        "t0":       time.monotonic(),
    }

    try:
        while True:
            tick  = time.monotonic()
            frame = next_frame(state)
            _latest_frame.update(frame)        # keep HTTP /frame current
            await websocket.send(json.dumps(frame))
            elapsed = time.monotonic() - tick
            await asyncio.sleep(max(0, SAMPLE_S - elapsed))
    except websockets.ConnectionClosed:
        print(f"[MindLink] client disconnected")


# ── HTTP handlers ───────────────────────────────────────────────────────────
async def handle_info(request):
    return web.json_response({
        "device":          DEVICE_ID,
        "sample_rate_hz":  SAMPLE_RATE_HZ,
        "ema_fast":        EMA_FAST,
        "ema_slow":        EMA_SLOW,
        "warmup_samples":  WARMUP_SAMPLES,
    })


async def handle_frame(request):
    if not _latest_frame:
        return web.json_response({"error": "no data yet — sensor warming up"}, status=503)
    return web.json_response(_latest_frame)


async def main(host: str, ws_port: int):
    print(f"[MindLink] device    : {DEVICE_ID}")
    print(f"[MindLink] websocket : ws://{host}:{ws_port}")
    print(f"[MindLink] http      : http://{host}:{ws_port + 1}/info  /frame")

    # ── HTTP server on ws_port+1 ────────────────────────────────────────────
    app = web.Application()
    app.router.add_get("/info",  handle_info)
    app.router.add_get("/frame", handle_frame)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, host, ws_port + 1).start()

    # ── WebSocket server ────────────────────────────────────────────────────
    async with websockets.serve(stream, host, ws_port):
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    addr = sys.argv[1] if len(sys.argv) > 1 else "192.168.4.1:5000"
    host, port = addr.rsplit(":", 1)
    asyncio.run(main(host, int(port)))
