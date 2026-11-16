#!/usr/bin/env python3
"""Write the whole app as one readable text file that rebuilds the package.

    python scripts/make_text_bundle.py      # -> release/<app>-<version>.txt

The output is plain text: a short Python program followed by every source
file, line by line, as comments ("#|" + original line). Nothing is encoded.
Running it ("python <file>.txt") recreates splunk_app/<app>/ and the .spl.
The only binary files, the app icons, are drawn by code instead of embedded.
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import package  # noqa: E402  (scripts/package.py)

APP = package.APP
SRC = package.SRC
ROOT = package.ROOT

# Program placed at the top of the bundle. Kept self-contained (stdlib only).
PROGRAM = r'''#!/usr/bin/env python3
# ===========================================================================
# __APP__ __VERSION__ - Splunk app source as a single readable text file
#
# Everything below the "SOURCE FILES" line is the app's source code, one
# file at a time, each line prefixed with "#|". Read it like any text file.
#
# To rebuild the app and the installable package (needs Python 3 only):
#     python __APP__-__VERSION__.txt                 (Windows: py ...)
#     python __APP__-__VERSION__.txt --out-dir DIR
# This writes DIR/__APP__/ (the app folder) and DIR/__APP__-__VERSION__.spl.
# ===========================================================================
import argparse, gzip, io, os, struct, sys, tarfile, zlib

APP = "__APP__"
VERSION = "__VERSION__"


def icon(n):
    """The app icon: orange square with a dark border (PNG, RGBA)."""
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    rows = b""
    for y in range(n):
        rows += b"\x00"
        for x in range(n):
            border = x < n // 8 or y < n // 8 or x >= n - n // 8 or y >= n - n // 8
            rows += bytes((0x3C, 0x44, 0x4D, 255) if border else (0xF5, 0x8F, 0x1F, 255))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


ICONS = {"static/appIcon.png": 36, "static/appIcon_2x.png": 72,
         "static/appIconAlt.png": 36, "static/appIconAlt_2x.png": 72}


def read_files(path):
    files, cur, lines = {}, None, []
    with open(path, encoding="utf-8") as fh:
        text = fh.read().split("\n#@@ SOURCE FILES @@\n", 1)[1]
    for line in text.split("\n"):
        if line.startswith("#=== FILE "):
            cur, lines = line[len("#=== FILE "):], []
        elif line.startswith("#=== END ") and cur:
            eol = line.endswith("newline=1")
            files[cur] = ("\n".join(lines) + ("\n" if eol else "")).encode("utf-8")
            cur = None
        elif cur is not None:
            if not line.startswith("#|"):
                sys.exit("Corrupt bundle near file " + cur)
            lines.append(line[2:])
    return files


def tar_add(tar, arcname, data=None):
    info = tarfile.TarInfo(arcname)
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    if data is None:
        info.type, info.mode = tarfile.DIRTYPE, 0o755
        tar.addfile(info)
    else:
        info.mode, info.size = 0o644, len(data)
        tar.addfile(info, io.BytesIO(data))


def main():
    ap = argparse.ArgumentParser(description="Rebuild the Splunk app from this text file.")
    ap.add_argument("--out-dir", default=".")
    args = ap.parse_args()
    files = read_files(os.path.abspath(__file__))
    for name, n in ICONS.items():
        files[name] = icon(n)
    out = os.path.abspath(args.out_dir)
    app_dir = os.path.join(out, APP)
    if os.path.exists(app_dir):
        sys.exit("Refusing to overwrite existing folder: " + app_dir)
    for rel, data in files.items():
        p = os.path.join(app_dir, *rel.split("/"))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as fh:
            fh.write(data)
    dirs = sorted({"/".join(r.split("/")[:i]) for r in files for i in range(1, r.count("/") + 1)})
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
        tar_add(tar, APP)
        for d in dirs:
            tar_add(tar, APP + "/" + d)
        for rel in sorted(files):
            tar_add(tar, APP + "/" + rel, files[rel])
    spl = os.path.join(out, "%s-%s.spl" % (APP, VERSION))
    with open(spl, "wb") as fh:
        fh.write(gzip.compress(buf.getvalue()))
    print("App folder: " + app_dir)
    print("Package:    " + spl)


if __name__ == "__main__":
    main()
'''


def main():
    version = package.app_version()
    files = []
    for dirpath, dirnames, filenames in os.walk(SRC):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, SRC)
        parts = [] if rel_dir == "." else rel_dir.split(os.sep)
        dirnames[:] = [d for d in dirnames if not package.excluded(parts + [d])]
        for f in sorted(filenames):
            if not package.excluded(parts + [f]):
                files.append("/".join(parts + [f]))

    # Icons are regenerated by the bundle; make sure that gives the same bytes.
    ns = {"__name__": "bundle"}
    exec(compile(PROGRAM, "bundle", "exec"), ns)
    out = [PROGRAM.replace("__APP__", APP).replace("__VERSION__", version).rstrip("\n"), "", "#@@ SOURCE FILES @@"]
    for rel in files:
        path = os.path.join(SRC, *rel.split("/"))
        with open(path, "rb") as fh:
            data = fh.read()
        if rel in ns["ICONS"]:
            if data != ns["icon"](ns["ICONS"][rel]):
                sys.exit("Icon %s differs from the generated icon; update icon() in the bundle." % rel)
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            sys.exit("Binary file can't go in a text bundle: " + rel)
        if "\r" in text:
            sys.exit("CR line endings not supported: " + rel)
        eol = text.endswith("\n")
        body = text[:-1] if eol else text
        out.append("#=== FILE " + rel)
        out.extend("#|" + line for line in body.split("\n"))
        out.append("#=== END %s newline=%d" % (rel, 1 if eol else 0))

    os.makedirs(os.path.join(ROOT, "release"), exist_ok=True)
    dest = os.path.join(ROOT, "release", "%s-%s.txt" % (APP, version))
    with open(dest, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(out) + "\n")
    print(dest)


if __name__ == "__main__":
    main()
