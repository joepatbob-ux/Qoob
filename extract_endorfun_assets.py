#!/usr/bin/env python3
"""Extract ELVRL/ and rloops/ from an Endorfun 1.0 HFS Toast image.

Requires Homebrew `hfsutils` (`hmount`, `hls`, `hcopy`, `humount`).
Classic Mac rhythm loops live in resource-fork `snd ` resources; this
script converts them to WAV. ELV level files are copied from the data fork.
"""

from __future__ import annotations

import argparse
import re
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kwargs)


def hls_names(hfs_dir: str) -> list[str]:
    """List filenames in an HFS directory, decoding hls -b escapes."""
    out = run(["hls", "-1b", hfs_dir]).stdout
    names: list[str] = []
    for line in out.splitlines():
        name = line.strip()
        if not name or name.startswith(":"):
            continue
        # hls -b uses octal escapes like \177
        name = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), name)
        name = name.replace(r"\\", "\\")
        names.append(name)
    return names


def safe_unix_name(name: str) -> str:
    """Drop non-printable chars (e.g. DEL in Hpurist.elv)."""
    cleaned = "".join(ch for ch in name if 32 <= ord(ch) < 127)
    return cleaned or "unnamed"


def extract_macbinary(hfs_path: str, dest: Path) -> None:
    run(["hcopy", "-m", hfs_path, str(dest)])


def extract_raw_data(hfs_path: str, dest: Path) -> None:
    run(["hcopy", "-r", hfs_path, str(dest)])


def split_macbinary(blob: bytes) -> tuple[bytes, bytes]:
    data_len = int.from_bytes(blob[83:87], "big")
    rsrc_len = int.from_bytes(blob[87:91], "big")
    pad = (128 - (data_len % 128)) % 128
    data = blob[128 : 128 + data_len]
    rsrc = blob[128 + data_len + pad : 128 + data_len + pad + rsrc_len]
    return data, rsrc


def iter_resources(rsrc: bytes):
    if len(rsrc) < 16:
        return
    data_off = int.from_bytes(rsrc[0:4], "big")
    map_off = int.from_bytes(rsrc[4:8], "big")
    type_list = map_off + int.from_bytes(rsrc[map_off + 24 : map_off + 26], "big")
    n_types = int.from_bytes(rsrc[type_list : type_list + 2], "big") + 1
    for i in range(n_types):
        off = type_list + 2 + i * 8
        typ = rsrc[off : off + 4]
        count = int.from_bytes(rsrc[off + 4 : off + 6], "big") + 1
        ref_off = type_list + int.from_bytes(rsrc[off + 6 : off + 8], "big")
        for j in range(count):
            ro = ref_off + j * 12
            rid = struct.unpack(">h", rsrc[ro : ro + 2])[0]
            packed = int.from_bytes(rsrc[ro + 4 : ro + 8], "big")
            doff = packed & 0xFFFFFF
            length = int.from_bytes(rsrc[data_off + doff : data_off + doff + 4], "big")
            data = rsrc[data_off + doff + 4 : data_off + doff + 4 + length]
            yield typ, rid, data


def snd_to_pcm(snd: bytes) -> tuple[float, int, int, bytes]:
    fmt = int.from_bytes(snd[0:2], "big")
    if fmt != 1:
        raise ValueError(f"unsupported snd format {fmt}")
    nmod = int.from_bytes(snd[2:4], "big")
    p = 4 + nmod * 6
    ncmd = int.from_bytes(snd[p : p + 2], "big")
    p += 2
    for _ in range(ncmd):
        cmd = int.from_bytes(snd[p : p + 2], "big")
        p2 = int.from_bytes(snd[p + 4 : p + 8], "big")
        p += 8
        if not (cmd & 0x8000):
            continue
        hdr = p2
        encode = snd[hdr + 20]
        rate = int.from_bytes(snd[hdr + 8 : hdr + 12], "big") / 65536.0
        if encode == 0xFF:  # extended sound header
            channels = int.from_bytes(snd[hdr + 4 : hdr + 8], "big")
            frames = int.from_bytes(snd[hdr + 22 : hdr + 26], "big")
            sample_size = int.from_bytes(snd[hdr + 48 : hdr + 50], "big")
            width = max(sample_size // 8, 1)
            samples = snd[hdr + 64 : hdr + 64 + frames * channels * width]
            return rate, channels, sample_size, samples
        if encode == 0:  # standard mono header
            length = int.from_bytes(snd[hdr + 4 : hdr + 8], "big")
            samples = snd[hdr + 22 : hdr + 22 + length]
            return rate, 1, 8, samples
        raise ValueError(f"unsupported encode {encode}")
    raise ValueError("no offset bufferCmd in snd resource")


def macbinary_snd_to_wav(macbinary: bytes, dest_wav: Path) -> None:
    _, rsrc = split_macbinary(macbinary)
    for typ, _rid, snd in iter_resources(rsrc):
        if typ != b"snd ":
            continue
        rate, channels, sample_size, samples = snd_to_pcm(snd)
        with wave.open(str(dest_wav), "wb") as w:
            w.setnchannels(channels)
            w.setsampwidth(max(sample_size // 8, 1))
            w.setframerate(int(round(rate)))
            w.writeframes(samples)
        return
    raise ValueError("no snd resource found")


def extract_elvrl(dest: Path) -> int:
    dest.mkdir(parents=True, exist_ok=True)
    count = 0
    for name in hls_names("Elvrl"):
        if not name.lower().endswith(".elv"):
            continue
        out_name = safe_unix_name(name)
        out = dest / out_name
        extract_raw_data(f":Elvrl:{name}", out)
        count += 1
        print(f"  ELV  {out_name} ({out.stat().st_size} bytes)")
    return count


def write_silence_wav(dest: Path, seconds: float = 1.0, rate: int = 22255) -> None:
    frames = int(rate * seconds)
    with wave.open(str(dest), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(1)
        w.setframerate(rate)
        w.writeframes(bytes([128, 128]) * frames)


def extract_rloops(dest: Path) -> int:
    dest.mkdir(parents=True, exist_ok=True)
    count = 0
    errors = 0
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        for name in hls_names("Rloops"):
            bin_path = tmp_path / "loop.bin"
            try:
                extract_macbinary(f":Rloops:{name}", bin_path)
                out_name = safe_unix_name(name)
                if not out_name.lower().endswith(".wav"):
                    out_name = f"{out_name}.wav"
                out = dest / out_name
                blob = bin_path.read_bytes()
                data, rsrc = split_macbinary(blob)
                # Disc placeholder is a 7-byte data fork containing "nosound"
                if not rsrc and data.strip().lower() in {b"nosound", b""}:
                    write_silence_wav(out)
                else:
                    macbinary_snd_to_wav(blob, out)
                count += 1
                if count % 50 == 0:
                    print(f"  ... {count} WAVs")
            except Exception as exc:  # noqa: BLE001 - keep extracting remaining loops
                errors += 1
                print(f"  FAIL {name!r}: {exc}", file=sys.stderr)
    print(f"  rloops done: {count} ok, {errors} failed")
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "toast",
        nargs="?",
        default=str(Path.home() / "Downloads" / "Endorfun_1_0" / "ENDORFUN.toast"),
        help="Path to ENDORFUN.toast",
    )
    parser.add_argument(
        "-o",
        "--output",
        default=".",
        help="Project root to write ELVRL/ and rloops/ into",
    )
    args = parser.parse_args()

    toast = Path(args.toast).expanduser().resolve()
    out_root = Path(args.output).expanduser().resolve()
    if not toast.is_file():
        print(f"Toast image not found: {toast}", file=sys.stderr)
        return 1

    for tool in ("hmount", "hls", "hcopy", "humount"):
        if subprocess.call(["which", tool], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL):
            print(f"Missing {tool}; install with: brew install hfsutils", file=sys.stderr)
            return 1

    print(f"Mounting {toast}")
    run(["hmount", str(toast)])
    try:
        print("Extracting Elvrl -> ELVRL/")
        n_elv = extract_elvrl(out_root / "ELVRL")
        print("Extracting Rloops -> rloops/ (snd -> WAV)")
        n_wav = extract_rloops(out_root / "rloops")
    finally:
        run(["humount"])

    print(f"Done: {n_elv} ELV files, {n_wav} WAV files -> {out_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
