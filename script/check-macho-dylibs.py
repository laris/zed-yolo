#!/usr/bin/env python3
import collections
import pathlib
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x18
LC_REEXPORT_DYLIB = 0x1F
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x23

DYLIB_COMMANDS = {
    LC_LOAD_DYLIB,
    LC_LOAD_WEAK_DYLIB,
    LC_REEXPORT_DYLIB,
    LC_LAZY_LOAD_DYLIB,
    LC_LOAD_UPWARD_DYLIB,
}


def read_cstr(data: bytes, offset: int, limit: int) -> str:
    end = data.find(b"\0", offset, limit)
    if end == -1:
        end = limit
    return data[offset:end].decode("utf-8", errors="replace")


def dylibs(path: pathlib.Path) -> list[str]:
    data = path.read_bytes()
    if len(data) < 32:
        raise ValueError("file is too small for a Mach-O header")

    magic = struct.unpack_from("<I", data, 0)[0]
    if magic == MH_MAGIC_64:
        endian = "<"
    elif magic == MH_CIGAM_64:
        endian = ">"
    else:
        raise ValueError(f"unsupported Mach-O magic 0x{magic:08x}")

    ncmds = struct.unpack_from(f"{endian}I", data, 16)[0]
    offset = 32
    names = []
    for _ in range(ncmds):
        if offset + 8 > len(data):
            raise ValueError("load command extends past end of file")
        cmd, cmdsize = struct.unpack_from(f"{endian}II", data, offset)
        if cmdsize < 8 or offset + cmdsize > len(data):
            raise ValueError(f"invalid load command size {cmdsize} at {offset}")
        if cmd in DYLIB_COMMANDS:
            nameoff = struct.unpack_from(f"{endian}I", data, offset + 8)[0]
            names.append(read_cstr(data, offset + nameoff, offset + cmdsize))
        offset += cmdsize
    return names


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check-macho-dylibs.py <mach-o> [...]", file=sys.stderr)
        return 2

    failed = False
    for arg in sys.argv[1:]:
        path = pathlib.Path(arg)
        try:
            names = dylibs(path)
        except ValueError as error:
            print(f"{path}: {error}", file=sys.stderr)
            failed = True
            continue

        counts = collections.Counter(names)
        duplicates = {name: count for name, count in counts.items() if count > 1}
        if duplicates:
            failed = True
            print(f"{path}: duplicate dylib load commands:", file=sys.stderr)
            for name, count in sorted(duplicates.items()):
                print(f"  {count}x {name}", file=sys.stderr)
        else:
            print(f"{path}: {len(names)} dylib load commands, no duplicates")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
