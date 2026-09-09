"""把 build/ico/<size>.png 打包成 windows/runner/resources/app_icon.ico。

前置:flutter test test/app_icon_test.dart 生成各档位 PNG。
ICO 采用 PNG 负载(Vista+ 支持),保留 alpha 且比 BMP 负载小得多。

用法:python tool/make_app_icon.py
"""
import os
import struct

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(repo, 'build', 'ico')
out = os.path.join(repo, 'windows', 'runner', 'resources', 'app_icon.ico')

sizes = sorted(
    int(f.split('.')[0])
    for f in os.listdir(src)
    if f.endswith('.png') and f.split('.')[0].isdigit()
)
blobs = [(s, open(os.path.join(src, f'{s}.png'), 'rb').read()) for s in sizes]

header = struct.pack('<HHH', 0, 1, len(blobs))
entry_size = 16 * len(blobs)
offset = 6 + entry_size

entries, payload = [], []
for size, blob in blobs:
    # 256 在目录项里用 0 表示
    dim = size % 256
    entries.append(
        struct.pack('<BBBBHHII', dim, dim, 0, 0, 1, 32, len(blob), offset)
    )
    payload.append(blob)
    offset += len(blob)

with open(out, 'wb') as f:
    f.write(header + b''.join(entries) + b''.join(payload))

print('已写出', os.path.relpath(out, repo))
print('档位:', ', '.join(str(s) for s in sizes))
