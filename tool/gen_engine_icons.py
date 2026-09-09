"""【已被取代】自绘母题版引擎图标:python tool/gen_engine_icons.py

现行方案是 tool/compose_engine_icons.py —— 把厂商官方 logo 合成到同一套圆角瓦片底,
两者写同一个输出路径 assets/icons/engines/*.svg。本文件只作为"官方素材不可用时退回自绘"
的参考保留,不要随手运行(会覆盖官方 logo 版)。

按 ui 图标家族规格重绘 assets/icons/engines/*.svg。

家族规格(取自 assets/icons/ui/{table,query,connection,schema}.svg):
  - 24 viewBox,内容 live area 约 21.4(1.2 ~ 22.8)
  - 圆角 / 短边 ≈ 0.15(table: 2.8/18.8,query: 2.2/12.8)
  - 主笔画 2.6 ~ 3.2
  - 立体感来自同色系纵向渐变(steelA / skin / shirt),不是白色叠层
"""
import colorsys
import os

TILE = dict(x=1.2, y=1.2, w=21.6, h=21.6, rx=3.4)
SW = 2.8


def shift(hexcolor, dl):
    """同色系明度偏移(HSL 的 L 加减 dl,饱和度保持)。"""
    h = hexcolor.lstrip('#')
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    hh, l, s = colorsys.rgb_to_hls(r, g, b)
    l = min(max(l + dl, 0.0), 1.0)
    return '#%02x%02x%02x' % tuple(round(c * 255) for c in colorsys.hls_to_rgb(hh, l, s))


def tile(gid, base):
    return f'''  <defs>
    <linearGradient id="{gid}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{shift(base, .12)}"/>
      <stop offset="1" stop-color="{shift(base, -.12)}"/>
    </linearGradient>
  </defs>
  <rect x="{TILE['x']}" y="{TILE['y']}" width="{TILE['w']}" height="{TILE['h']}" rx="{TILE['rx']}" fill="url(#{gid})"/>'''


STROKE = f'fill="none" stroke="#ffffff" stroke-width="{SW}" stroke-linecap="round"'
STROKE_JOIN = f'{STROKE} stroke-linejoin="round"'

MOTIFS = {
    # MySQL:官方吉祥物「SQL 海豚」sakila —— 弓背跃起 + 圆额 + 细长吻 + 背鳍 + 尾叶
    'mysql': lambda b: f'  <path d="M7.4 15.0C9.4 10.8 12.4 7.8 15.8 6.2" fill="none" stroke="#ffffff" stroke-width="5.4" stroke-linecap="round"/>\n'
                       '  <g fill="#ffffff">\n'
                       '    <circle cx="15.8" cy="6.8" r="3.0"/>\n'
                       '    <path d="M16.2 5.0 22.2 7.2 16.2 8.8Z"/>\n'
                       '    <path d="M8.6 10.8 10.2 4.6 12.8 7.6Z"/>\n'
                       '    <path d="M7.6 14.6 2.6 11.8c1.6 3.4 1.8 6.2.8 8.8Z"/>\n'
                       '  </g>\n'
                       f'  <circle cx="16.0" cy="6.2" r="1.0" fill="{b}"/>',
    # PostgreSQL:吉祥物 Slonik 象头 —— 双耳 + 头 + 内卷长鼻
    'postgresql': lambda b: f'  <g {STROKE} stroke-width="3"><path d="M6.6 11.6a2.9 4 0 0 1 0-6.4M17.4 11.6a2.9 4 0 0 0 0-6.4"/></g>\n'
                            '  <circle cx="12" cy="8.8" r="5.2" fill="#ffffff"/>\n'
                            f'  <path d="M12 13.8v2.8a2.7 2.7 0 0 0 5.4 0v-1.3" fill="none" stroke="#ffffff" stroke-width="3" stroke-linecap="round"/>\n'
                            f'  <g fill="{b}"><circle cx="9.9" cy="8.4" r="1.1"/><circle cx="14.1" cy="8.4" r="1.1"/></g>',
    # SQL Server:老版 SSMS 旋带标 —— 三片强旋弧叶绕中心(奇数叶 = 漩涡而非花瓣)
    'sqlserver': lambda b: '  <g fill="#ffffff">\n'
                           + ''.join(
                               f'    <path d="M12 12c.6-4.6 3.0-7.8 7.6-8.8-1.0 5.2-3.2 7.6-7.6 8.8Z" transform="rotate({a} 12 12)"/>\n'
                               for a in (0, 120, 240))
                           + '  </g>',
    # SQLite:吉祥物「鲸鲨」Samuel —— 横向鱼雷身 + 高背鳍 + 胸鳍 + 叉尾
    'sqlite': lambda b: '  <g fill="#ffffff">\n'
                        '    <path d="M2.4 13c4-3 9.4-4 13.6-3.2 2.2.4 3.4 1.4 3.4 2.8s-1.4 2.4-3.6 2.8c-4.4.8-9.6-.2-13.4-2.4Z"/>\n'
                        '    <path d="M11 9.6 13.2 5.2 15.4 9.8Z"/>\n'
                        '    <path d="M12.4 15.4 10.8 19.8 8.6 15.2Z"/>\n'
                        '    <path d="M18.2 12.6 22.6 8.6c-1.4 3-1.4 5.4 0 8.2Z"/>\n'
                        '  </g>\n'
                        f'  <circle cx="5.6" cy="12.6" r="1" fill="{b}"/>',
    # Access:官方小尺寸标就是棕红底白字母 A —— 用笔画字架(带横梁)避免读成警告三角
    'access': lambda b: f'  <g {STROKE_JOIN}>\n'
                        '    <path d="M6.2 18.6 12 5.6l5.8 13"/>\n'
                        '    <path d="M8.9 14.3h6.2"/>\n'
                        '  </g>',
    # MariaDB:吉祥物「顶球海狮」—— 头特写 + 吻部上举 + 鼻尖顶球(全身版在 20px 糊成一团)
    'mariadb': lambda b: '  <g fill="#ffffff">\n'
                         '    <circle cx="11.4" cy="13.0" r="6.0"/>\n'
                         '    <circle cx="16.8" cy="9.6" r="3.0"/>\n'
                         '    <circle cx="19.6" cy="4.6" r="2.6"/>\n'
                         '  </g>\n'
                         f'  <g fill="{b}"><circle cx="12.0" cy="11.4" r="1.3"/><circle cx="18.4" cy="8.6" r="1.0"/></g>',
    # Oracle:官方小尺寸标就是红底白 O(字标无法矢量复刻,沿用其 favicon 做法)
    'oracle': lambda b: f'  <ellipse cx="12" cy="12" rx="7" ry="5" {STROKE}/>',
    # MongoDB:官方叶子(叶脉用底色挖出)
    'mongodb': lambda b: '  <path d="M12 5.2c3.2 3.3 4.8 6.1 4.8 8.6 0 2.8-1.8 4.5-4.8 5.3-3-.8-4.8-2.5-4.8-5.3 0-2.5 1.6-5.3 4.8-8.6Z" fill="#ffffff"/>\n'
                         f'  <path d="M12 7.8v10.6" stroke="{b}" stroke-width="1.6" stroke-linecap="round" fill="none"/>',
    # Redis:官方堆叠砖层
    'redis': lambda b: '  <g fill="#ffffff">\n'
                       '    <rect x="5" y="5.4" width="14" height="3.4" rx="1.7"/>\n'
                       '    <rect x="6.5" y="10.3" width="11" height="3.4" rx="1.7"/>\n'
                       '    <rect x="8" y="15.2" width="8" height="3.4" rx="1.7"/>\n'
                       '  </g>',
    # Snowflake:官方六角雪花
    'snowflake': lambda b: f'  <g {STROKE}>\n'
                           '    <path d="M12 5.2v13.6M6.1 8.6l11.8 6.8M17.9 8.6 6.1 15.4"/>\n'
                           '  </g>',
}

BRANDS = {
    'mysql': '#4479a1',
    'postgresql': '#4169e1',
    'sqlserver': '#cc2927',
    'sqlite': '#0e6d8f',
    'access': '#a4373a',
    'mariadb': '#4a8f7d',
    'oracle': '#c74634',
    'mongodb': '#47a248',
    'redis': '#dc382d',
    'snowflake': '#29b5e8',
}

out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'assets', 'icons', 'engines')
for i, (eid, base) in enumerate(BRANDS.items()):
    gid = f't{i}'
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">\n'
           + tile(gid, base) + '\n' + MOTIFS[eid](base) + '\n</svg>\n')
    with open(os.path.join(out, f'{eid}.svg'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(svg)
print('已重写', len(BRANDS), '个引擎瓦片')
