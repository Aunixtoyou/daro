"""由 assets/icons/brands/SOURCES.json 生成 NOTICE.md(第三方商标素材出处声明)。

用法:
  python tool/fetch_engine_brands.py    # 抓取/更新官方原件与 SOURCES.json
  python tool/compose_engine_icons.py   # 合成 assets/icons/engines/*.svg
  python tool/gen_brand_notice.py       # 生成 NOTICE.md
"""
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO, 'assets', 'icons', 'brands', 'SOURCES.json')
OUT = os.path.join(REPO, 'NOTICE.md')

OWNER_NOTE = 'daro 与上述厂商之间不存在隶属、赞助、背书或授权关系。'


def main():
    if not os.path.exists(SOURCES):
        print('缺少 %s,请先运行 python tool/fetch_engine_brands.py' % os.path.relpath(SOURCES, REPO),
              file=sys.stderr)
        return 1
    with open(SOURCES, encoding='utf-8') as f:
        sources = json.load(f)
    owners = sorted({sources[e].get('trademark_owner', '') for e in sources} - {''})

    lines = [
        '# 第三方商标声明 (NOTICE)',
        '',
        'daro 的连接树、对话框等处会显示各数据库引擎的**厂商官方 logo**。',
        '这些商标仅用于**指示该连接所指向的数据库产品**（指示性使用 / compatibility use），',
        '与 DataGrip、DBeaver 等同类工具的做法一致；不用于暗示厂商对 daro 的背书或授权。',
        '',
        '## 使用方式',
        '',
        '* 官方原件抓取到 `assets/icons/brands/`，由 `tool/compose_engine_icons.py` 等比放进统一圆角瓦片底，',
        '  输出 `assets/icons/engines/<id>.svg`。**未改动 logo 的几何与配色**（仅整体缩放、居中、裁剪到瓦片）。',
        '* `assets/icons/brands/` 未登记进 `pubspec.yaml` 的 assets，因此**原始文件不随应用分发**，',
        '  随分发的只有合成后的 `assets/icons/engines/`。',
        '* 素材来源与权利人记录在 `assets/icons/brands/SOURCES.json`，本文件由其自动生成。',
        '',
        '## 素材清单',
        '',
        '| 引擎 | 商标 | 权利人 | 来源 |',
        '|---|---|---|---|',
    ]
    for eid in sorted(sources):
        rec = sources[eid]
        lines.append('| `%s` | %s | %s | %s |' % (
            eid, rec.get('mark', ''), rec.get('trademark_owner', ''),
            rec.get('source_url', '')))
    lines += [
        '',
        '## 权利归属',
        '',
        '上述商标及其 logo 权利归属各自厂商：%s。' % '、'.join(owners),
        '',
        OWNER_NOTE,
        '',
        '如任一权利人希望以其他方式署名或要求移除其标识，请提 issue，我们会在下个版本处理。',
        '',
        '> 本文件由 `tool/gen_brand_notice.py` 生成，请勿手工编辑清单部分。',
    ]
    with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')
    print('写出 NOTICE.md（%d 项素材）' % len(sources))
    return 0


if __name__ == '__main__':
    sys.exit(main())
