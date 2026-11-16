#!/usr/bin/env python3
"""Build the installable Splunk app package from source.

Works on Windows, macOS and Linux with only the Python standard library.

    python scripts/package.py                 # -> dist/<app>-<version>.spl and .tgz
    python scripts/package.py --out-dir C:\\temp

The package is a gzipped tar of splunk_app/<app>/, with AppInspect-friendly
settings: owner root (0/0), dirs 755, files 644, no hidden files, no local/
directory, no local.meta and no compiled Python.
"""
import argparse
import configparser
import gzip
import io
import os
import sys
import tarfile

APP = "licoryx_spl_owner_manager"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "splunk_app", APP)


def app_version():
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.read(os.path.join(SRC, "default", "app.conf"), encoding="utf-8")
    return cp.get("launcher", "version", fallback=None) or cp.get("id", "version")


def excluded(rel_parts):
    if any(p.startswith(".") for p in rel_parts):
        return True
    if rel_parts and rel_parts[0] == "local":
        return True
    if rel_parts[-2:] == ["metadata", "local.meta"]:
        return True
    if rel_parts[-1].endswith((".pyc", ".pyo")) or "__pycache__" in rel_parts:
        return True
    return False


def add(tar, path, arcname, is_dir):
    info = tarfile.TarInfo(arcname)
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mtime = int(os.path.getmtime(path))
    if is_dir:
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        tar.addfile(info)
    else:
        info.mode = 0o644
        with open(path, "rb") as fh:
            data = fh.read()
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))


def build():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
        add(tar, SRC, APP, True)
        for dirpath, dirnames, filenames in os.walk(SRC):
            dirnames.sort()
            rel_dir = os.path.relpath(dirpath, SRC)
            dir_parts = [] if rel_dir == "." else rel_dir.split(os.sep)
            # Prune excluded directories so os.walk skips them.
            dirnames[:] = [d for d in dirnames if not excluded(dir_parts + [d])]
            for d in dirnames:
                add(tar, os.path.join(dirpath, d), "/".join([APP] + dir_parts + [d]), True)
            for f in sorted(filenames):
                if excluded(dir_parts + [f]):
                    continue
                add(tar, os.path.join(dirpath, f), "/".join([APP] + dir_parts + [f]), False)
    return gzip.compress(buf.getvalue())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-dir", default=os.path.join(ROOT, "dist"))
    args = ap.parse_args()
    if not os.path.isfile(os.path.join(SRC, "default", "app.conf")):
        sys.exit("App source not found at " + SRC)
    data = build()
    os.makedirs(args.out_dir, exist_ok=True)
    base = os.path.join(args.out_dir, "%s-%s" % (APP, app_version()))
    for ext in (".spl", ".tgz"):
        with open(base + ext, "wb") as fh:
            fh.write(data)
    print(base + ".spl")


if __name__ == "__main__":
    main()
