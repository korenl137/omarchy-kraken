#!/usr/bin/env python3
"""Kraken cooler profiles and device control (core + CLI). See README.md."""
import argparse
import glob
import json
import os
import subprocess
import sys
import tomllib

CONFIG_DIR = os.path.expanduser("~/.config/kraken")
PROFILE_DIR = os.path.join(CONFIG_DIR, "profiles")
ACTIVE_FILE = os.path.join(CONFIG_DIR, "profile")  # name of the profile restored at login
SETTINGS_FILE = os.path.join(CONFIG_DIR, "config.toml")

# Device limits (liquidctl kraken3 driver): curve covers liquid 20-59 C, pump duty 20-100.
TEMP_MIN, TEMP_MAX = 20, 59
PUMP_MIN, PUMP_MAX = 20, 100
MAX_POINTS = 10

# Read-only defaults. Warning thresholds are arbitrary defaults, not vendor limits.
BUILTIN = {
    "quiet": {"pump": 80, "fan": [[30, 25], [36, 35], [42, 55], [48, 80], [54, 100]]},
    "balanced": {"pump": 80, "fan": [[28, 40], [34, 55], [40, 75], [45, 100]]},
    "performance": {"pump": 80, "fan": [[28, 60], [34, 80], [38, 100]]},
    "max": {"pump": 100, "fan": [[20, 100], [59, 100]]},
}
DEFAULT_WARN = {"fan_at_temp": 45, "fan_min": 70, "pump_min": 40}


def validate(pump, fan):
    """Return error strings; an empty list means the device accepts it."""
    errs = []
    if not isinstance(pump, int) or not PUMP_MIN <= pump <= PUMP_MAX:
        errs.append(f"pump must be an integer {PUMP_MIN}-{PUMP_MAX}")
    if not 1 <= len(fan) <= MAX_POINTS:
        errs.append(f"fan curve needs 1-{MAX_POINTS} points")
    temps = [p[0] for p in fan]
    if temps != sorted(set(temps)):
        errs.append("fan temperatures must be strictly increasing")
    for t, d in fan:
        if not (TEMP_MIN <= t <= TEMP_MAX):
            errs.append(f"temperature {t} outside {TEMP_MIN}-{TEMP_MAX}")
        if not (0 <= d <= 100):
            errs.append(f"duty {d} outside 0-100")
    return errs


def interp(fan, temp):
    """Fan duty the device should pick at a liquid temperature (clamped at both ends)."""
    if temp <= fan[0][0]:
        return fan[0][1]
    for (t0, d0), (t1, d1) in zip(fan, fan[1:]):
        if temp <= t1:
            return d0 + (d1 - d0) * (temp - t0) / (t1 - t0)
    return fan[-1][1]


def load_settings():
    warn = dict(DEFAULT_WARN)
    try:
        with open(SETTINGS_FILE, "rb") as f:
            warn.update(tomllib.load(f).get("warn", {}))
    except FileNotFoundError:
        pass
    return warn


def warnings(pump, fan, warn=None):
    warn = warn or load_settings()
    out = []
    d = interp(fan, warn["fan_at_temp"])
    if d < warn["fan_min"]:
        out.append(f"fan is {d:.0f}% at liquid {warn['fan_at_temp']} C (below {warn['fan_min']}%)")
    if pump < warn["pump_min"]:
        out.append(f"pump {pump}% is below {warn['pump_min']}%")
    return out


def _path(name):
    if not name or any(c in name for c in "/\\.") or name.startswith("-"):
        raise ValueError(f"invalid profile name: {name!r}")
    return os.path.join(PROFILE_DIR, f"{name}.toml")


def load_profile(name):
    if os.path.exists(_path(name)):
        with open(_path(name), "rb") as f:
            d = tomllib.load(f)
        return {"name": name, "pump": d["pump"], "fan": [list(p) for p in d["fan"]], "builtin": False}
    if name in BUILTIN:
        return {"name": name, **BUILTIN[name], "builtin": True}
    raise KeyError(f"no such profile: {name}")


def list_profiles():
    names = list(BUILTIN)
    for p in sorted(glob.glob(os.path.join(PROFILE_DIR, "*.toml"))):
        n = os.path.basename(p)[:-5]
        if n not in names:
            names.append(n)
    return names


def save_profile(name, pump, fan):
    if name in BUILTIN:
        raise ValueError(f"{name!r} is a built-in profile; save under another name")
    errs = validate(pump, fan)
    if errs:
        raise ValueError("; ".join(errs))
    os.makedirs(PROFILE_DIR, exist_ok=True)
    body = f"pump = {pump}\nfan = [" + ", ".join(f"[{t}, {d}]" for t, d in fan) + "]\n"
    tmp = _path(name) + ".tmp"
    with open(tmp, "w") as f:
        f.write(body)
    os.replace(tmp, _path(name))


def delete_profile(name):
    if name in BUILTIN and not os.path.exists(_path(name)):
        raise ValueError(f"{name!r} is built-in and cannot be deleted")
    os.remove(_path(name))


def active_name():
    try:
        return open(ACTIVE_FILE).read().strip() or "balanced"
    except FileNotFoundError:
        return "balanced"


def set_active(name):
    load_profile(name)
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(ACTIVE_FILE, "w") as f:
        f.write(name + "\n")


def _liquidctl(*args):
    return subprocess.run(["liquidctl", "--match", "Kraken", *args],
                          check=True, capture_output=True, text=True).stdout


def apply_to_device(pump, fan):
    errs = validate(pump, fan)
    if errs:
        raise ValueError("; ".join(errs))
    _liquidctl("set", "pump", "speed", str(pump))
    _liquidctl("set", "fan", "speed", *[str(v) for p in fan for v in p])


def cpu_temp():
    for lab in glob.glob("/sys/class/hwmon/hwmon*/temp*_label"):
        if open(lab).read().strip().startswith("Package id"):
            return int(open(lab.replace("_label", "_input")).read()) / 1000
    return None


def device_status():
    rows = json.loads(_liquidctl("--json", "status"))[0]["status"]
    v = {r["key"]: r["value"] for r in rows}
    return {"liquid": v["Liquid temperature"], "pump_rpm": v["Pump speed"], "pump_duty": v["Pump duty"],
            "fan_rpm": v["Fan speed"], "fan_duty": v["Fan duty"], "cpu": cpu_temp()}


def _parse_fan(s):
    v = [int(x) for x in s.split()]
    if len(v) % 2:
        raise ValueError("fan curve needs temperature/duty pairs")
    return [[v[i], v[i + 1]] for i in range(0, len(v), 2)]


def main(argv=None):
    ap = argparse.ArgumentParser(prog="kraken-profile")
    sub = ap.add_subparsers(dest="cmd")
    for c in ("list", "status", "apply"):
        p = sub.add_parser(c)
        if c != "apply":
            p.add_argument("--json", action="store_true")
    for c in ("show", "use", "delete"):
        sub.add_parser(c).add_argument("name")
    for c in ("try", "check", "save"):
        p = sub.add_parser(c)
        if c == "save":
            p.add_argument("name")
        p.add_argument("--pump", type=int, required=True)
        p.add_argument("--fan", required=True, help='"temp duty temp duty ..."')
        if c == "save":
            p.add_argument("--activate", action="store_true")
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] in BUILTIN | {n: 0 for n in list_profiles()}:  # legacy: kraken-profile balanced
        argv.insert(0, "use")
    a = ap.parse_args(argv)
    try:
        if a.cmd in (None, "list"):
            act = active_name()
            for n in list_profiles():
                print(("* " if n == act else "  ") + n) if not getattr(a, "json", False) else None
            if getattr(a, "json", False):
                print(json.dumps({"active": act, "profiles": [load_profile(n) for n in list_profiles()]}))
        elif a.cmd == "status":
            print(json.dumps(device_status()) if a.json else _liquidctl("status"), end="\n" if a.json else "")
        elif a.cmd == "show":
            print(json.dumps(load_profile(a.name)))
        elif a.cmd == "use":
            p = load_profile(a.name)
            apply_to_device(p["pump"], p["fan"])
            set_active(a.name)
        elif a.cmd == "apply":
            p = load_profile(active_name())
            apply_to_device(p["pump"], p["fan"])
        elif a.cmd == "try":
            apply_to_device(a.pump, _parse_fan(a.fan))
        elif a.cmd == "check":
            fan = _parse_fan(a.fan)
            print(json.dumps({"errors": validate(a.pump, fan), "warnings": warnings(a.pump, fan)}))
        elif a.cmd == "save":
            save_profile(a.name, a.pump, _parse_fan(a.fan))
            if a.activate:
                set_active(a.name)
        elif a.cmd == "delete":
            delete_profile(a.name)
            if active_name() == a.name:
                set_active("balanced")
    except (ValueError, KeyError, subprocess.CalledProcessError, FileNotFoundError) as e:
        msg = e.stderr.strip() if isinstance(e, subprocess.CalledProcessError) and e.stderr else str(e)
        print(f"error: {msg}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
