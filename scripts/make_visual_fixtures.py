"""Generate ten synthetic PNGs for an isolated CI simulator; no user media or downloads."""
from pathlib import Path
import struct
import sys
import zlib

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)

def chunk(name, data):
    return struct.pack('>I', len(data)) + name + data + struct.pack('>I', zlib.crc32(name + data) & 0xffffffff)

for index in range(10):
    width, height = ((900, 1200) if index % 2 else (1200, 900))
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            horizon = int(height * 0.56)
            sun = (x - width * 0.72) ** 2 + (y - height * 0.24) ** 2 < (width * 0.085) ** 2
            ridge = horizon - abs(x - width * 0.40) * 0.42
            if sun:
                rgb = (255, 216, 143)
            elif y > horizon:
                rgb = (32 + index * 4, 100 + int(45 * y / height), 151 + index * 4)
            elif y > ridge:
                rgb = (42 + index * 6, 79 + index * 6, 106 + index * 7)
            else:
                rgb = (158 + index * 8, 190 + index * 5, 210 + index * 4)
            rows.extend(rgb)
    data = b'\x89PNG\r\n\x1a\n'
    data += chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    data += chunk(b'IDAT', zlib.compress(rows, 6)) + chunk(b'IEND', b'')
    (out / f'visual-fixture-{index}.png').write_bytes(data)
print('Generated 10 synthetic images; no personal data')
