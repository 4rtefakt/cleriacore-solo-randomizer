"""Run this mod's drive cases through CleriaCore's headless harness.

    python .dev/run.py [case ...]        # CLERIACORE=<checkout> if it is not ../YsOrigin-CleriaCore

Each case boots one room with the mod installed and turned on in a scratch settings folder, plays the
`drive` script (tick:command;...), and checks the engine's output: `expect` lines in order, `absent`
lines never. `settings` are lines for the mod's section of cleria.ini; `shots` ({name: tick of a `shot`
command}) copies captured frames to .dev/shots/<name>.png."""
import importlib.util, os, shutil, struct, subprocess, sys, tempfile, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(HERE)
CC = os.environ.get("CLERIACORE") or os.path.join(os.path.dirname(os.path.dirname(MOD)), "YsOrigin-CleriaCore")
EXE = os.path.join(CC, "build", "Release", "cleria-view.exe")
ASSETS = os.path.join(CC, "assets")
SKIP = ("script stopped", "Mod stopped")


def mod_id():
    for line in open(os.path.join(MOD, "mod.ini"), encoding="utf-8"):
        if line.strip().lower().startswith("id="):
            return line.split("=", 1)[1].strip().strip('"').lower()


def ppm_to_png(src, dst):
    with open(src, "rb") as f:
        assert f.readline().strip() == b"P6"
        w, h = map(int, f.readline().split())
        f.readline()
        rgb = f.read()
    raw = b"".join(b"\0" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(dst, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def run(name, case):
    mid = mod_id()
    with tempfile.TemporaryDirectory() as tmp:
        settings = os.path.join(tmp, "settings")
        dst = os.path.join(settings, "mods", mid)
        shutil.copytree(MOD, dst, ignore=shutil.ignore_patterns(".*", "*.cleriamod", "*.zip", "__pycache__"))
        with open(os.path.join(settings, "cleria.ini"), "w") as f:
            f.write('[cleria.mods]\nUseMods=1\nOrder="%s"\nActive="%s"\n\n[cleria.mod.%s]\n%s\n' % (mid, mid, mid, case.get("settings", "")))
        open(os.path.join(settings, "yso_win.ini"), "w").close()
        env = dict(os.environ, CLERIA_MUTE="1", CLERIA_CHAR=case.get("char", "1"), CLERIA_DRIVE=case["drive"],
                   CLERIA_SAVE_DIR=tmp, CLERIA_SHOT_DIR=tmp, CLERIA_INI=os.path.join(settings, "yso_win.ini"))
        env.update(case.get("env", {}))
        srv = case["server"]() if case.get("server") else None      # a mock server: returns (process, env additions)
        if srv:
            env.update(srv[1])
            with open(os.path.join(settings, "cleria.ini"), "a") as f:
                f.write(srv[2] + "\n")
        try:
            sob = os.path.join(ASSETS, "MAP", case["room"] + ".SOB")
            r = subprocess.run([EXE, ASSETS, sob], env=env, capture_output=True, text=True, errors="replace", timeout=900)
            out = r.stdout + r.stderr
            if "drive2" in case:                                  # a second boot on the same saves and settings
                r = subprocess.run([EXE, ASSETS, sob], env=dict(env, CLERIA_DRIVE=case["drive2"]), capture_output=True,
                                   text=True, errors="replace", timeout=900)
                out += "\n==== second boot\n" + r.stdout + r.stderr
        finally:
            if srv:
                srv[0].terminate()
                try:
                    out += "\n==== server\n" + srv[0].communicate(timeout=10)[0]
                except Exception:
                    pass
        for shot, tick in case.get("shots", {}).items():          # {name: the tick of its `shot` command}
            p = os.path.join(tmp, "t%d.ppm" % tick)
            if os.path.exists(p):
                os.makedirs(os.path.join(HERE, "shots"), exist_ok=True)
                ppm_to_png(p, os.path.join(HERE, "shots", shot + ".png"))
    if os.environ.get("SHOW"):
        print("\n".join(l for l in out.splitlines() if "[lua" in l or os.environ["SHOW"] in l))
    for e in list(case.get("absent", [])) + list(SKIP):
        if e in out:
            print(f"FAIL {name}: unexpected '{e}'")
            print("\n".join(l for l in out.splitlines() if "[lua" in l or "stopped" in l)[-1500:])
            return False
    at = 0
    for e in case["expect"]:
        k = out.find(e, at)
        if k < 0:
            print(f"FAIL {name}: missing '{e}'")
            print("\n".join(l for l in out.splitlines() if "[lua" in l)[-2500:])
            return False
        at = k + len(e)
    if case.get("check"):                                         # a case's own check of the whole output
        err = case["check"](out)
        if err:
            print(f"FAIL {name}: {err}")
            return False
    print(f"ok   {name}")
    return True


if __name__ == "__main__":
    spec = importlib.util.spec_from_file_location("cases", os.path.join(HERE, "cases.py"))
    cases = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cases)
    names = sys.argv[1:] or list(cases.CASES)
    bad = sum(not run(n, cases.CASES[n]) for n in names)
    print(f"{len(names) - bad}/{len(names)} passed")
    sys.exit(1 if bad else 0)
