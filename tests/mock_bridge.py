#!/usr/bin/env python3
"""A stand-in Hue bridge with a demo home, for headless renders and screenshots.

    python3 tests/mock_bridge.py PORT_FILE

Serves the v1 API subset the plugin uses (GET groups, lights and scenes; PUT group actions and
light state) on 127.0.0.1 with any application key, and writes the port it bound to PORT_FILE.
No real bridge or light is contacted.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def light(name, on, bri, reachable=True):
    return {"name": name, "type": "Extended color light",
            "state": {"on": on, "bri": bri, "reachable": reachable}}


LIGHTS = {
    "1": light("Sofa lamp", True, 178),
    "2": light("Floor lamp", True, 178),
    "3": light("TV strip", True, 127),
    "4": light("Pendant 1", True, 254),
    "5": light("Pendant 2", True, 254),
    "6": light("Under-cabinet", False, 254),
    "7": light("Bedside left", False, 80),
    "8": light("Bedside right", False, 80),
    "9": light("Desk lamp", True, 230),
    "10": light("Shelf light", True, 40, reachable=False),
    "11": light("Porch", True, 200),
}
GROUPS = {
    "1": {"name": "Living room", "type": "Room", "lights": ["1", "2", "3"]},
    "2": {"name": "Kitchen", "type": "Room", "lights": ["4", "5", "6"]},
    "3": {"name": "Bedroom", "type": "Room", "lights": ["7", "8"]},
    "4": {"name": "Office", "type": "Room", "lights": ["9", "10"]},
    "5": {"name": "Porch", "type": "Room", "lights": ["11"]},
    "6": {"name": "Downstairs", "type": "Zone", "lights": ["1", "2", "3", "4", "5", "6"]},
    "7": {"name": "Reading nook", "type": "Zone", "lights": ["1", "9"]},
    "8": {"name": "Movie night", "type": "Entertainment", "lights": ["3"]},
}
SCENES = {
    f"s{i}": {"name": name, "type": "GroupScene", "group": group, "recycle": False}
    for i, (group, name) in enumerate([
        ("1", "Relax"), ("1", "Read"), ("1", "Concentrate"), ("1", "Energize"),
        ("1", "Dimmed"), ("1", "Nightlight"), ("1", "Sunset"),
        ("2", "Bright"), ("2", "Cooking"), ("3", "Nightlight"), ("4", "Concentrate"),
    ])
}


def set_lights(ids, body):
    for lid in ids:
        state = LIGHTS[lid]["state"]
        if not state["reachable"]:
            continue
        if "on" in body:
            state["on"] = bool(body["on"])
        if "bri_inc" in body:
            state["on"] = True
            state["bri"] = max(1, min(254, state["bri"] + int(body["bri_inc"])))


class Bridge(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, data, status=200):
        raw = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def parts(self):
        # /api/<key>/<resource>[/<id>[/<sub>]]
        return self.path.strip("/").split("/")[2:]

    def do_GET(self):
        parts = self.parts()
        table = {"lights": LIGHTS, "groups": GROUPS, "scenes": SCENES}.get(parts[0] if parts else "")
        if table is None:
            return self.reply([{"error": {"type": 3, "description": "resource not available"}}])
        self.reply(table)

    def do_PUT(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        parts = self.parts()
        if len(parts) == 3 and parts[0] == "groups" and parts[2] == "action":
            if "scene" in body:
                set_lights(GROUPS.get(parts[1], {}).get("lights", []), {"on": True})
            else:
                ids = list(LIGHTS) if parts[1] == "0" else GROUPS.get(parts[1], {}).get("lights", [])
                set_lights(ids, body)
        elif len(parts) == 3 and parts[0] == "lights" and parts[2] == "state" and parts[1] in LIGHTS:
            set_lights([parts[1]], body)
        else:
            return self.reply([{"error": {"type": 3, "description": "resource not available"}}])
        self.reply([{"success": {f"/{'/'.join(parts)}/{k}": v}} for k, v in body.items()])


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Bridge)
    with open(sys.argv[1], "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
