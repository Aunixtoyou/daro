"""把 assets/icons/brands/ 里的厂商官方 logo 合成到统一圆角瓦片底上。

用法:
  python tool/fetch_engine_brands.py     # 1. 抓官方原件(需联网)
  python tool/compose_engine_icons.py    # 2. 合成 assets/icons/engines/*.svg
  pip install svgelements                #    (依赖:用于计算原件的几何 bbox)

合成规则:
  * 24 viewBox、瓦片 rect(1.2,1.2,21.6,21.6,r3.4) 与 assets/icons/ui/*.svg 同族
  * 官方标保持原始全彩,按几何 bbox 等比缩放到瓦片内的安全框后居中,再裁剪到瓦片
  * 所有引擎共用同一块浅色底板,明暗主题下都靠它把官方标与背景分开
"""
import os
import re
import sys

from svgelements import SVG, Path

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, 'assets', 'icons', 'brands')
DST = os.path.join(REPO, 'assets', 'icons', 'engines')

TILE = (1.2, 1.2, 21.6, 21.6, 3.4)      # x, y, w, h, rx
LIVE = 17.6                              # 官方标最长边允许占据的瓦片内边长
PLATE = ('#ffffff', '#e8edf2')           # 底板渐变:上亮下稍暗
RIM = '#a9b4c0'                          # 描边,亮/暗主题下都能把瓦片与背景分开

# 引擎 id -> 安全框(瓦片内允许占据的宽高, px);默认正方形 LIVE
# Oracle 官方标识只有字标:让它吃满瓦片宽度,否则 14~20px 下完全不可辨
BOX = {'oracle': {'w': 20.0, 'h': 20.0}}
ICONS = {eid: BOX.get(eid, {}) for eid in
         ('mysql', 'postgresql', 'sqlserver', 'sqlite', 'access', 'mariadb',
          'oracle', 'mongodb', 'redis', 'snowflake')}


def art_bbox(path):
    """官方原件的几何 bbox(含描边外扩, viewBox 用户空间),返回 (x0, y0, x1, y1)。"""
    svg = SVG.parse(path, reify=True, ppi=100.0)
    # svgelements 会按 ppi 把 mm/in 等单位换算成像素空间,而我们要输出原始 path 坐标,
    # 因此必须把 bbox 折回 viewBox 用户空间。
    k = 1.0
    m = re.search(r'viewBox="([^"]+)"', open(path, encoding='utf-8').read())
    if m:
        vb = [float(v) for v in m.group(1).replace(',', ' ').split()]
        if len(vb) == 4 and vb[2] and svg.width:
            k = vb[2] / float(svg.width)
    box = None
    for e in svg.elements():
        if not isinstance(e, Path) or len(e) == 0:
            continue
        try:
            b = e.bbox()
        except Exception:
            continue
        x0, y0, x1, y1 = [float(v) * k for v in tuple(b)]
        sw = getattr(e, 'stroke_width', None)
        if getattr(e, 'stroke', None) is not None and sw:
            p = float(sw) / 2.0 * k
            x0, y0, x1, y1 = x0 - p, y0 - p, x1 + p, y1 + p
        x0, y0, x1, y1 = min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)
        box = (x0, y0, x1, y1) if box is None else (
            min(box[0], x0), min(box[1], y0), max(box[2], x1), max(box[3], y1))
    return box


ROOT_SVG = re.compile(r'<svg\b[^>]*>', re.I)
# 根 <svg> 上的呈现属性会被子元素继承;剥掉根标签后必须搬到包裹用的 <g> 上
INHERITED = ('fill', 'fill-rule', 'fill-opacity', 'stroke', 'stroke-width', 'stroke-opacity',
             'stroke-linecap', 'stroke-linejoin', 'opacity', 'color', 'clip-rule')


def inner_markup(text):
    """去掉根 <svg> 标签与 XML 声明,返回 (包裹属性串, 内部标记)。"""
    body = re.sub(r'<\?xml[^>]*\?>\s*', '', text, flags=re.I)
    body = re.sub(r'<!DOCTYPE[^>]*>\s*', '', body, flags=re.I)
    body = re.sub(r'<!--.*?-->', '', body, flags=re.S)
    m = ROOT_SVG.search(body)
    if not m:
        raise RuntimeError('未找到根 <svg>')
    root = m.group(0)
    attrs = dict((k.lower(), v) for k, v in re.findall(r'([\w:-]+)="([^"]*)"', root))
    head = ['xmlns="http://www.w3.org/2000/svg"']
    head += ['%s="%s"' % (a, attrs[a]) for a in INHERITED if a in attrs]
    for k, v in attrs.items():
        if k.startswith('xmlns:'):
            head.append('%s="%s"' % (k, v))
    inner = body[m.end(): body.rindex('</svg>')] if '</svg>' in body else body[m.end():]
    # Inkscape 的编辑器元数据 flutter_svg 无法解析(会打印 unhandled element 警告)
    JUNK = re.compile(
        r'<((?:sodipodi|inkscape|metadata|rdf)[:\w-]*)\b[^>]*/>'
        r'|<((?:sodipodi|inkscape|metadata|rdf)[:\w-]*)\b[^>]*>(?:(?!</\2>).)*?</\2>',
        re.S)
    inner = JUNK.sub('', inner)
    return ' '.join(head), inner.strip()


def compose(eid, cfg):
    raw = open(os.path.join(SRC, '%s.svg' % eid), encoding='utf-8').read()
    x0, y0, x1, y1 = art_bbox(os.path.join(SRC, '%s.svg' % eid))
    bw, bh = x1 - x0, y1 - y0
    if bw <= 0 or bh <= 0:
        raise RuntimeError('%s 原件 bbox 为空' % eid)

    tx, ty, tw, th, tr = TILE
    cx, cy = tx + tw / 2.0, ty + th / 2.0
    s = min(cfg.get('w', LIVE) / bw, cfg.get('h', LIVE) / bh)

    ns, inner = inner_markup(raw)
    # 官方原件自带的 defs 保留(渐变/裁剪会用到);根命名空间搬到 <g> 上
    defs = re.search(r'<defs\b.*?</defs>', inner, re.S | re.I)
    drawable = inner
    if defs:
        drawable = inner.replace(defs.group(0), '', 1)

    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">']
    out.append('  <!-- %s:厂商官方 logo 合成到统一圆角瓦片底;出处见 assets/icons/brands/SOURCES.json -->' % eid)
    out.append('  <defs>')
    out.append('    <linearGradient id="plate" x1="0" y1="0" x2="0" y2="1">')
    out.append('      <stop offset="0" stop-color="%s"/>' % PLATE[0])
    out.append('      <stop offset="1" stop-color="%s"/>' % PLATE[1])
    out.append('    </linearGradient>')
    out.append('    <clipPath id="tile"><rect x="%s" y="%s" width="%s" height="%s" rx="%s"/></clipPath>'
               % (g(tx), g(ty), g(tw), g(th), g(tr)))
    if defs:
        out.append('    ' + re.sub(r'\s+', ' ', defs.group(0)))
    out.append('  </defs>')
    out.append('  <rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="url(#plate)"/>'
               % (g(tx), g(ty), g(tw), g(th), g(tr)))
    out.append('  <g clip-path="url(#tile)">')
    out.append('    <g %s transform="translate(%s %s) scale(%s) translate(%s %s)">'
               % (ns, g(cx), g(cy), g(s), g(-(x0 + bw / 2.0)), g(-(y0 + bh / 2.0))))
    out.append('      ' + re.sub(r'\s*\n\s*', ' ', drawable))
    out.append('    </g>')
    out.append('  </g>')
    out.append('  <rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="none" stroke="%s" stroke-width="0.7" stroke-opacity="0.85"/>'
               % (g(tx + 0.35), g(ty + 0.35), g(tw - 0.7), g(th - 0.7), g(tr - 0.35), RIM))
    out.append('</svg>')
    path = os.path.join(DST, '%s.svg' % eid)
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(out) + '\n')
    return os.path.getsize(path), (bw * s, bh * s)


def g(v):
    """去掉浮点噪声,保持 SVG 可读。"""
    return ('%.4f' % v).rstrip('0').rstrip('.')


def main():
    os.makedirs(DST, exist_ok=True)
    only = [a for a in sys.argv[1:] if not a.startswith('-')]
    for eid, cfg in ICONS.items():
        if only and eid not in only:
            continue
        size, drawn = compose(eid, cfg)
        print('%-11s %6d B  标绘 %.1f x %.1f px' % (eid, size, drawn[0], drawn[1]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
