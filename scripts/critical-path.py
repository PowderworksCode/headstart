#!/usr/bin/env python3
"""Reads event logs from scripts/log-rustc (HEADSTART_LOG) and reports where
the build's time goes along its critical path, plus two headstart-specific
waits:

- linking crates (binaries, proc macros): how long after their dependencies'
  early metadata they started (cargo holds them until every rlib exists);
- pauses: time dependents spent waiting for full metadata.

    scripts/critical-path.py <log>...
"""
import sys
from collections import defaultdict

LINKING = {"bin", "proc-macro", "cdylib", "dylib", "staticlib"}

def load(path):
    units = {}
    for line in open(path):
        f = line.split()
        key, kind, t = f[0], f[1], float(f[2])
        name = key.rsplit(":", 1)[0]
        if name == "___":
            continue
        if kind == "start":
            units[key] = {"name": name, "_key": key, "start": t, "type": f[3],
                          "deps": [] if f[4] == "-" else f[4].split(","),
                          "events": defaultdict(list)}
        elif key in units:
            units[key]["events"][kind].append(t)
            if len(f) > 3:
                units[key].setdefault("files", []).append((kind, t, f[3]))
    return units

def first(u, kind):
    return u["events"][kind][0] if u["events"][kind] else None

def report(path):
    units = {k: u for k, u in load(path).items()}
    units = {k: u for k, u in units.items() if u["events"]["end"]}
    by_name = {}
    for key, u in units.items():
        by_name.setdefault(u["name"], key)  # first run of that name
        u["end"] = first(u, "end")
        u["early"] = first(u, "early-metadata")
        u["full"] = first(u, "metadata")
        waits, resumes = u["events"]["wait-metadata"], u["events"]["resume"]
        u["paused"] = sum(r - w for w, r in zip(waits, resumes))
    t0 = min(u["start"] for u in units.values())
    end = max(u["end"] for u in units.values() if u["end"])
    def dep_units(u):
        return [units[by_name[d]] for d in u["deps"] if d in by_name]
    def ancestors(u, seen=None):
        seen = set() if seen is None else seen
        for d in dep_units(u):
            if d["_key"] not in seen:
                seen.add(d["_key"]); ancestors(d, seen)
        return [units[k] for k in seen]
    def early_ready(d):
        # When a dependent could start on d: its early (or full) metadata;
        # proc macros only once built.
        if d["type"] == "proc-macro":
            return d["end"]
        return d["early"] or d["full"] or d["end"]
    print(f"== {path}: {end - t0:.2f} s, {len(units)} rustc runs, "
          f"{sum(u['paused'] for u in units.values()):.1f} s paused in total")
    # Linking crates held back after their dependencies' early metadata.
    held = []
    for u in units.values():
        if u["type"] in LINKING and u["deps"]:
            anc = ancestors(u)
            could = max([early_ready(d) for d in anc] + [t0])
            held.append((u["start"] - could, u["end"] - u["start"], u["name"], u["type"],
                         could - t0, u["start"] - t0))
    held.sort(reverse=True)
    print("  linking crates, held after dependencies' early metadata "
          "(held, own run time, crate):")
    for h, run, name, typ, could, start in held[:6]:
        print(f"    {h:6.2f} s held, runs {run:5.2f} s  {name} ({typ}); could start "
              f"{could:.2f}, started {start:.2f}")
    # Critical path, walked back from the last crate to finish.
    u = max((u for u in units.values() if u["end"]), key=lambda u: u["end"])
    path_ = []
    while u:
        path_.append(u)
        deps = ancestors(u) if u["type"] in LINKING else dep_units(u)
        if not deps:
            break
        if u["type"] in LINKING:
            u = max(deps, key=lambda d: d["end"])
        else:
            u = max(deps, key=early_ready)
    # Pauses: waiting for the awaited full metadata vs. for a job slot after it.
    written = {}
    for u in units.values():
        for kind, t, f in u.get("files", []):
            if kind == "metadata":
                written[f] = t
    waiting = starved = 0.0
    for u in units.values():
        files = u.get("files", [])
        for i, (kind, t, f) in enumerate(files):
            if kind != "wait-metadata":
                continue
            resume = next((t2 for k2, t2, _ in files[i + 1:] if k2 == "resume"), None)
            if resume is None:
                continue
            ready = written.get(f, resume)
            waiting += max(0.0, min(ready, resume) - t)
            starved += max(0.0, resume - max(ready, t))
    print(f"  paused: {waiting:.1f} s waiting for full metadata, "
          f"{starved:.1f} s waiting for a job slot after it was written")
    print("  critical path (start, end, paused, crate):")
    for u in reversed(path_):
        print(f"    {u['start'] - t0:6.2f} {u['end'] - t0:6.2f} {u['paused']:5.2f}  "
              f"{u['name']} ({u['type']})")

for p in sys.argv[1:]:
    report(p)
