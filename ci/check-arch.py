#!/usr/bin/env python3
"""校验 Mach-O 架构（容器内没有 file 命令，直接读文件头）。

支持 fat/universal（0xcafebabe）与 thin Mach-O（0xfeedfacf 等）。
只接受 arm64，因为这是 iPhoneOS 未签名包。
"""
from __future__ import annotations

import struct
import sys

CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPE_X86_64 = 0x01000007

MH_MAGIC = 0xFEEDFACE
MH_CIGAM = 0xCEFAEDFE
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

ARCH_NAMES = {
    CPU_TYPE_ARM64: "arm64",
    CPU_TYPE_X86_64: "x86_64",
    7: "i386",
    12: "arm",
}


def describe(path: str) -> list[str]:
    with open(path, "rb") as fh:
        head = fh.read(8)
        if len(head) < 8:
            raise ValueError("文件太小，不是 Mach-O")
        magic = struct.unpack(">I", head[:4])[0]

        # fat / universal
        if magic in (FAT_MAGIC, FAT_MAGIC_64):
            fh.seek(0)
            nfat = struct.unpack(">I", fh.read(8)[4:8])[0]
            arches = []
            is64 = magic == FAT_MAGIC_64
            for _ in range(nfat):
                chunk = fh.read(32 if is64 else 20)
                if len(chunk) < (32 if is64 else 20):
                    break
                cputype = struct.unpack(">i", chunk[:4])[0]
                arches.append(ARCH_NAMES.get(cputype & 0xFFFFFFFF, f"cpu={cputype:#x}"))
            return arches

        # thin
        fh.seek(0)
        raw = fh.read(8)
        le_magic = struct.unpack("<I", raw[:4])[0]
        for candidate in (le_magic, magic):
            if candidate in (MH_MAGIC, MH_MAGIC_64, MH_CIGAM, MH_CIGAM_64):
                # cputype 紧随 magic，字节序与 magic 一致
                endian = "<" if candidate in (MH_MAGIC, MH_MAGIC_64) else ">"
                cputype = struct.unpack(endian + "i", raw[4:8])[0]
                return [ARCH_NAMES.get(cputype & 0xFFFFFFFF, f"cpu={cputype:#x}")]
        raise ValueError(f"未知文件头 {raw[:4].hex()}")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check-arch.py <macho-binary>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        arches = describe(path)
    except (OSError, ValueError) as err:
        print(f"::error::无法读取 Mach-O: {err}", file=sys.stderr)
        return 1

    print(f"  architectures: {arches}")
    if "arm64" not in arches:
        print(f"::error::不是 arm64（实际 {arches}）", file=sys.stderr)
        return 1
    print("ARCH_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
