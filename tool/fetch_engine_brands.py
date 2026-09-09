"""抓取数据库厂商官方 logo 原件到 assets/icons/brands/。

用法:python tool/fetch_engine_brands.py

来源优先级:
  1. devicon —— 托管的是厂商官方原始全彩标(仅图形几何为第三方重排)
  2. simple-icons CDN —— 官方符号的几何 + 厂商品牌主色(官方符号本就单色的厂商等价于全彩)
  3. Wikimedia Commons 直链(原始作者即厂商)

每个文件的出处与版权方记在 assets/icons/brands/SOURCES.json,供 NOTICE 与后续复查使用。
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, 'assets', 'icons', 'brands')

UA_BROWSER = {'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
                            '(KHTML, like Gecko) Chrome/124.0 Safari/537.36'}
UA_LOOKUP = {'User-Agent': 'daro-brand-fetch/1.0 (https://github.com/SpringHgui/daro)'}

def devicon(name):
    return ('https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/%s/%s-original.svg'
            % (name, name))


SIMPLE = 'https://cdn.simpleicons.org/%s'


def fetch(url, headers, tries=4):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=45) as r:
                return r.read()
        except (urllib.error.HTTPError, OSError) as e:
            code = getattr(e, 'code', None)
            if (code in (429, 403, 503) or code is None) and i < tries - 1:
                time.sleep(6 * (i + 1))
                continue
            raise
    raise RuntimeError('unreachable')


def commons_url(filename):
    """Commons 文件名 -> 原始直链(取规范名,避免手工拼哈希路径)。"""
    q = urllib.parse.urlencode({'action': 'query', 'titles': filename,
                                'prop': 'imageinfo', 'iiprop': 'url', 'format': 'json'})
    body = json.loads(fetch('https://commons.wikimedia.org/w/api.php?' + q, UA_LOOKUP).decode())
    page = next(iter(body['query']['pages'].values()))
    if 'imageinfo' not in page:
        raise RuntimeError('Commons 无此文件:%s' % filename)
    return page['imageinfo'][0]['url']


# 引擎 id -> (标的名, 候选 URL 列表(按优先级), 版权方)
TARGETS = {
    'mysql':       ('sakila 海豚', [devicon('mysql'), SIMPLE % 'mysql'], 'Oracle America, Inc.'),
    'postgresql':  ('Slonik 象头', [devicon('postgresql'), SIMPLE % 'postgresql'], 'PostgreSQL Global Development Group'),
    # devicon 的 microsoftsqlserver 是 3D 线框锥体，20px 下糊成一团；用官方 2025 版蓝色缎带 "S"
    'sqlserver':   ('2025 蓝色缎带 S',
                    ['commons:File:Microsoft_SQL_Server_2025_icon.svg', devicon('microsoftsqlserver')],
                    'Microsoft Corporation'),
    # 官方标识即"蓝色瓦片 + 羽毛笔"(鲸鲨只是 sqlite.org 的吉祥物，非 logo)
    'sqlite':      ('蓝色瓦片 + 羽毛笔', [devicon('sqlite'), SIMPLE % 'sqlite'], 'D. Richard Hipp / SQLite project'),
    'access':      ('Office Access 应用图标',
                    ['commons:File:Microsoft_Access_2013-2019_logo.svg', devicon('microsoftaccess')],
                    'Microsoft Corporation'),
    'mariadb':     ('海狮', [devicon('mariadb'), SIMPLE % 'mariadb'], 'MariaDB plc'),
    'oracle':      ('红色字标', [devicon('oracle'), SIMPLE % 'oracle'], 'Oracle Corporation'),
    'mongodb':     ('绿叶', [devicon('mongodb'), SIMPLE % 'mongodb'], 'MongoDB, Inc.'),
    'redis':       ('堆叠砖层', [devicon('redis'), SIMPLE % 'redis'], 'Redis Ltd.'),
    'snowflake':   ('六角雪花', [devicon('snowflake'), SIMPLE % 'snowflake'], 'Snowflake Inc.'),
}


def main():
    os.makedirs(OUT, exist_ok=True)
    picked = [a for a in sys.argv[1:] if not a.startswith('-')]
    unknown = [a for a in picked if a not in TARGETS]
    if unknown:
        print('未知引擎 id:', unknown, '| 可选:', sorted(TARGETS), file=sys.stderr)
        return 1
    targets = {k: TARGETS[k] for k in (picked or TARGETS)}

    sp = os.path.join(OUT, 'SOURCES.json')
    sources = {}
    if os.path.exists(sp):
        with open(sp, encoding='utf-8') as f:
            sources = json.load(f)
    for eid, (mark, cands, owner) in targets.items():
        rec = {'mark': mark, 'trademark_owner': owner, 'candidates': cands}
        data = None
        for c in cands:
            url = c
            try:
                url = commons_url(c.split(':', 1)[1]) if c.startswith('commons:') else c
                data = fetch(url, UA_BROWSER)
                rec['source_url'] = url
                break
            except Exception as e:
                rec.setdefault('failed', []).append('%s: %s %s' % (url, type(e).__name__, getattr(e, 'code', '')))
        if data is None:
            print('%-11s 全部候选失败 %s' % (eid, rec.get('failed')), file=sys.stderr)
            return 1
        text = data.decode('utf-8', 'replace')
        vb = re.search(r'viewBox="([^"]+)"', text)
        rec['viewBox'] = vb.group(1) if vb else '%sx%s' % (
            re.search(r'\bwidth="([\d.]+)', text).group(1), re.search(r'\bheight="([\d.]+)', text).group(1))
        rec['bytes'] = len(data)
        with open(os.path.join(OUT, '%s.svg' % eid), 'wb') as f:
            f.write(data)
        sources[eid] = rec
        time.sleep(2.5)  # 速率限制
        print('%-11s %6d B  viewBox=%-22s %s' % (eid, rec['bytes'], rec['viewBox'], rec['source_url']))
    with open(os.path.join(OUT, 'SOURCES.json'), 'w', encoding='utf-8') as f:
        json.dump(sources, f, ensure_ascii=False, indent=2, sort_keys=True)
    print('写出', len(sources), '个原件 ->', os.path.relpath(OUT, REPO))
    return 0


if __name__ == '__main__':
    sys.exit(main())
