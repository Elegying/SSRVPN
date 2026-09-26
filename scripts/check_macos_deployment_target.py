#!/usr/bin/env python3
"""Check every shipped Mach-O slice, including the compressed core."""
import gzip
import plistlib
import struct
import sys
from pathlib import Path


THIN = {b'\xce\xfa\xed\xfe': ('<', 28), b'\xcf\xfa\xed\xfe': ('<', 32),
        b'\xfe\xed\xfa\xce': ('>', 28), b'\xfe\xed\xfa\xcf': ('>', 32)}
FAT = {b'\xca\xfe\xba\xbe': ('>', 20), b'\xbe\xba\xfe\xca': ('<', 20),
       b'\xca\xfe\xba\xbf': ('>', 32), b'\xbf\xba\xfe\xca': ('<', 32)}


def minimum_versions(data: bytes) -> list[tuple[int, int, int]]:
    magic = data[:4]
    if magic in FAT:
        endian, stride = FAT[magic]
        count, = struct.unpack_from(endian + 'I', data, 4)
        if not 0 < count <= 32 or 8 + count * stride > len(data):
            raise ValueError('invalid fat header')
        versions = []
        for index in range(count):
            offset, size = struct.unpack_from(endian + ('II' if stride == 20 else 'QQ'),
                                               data, 8 + index * stride + 8)
            if size == 0 or offset < 8 + count * stride or offset + size > len(data):
                raise ValueError('invalid fat slice')
            versions.extend(minimum_versions(data[offset:offset + size]))
        return versions
    if magic not in THIN:
        raise ValueError('not a Mach-O binary')
    endian, header_size = THIN[magic]
    count, command_bytes = struct.unpack_from(endian + 'II', data, 16)
    end = header_size + command_bytes
    if end > len(data) or count > command_bytes // 8:
        raise ValueError('invalid load commands')
    cursor = header_size
    versions = []
    for _ in range(count):
        command, size = struct.unpack_from(endian + 'II', data, cursor)
        if size < 8 or cursor + size > end:
            raise ValueError('invalid load command')
        if command == 0x32:  # LC_BUILD_VERSION
            if size < 24:
                raise ValueError('invalid build version')
            platform, version = struct.unpack_from(endian + 'II', data, cursor + 8)
            if platform != 1:
                raise ValueError('non-macOS platform in app')
            versions.append((version >> 16, (version >> 8) & 255, version & 255))
        elif command == 0x24:  # LC_VERSION_MIN_MACOSX
            if size < 16:
                raise ValueError('invalid minimum version')
            version, = struct.unpack_from(endian + 'I', data, cursor + 8)
            versions.append((version >> 16, (version >> 8) & 255, version & 255))
        cursor += size
    if cursor != end or len(versions) != 1:
        raise ValueError('missing or ambiguous macOS minimum version')
    return versions


def check_app(app: Path) -> int:
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    floor = tuple(int(part) for part in info['LSMinimumSystemVersion'].split('.'))
    floor = (floor + (0, 0, 0))[:3]
    if floor != (13, 0, 0):
        raise ValueError(f'app must declare macOS 13.0, got {floor}')
    main = app / 'Contents/MacOS' / info['CFBundleExecutable']
    core = app / 'Contents/Frameworks/App.framework/Resources/flutter_assets/assets/AtlasCore.gz'
    required = {main.resolve(), core.resolve()}
    seen = set()
    for path in app.rglob('*'):
        if not path.is_file() or path.resolve() in seen:
            continue
        resolved = path.resolve()
        with path.open('rb') as stream:
            magic = stream.read(4)
        if resolved not in required and magic not in THIN and magic not in FAT:
            continue
        data = gzip.decompress(path.read_bytes()) if resolved == core.resolve() else path.read_bytes()
        versions = minimum_versions(data)
        if any(version > floor for version in versions):
            raise ValueError(f'{path.relative_to(app)} requires {versions}, app declares {floor}')
        seen.add(resolved)
        print(f'{path.relative_to(app)}: {versions}')
    if not required <= seen:
        raise ValueError('missing main executable or compressed core')
    return len(seen)


if __name__ == '__main__':
    try:
        print(f'Checked {check_app(Path(sys.argv[1]))} binaries: macOS 13.0 floor satisfied')
    except (ValueError, KeyError, OSError, struct.error) as error:
        raise SystemExit(f'macOS deployment check failed: {error}')
