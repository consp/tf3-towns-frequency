#!/usr/bin/env bash
# Patch the town-density scale list in difficulty_util.tl inside the game's base.zip,
# WITHOUT changing the archive's size, offsets or checksums.
#
#   patch_town_frequency.sh find  <game-dir>            list zips containing difficulty_util.tl
#   patch_town_frequency.sh show  <zip>                 print the current values
#   patch_town_frequency.sh apply <zip> v1 v2 v3 ...    replace the values
#   patch_town_frequency.sh restore <zip>               put the original zip back
#
# Example: patch_town_frequency.sh apply base.zip 0.05 0.1 0.2 0.4 0.65
#
# Why so careful: the game's archives are non-standard (first header is "UG", not "PK")
# and the game keeps a content cache of file positions. A patch that changes the file
# size shifts every later entry and the game aborts with "Did not find local header
# signature". So this script keeps the entry exactly the same length (padding with
# spaces, trimming a comment if the values are longer) and, by default, adjusts four
# characters of a comment so the entry's CRC-32 stays identical to the original.
# Set KEEP_CRC=0 to update the CRC fields instead. Set FORCE=1 to allow a different
# number of values than the slider has positions.
# A backup "<zip>.orig" is made the first time you apply. Needs: bash, python3.
set -euo pipefail

TARGET="difficulty_util.tl"

die()  { echo "error: $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || die "'python3' is required but not installed"

PYZ=$(cat <<'PYEOF'
import itertools, os, re, shutil, struct, sys, tempfile, zlib

TARGET = "difficulty_util.tl"
LIST_RE = re.compile(rb"(local\s+level2TownFrequencyFactor\s*=\s*)\{([^}]*)\}")
COMMENT_RE = re.compile(rb"(?m)^([ \t]*--)([^\r\n]*)")
NUM_RE = re.compile(rb"[0-9]*\.?[0-9]+")

def parse(buf):
    e = buf.rfind(b"PK\x05\x06")
    if e < 0:
        raise SystemExit("no end-of-central-directory record found")
    _s, _d, _cd, _nd, n, cdsize, cdoff, _cl = struct.unpack("<4sHHHHIIH", buf[e:e + 22])
    if cdoff == 0xFFFFFFFF or n == 0xFFFF:
        raise SystemExit("zip64 archives are not supported")
    entries, p = [], cdoff
    for idx in range(n):
        if buf[p:p + 4] != b"PK\x01\x02":
            raise SystemExit("corrupt central directory")
        (_s, _vm, _vn, flags, method, _mt, _md, crc, csize, usize, fnl, exl, cml,
         _ds, _ia, _ea, loff) = struct.unpack("<4sHHHHHHIIIHHHHHII", buf[p:p + 46])
        name = buf[p + 46:p + 46 + fnl].decode("utf-8", "surrogateescape")
        entries.append(dict(idx=idx, start=p, name=name, flags=flags, method=method,
                            crc=crc, csize=csize, usize=usize, loff=loff))
        p += 46 + fnl + exl + cml
    return entries

def data_start(buf, e):
    lo = e["loff"]
    fnl, exl = struct.unpack("<HH", buf[lo + 26:lo + 30])
    return lo + 30 + fnl + exl

def read_entry(buf, e):
    ds = data_start(buf, e)
    raw = buf[ds:ds + e["csize"]]
    if e["method"] == 0:
        data = raw
    elif e["method"] == 8:
        data = zlib.decompress(raw, -15)
    else:
        raise SystemExit("unsupported compression method %d" % e["method"])
    if zlib.crc32(data) & 0xFFFFFFFF != e["crc"]:
        raise SystemExit("CRC mismatch reading " + e["name"])
    return data

def find_target(entries):
    hits = [e for e in entries if re.search(r"(^|/)" + re.escape(TARGET) + r"$", e["name"])]
    if len(hits) != 1:
        raise SystemExit("expected exactly one %s in the archive, found %d" % (TARGET, len(hits)))
    return hits[0]

def list_values(data):
    m = LIST_RE.search(data)
    if not m:
        raise SystemExit("could not find 'level2TownFrequencyFactor = { ... }' (game version changed?)")
    return [x.decode() for x in NUM_RE.findall(m.group(2))]

def build_basis(cols):
    basis = {}
    for j, c in enumerate(cols):
        v, m = c, 1 << j
        while v:
            h = v.bit_length() - 1
            if h in basis:
                bv, bm = basis[h]
                v ^= bv
                m ^= bm
            else:
                basis[h] = (v, m)
                break
    return basis

def solve(basis, t):
    x = 0
    while t:
        h = t.bit_length() - 1
        if h not in basis:
            return None
        bv, bm = basis[h]
        t ^= bv
        x ^= bm
    return x

def same_length_text(data, vals):
    m = LIST_RE.search(data)
    b0, b1 = m.start(2) - 1, m.end(2) + 1          # braces included
    old_len = b1 - b0
    items = [v.encode() for v in vals]
    cands = [b"{ " + b", ".join(items) + b" }",
             b"{ " + b",".join(items) + b" }",
             b"{" + b",".join(items) + b"}"]
    brace = next((c for c in cands if len(c) <= old_len), cands[-1])
    new = bytearray(data[:b0] + brace + data[b1:])
    if len(brace) < old_len:                          # pad after the brace: keep file size
        new[b0 + len(brace):b0 + len(brace)] = b" " * (old_len - len(brace))
    deficit = len(new) - len(data)
    if deficit > 0:                                   # values are longer: trim comment text
        for cm in reversed(list(COMMENT_RE.finditer(bytes(new)))):
            cut = min(deficit, len(cm.group(2)))
            if cut:
                del new[cm.end(2) - cut:cm.end(2)]
                deficit -= cut
            if deficit == 0:
                break
        if deficit > 0:
            raise SystemExit("these values do not fit without growing the file")
    assert len(new) == len(data)
    return bytes(new)

def forge_crc(text, target_crc):
    """Rewrite 7 characters at the end of the longest comment so that crc32(text) == target_crc."""
    comments = list(COMMENT_RE.finditer(text))
    best = max(comments, key=lambda c: len(c.group(2)), default=None)
    if best is None or len(best.group(2)) < 8:
        return None
    a = best.end(2) - 7                               # 3 free printable chars + 4 solved chars
    base = bytearray(text)
    base[a + 3:a + 7] = b"\0\0\0\0"
    z0 = zlib.crc32(bytes(base))
    cols = []
    for j in range(32):
        t = bytearray(base)
        t[a + 3 + j // 8] ^= 1 << (j % 8)
        cols.append(zlib.crc32(bytes(t)) ^ z0)
    basis = build_basis(cols)
    for combo in itertools.product(range(0x20, 0x7F), repeat=3):
        base[a:a + 3] = bytes(combo)
        x = solve(basis, target_crc ^ zlib.crc32(bytes(base)))
        if x is None:
            continue
        fb = x.to_bytes(4, "little")
        if all(0x20 <= c <= 0x7E for c in fb):
            base[a + 3:a + 7] = fb
            out = bytes(base)
            if zlib.crc32(out) & 0xFFFFFFFF == target_crc:
                return out
    return None

def sanity_check_diff(old, new, vals):
    ol, nl = old.splitlines(True), new.splitlines(True)
    if len(ol) != len(nl):
        raise SystemExit("internal error: line count changed")
    for a, b in zip(ol, nl):
        if a != b and not (re.match(rb"[ \t]*--", a) and re.match(rb"[ \t]*--", b)) \
                and not (LIST_RE.search(a) and LIST_RE.search(b)):
            raise SystemExit("internal error: unexpected change: %r" % b)

def write_atomic(path, data):
    fd, tmp = tempfile.mkstemp(suffix=".zip", dir=os.path.dirname(os.path.abspath(path)))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise

def main():
    cmd, zpath = sys.argv[1], sys.argv[2]
    buf = open(zpath, "rb").read()
    entries = parse(buf)
    if cmd == "list":
        for e in entries:
            print(e["name"])
        return
    e = find_target(entries)
    old = read_entry(buf, e)
    if cmd == "values":
        print("entry: " + e["name"])
        print("level2TownFrequencyFactor = { %s }" % ", ".join(list_values(old)))
        return
    if cmd != "patch":
        raise SystemExit("unknown command")

    vals = sys.argv[3:]
    old_vals = list_values(old)
    if len(vals) != len(old_vals) and not os.environ.get("FORCE"):
        raise SystemExit("slider has %d positions but you gave %d values. Add/remove slider "
                         "entries in mod.json too, then rerun with FORCE=1" % (len(old_vals), len(vals)))
    if e["method"] != 0 or e["flags"] & 8:
        raise SystemExit("entry is compressed or uses a data descriptor; same-size patching needs a stored entry")

    new = same_length_text(old, vals)
    keep_crc = os.environ.get("KEEP_CRC", "1") != "0"
    forged = forge_crc(new, e["crc"]) if keep_crc else None
    if keep_crc and forged is None:
        print("note: could not preserve the CRC; updating the CRC fields instead", file=sys.stderr)
    if forged is not None:
        new = forged
    sanity_check_diff(old, new, vals)
    assert len(new) == len(old) == e["usize"]

    out = bytearray(buf)
    ds = data_start(buf, e)
    out[ds:ds + len(new)] = new
    new_crc = zlib.crc32(new) & 0xFFFFFFFF
    if new_crc != e["crc"]:
        struct.pack_into("<I", out, e["loff"] + 14, new_crc)
        struct.pack_into("<I", out, e["start"] + 16, new_crc)

    # verify before touching the real file
    e2 = parse(bytes(out))
    t2 = find_target(e2)
    if len(out) != len(buf) or [x["name"] for x in e2] != [x["name"] for x in entries]:
        raise SystemExit("internal error: archive layout changed")
    if read_entry(bytes(out), t2) != new:
        raise SystemExit("internal error: new content did not round-trip")
    changed = [i for i in range(len(buf)) if buf[i] != out[i]]
    allowed = set(range(ds, ds + len(new))) | set(range(e["loff"] + 14, e["loff"] + 18)) \
        | set(range(e["start"] + 16, e["start"] + 20))
    if any(i not in allowed for i in changed):
        raise SystemExit("internal error: bytes outside the entry changed")

    write_atomic(zpath, bytes(out))
    print("crc preserved: %s | bytes changed in archive: %d" % (new_crc == e["crc"], len(changed)))
    print("before: { %s }" % ", ".join(old_vals))
    print("after:  { %s }" % ", ".join(list_values(new)))

main()
PYEOF
)
pyz() { python3 -c "$PYZ" "$@"; }

cmd_find() {
  [[ -d ${1:-} ]] || die "usage: find <directory>"
  find "$1" -type f -name '*.zip' -print0 | while IFS= read -r -d '' z; do
    if pyz list "$z" 2>/dev/null | grep -qE "(^|/)${TARGET}\$"; then echo "$z"; fi
  done
}

cmd_show() {
  [[ -f ${1:-} ]] || die "usage: show <zip>"
  pyz values "$1"
}

cmd_apply() {
  local zip=${1:-}; shift || true
  [[ -f $zip && $# -ge 1 ]] || die "usage: apply <zip> v1 v2 ..."
  local v prev=0
  for v in "$@"; do
    [[ $v =~ ^[0-9]*\.?[0-9]+$ ]] || die "not a positive number: $v"
    if awk "BEGIN{exit !($v <= $prev)}"; then
      echo "warning: values are not strictly ascending ($prev then $v); the slider will look odd" >&2
    fi
    prev=$v
  done
  zip=$(realpath "$zip")
  pyz list "$zip" >/dev/null || die "cannot read $zip"
  [[ -e $zip.orig ]] || { cp -p "$zip" "$zip.orig"; echo "backup: $zip.orig"; }
  pyz patch "$zip" "$@" || die "archive left unchanged (backup at $zip.orig)"
}

cmd_restore() {
  [[ -f ${1:-} && -f ${1:-}.orig ]] || die "usage: restore <zip> (needs <zip>.orig)"
  cp -p "$1.orig" "$1"; echo "restored $1"
}

case "${1:-}" in
  find)    shift; cmd_find "$@" ;;
  show)    shift; cmd_show "$@" ;;
  apply)   shift; cmd_apply "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
