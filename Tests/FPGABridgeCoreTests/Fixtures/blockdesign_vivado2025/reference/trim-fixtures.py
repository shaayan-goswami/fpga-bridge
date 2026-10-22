import json, os, sys, shutil, glob
src, dst = sys.argv[1], sys.argv[2]
shutil.rmtree(dst, ignore_errors=True)
for bd in ("mb_system", "wired"):
    os.makedirs(f"{dst}/{bd}", exist_ok=True)
    shutil.copy(f"{src}/bd/{bd}/{bd}.bd", f"{dst}/{bd}/{bd}.bd")
    for x in sorted(glob.glob(f"{src}/bd/{bd}/ip/*/*.xci")):
        d = json.load(open(x))
        ip = d["ip_inst"]
        params = ip.get("parameters", {}).get("component_parameters", {})
        keep = {k: [{kk: vv for kk, vv in e.items() if kk in ("value", "value_src")} for e in v] for k, v in params.items()}
        if len(keep) > 200:
            keep = {k: v for k, v in keep.items() if any(e.get("value_src") not in (None, "default") for e in v)}
        b = ip.get("boundary", {})
        nb = {}
        if "ports" in b: nb["ports"] = b["ports"]
        if "interfaces" in b:
            nb["interfaces"] = {k: {kk: vv for kk, vv in v.items() if kk != "parameters"} for k, v in b["interfaces"].items()}
        if "memory_maps" in b:
            mm = {}
            for k, v in b["memory_maps"].items():
                blocks = {bk: {kk: vv for kk, vv in bv.items() if kk != "registers"} for bk, bv in v.get("address_blocks", {}).items()}
                mm[k] = {kk: vv for kk, vv in v.items() if kk != "address_blocks"} | {"address_blocks": blocks}
            nb["memory_maps"] = mm
        out = {"schema": d["schema"], "ip_inst": {k: ip[k] for k in ("xci_name", "cell_name", "component_reference", "ip_revision") if k in ip}
               | {"parameters": {"component_parameters": keep}, "boundary": nb}}
        rel = os.path.relpath(x, f"{src}/bd/{bd}")
        os.makedirs(os.path.dirname(f"{dst}/{bd}/{rel}"), exist_ok=True)
        json.dump(out, open(f"{dst}/{bd}/{rel}", "w"), indent=2)
os.makedirs(f"{dst}/reference", exist_ok=True)
for f in ("mb_system.tcl", "wired.tcl", "mb_system_wrapper.v"):
    shutil.copy(f"{src}/{f}", f"{dst}/reference/{f}")
