#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 GitHub Release 正文：全部提交 + 关联 PR + Full Changelog 链接。

为什么需要它
------------
GitHub 自带的 `generate_release_notes` 只统计「经由 PR 合入的变更」。本仓库多数
提交是直接推到 master 的，于是 Release 正文里除了一行 Full Changelog 链接外
空无一物（见 0.3.1 Draft）。

本脚本改为以 git 提交为唯一准绳：
  1. 取上一个 tag → 当前 tag 的全部提交（默认排除 merge commit）；
  2. 按 Conventional Commits 前缀（feat/fix/chore…）归类成分节；
  3. 逐个提交反查 GitHub API，把它归属的 PR 编号 / 标题 / 作者补进来；
  4. 末尾补回 `**Full Changelog**: .../compare/<prev>...<tag>` 链接。

用法
----
    python3 tool/gen_release_notes.py --tag v0.3.1 --output release_body.md
    python3 tool/gen_release_notes.py --tag v0.3.1 --prev v0.3.0     # 显式指定区间
    python3 tool/gen_release_notes.py --tag v0.3.1 --no-pr           # 离线：跳过 PR 反查

参数（除 --tag 外均可省略）
    --tag      当前发布的 tag（默认取 GITHUB_REF_NAME，再退回 `git describe --tags`）
    --prev     上一个 tag；省略则用 `git describe --tags --abbrev=0 <tag>^` 自动推断，
               推断不到（首个 release）则用全量历史、且不输出 compare 链接
    --repo     owner/repo，默认取 GITHUB_REPOSITORY，再退回 origin 远程地址解析
    --output   写入的文件路径（UTF-8 / LF）；省略则打印到 stdout
    --token    GitHub token，默认取 GITHUB_TOKEN / GH_TOKEN；没有则走匿名查询（限流更低）
    --no-pr    完全不调用 GitHub API（PR 信息留空）

退出码
------
0  —— 生成成功。GitHub API 不可用时会打印告警并降级为「仅提交清单」，仍返回 0，
      以免 API 抖动把整个发布流水线卡死。
2  —— 参数或 git 仓库状态有问题（例如 tag 不存在）。此时应视为失败。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from typing import Dict, List, Optional, Tuple

FIELD = "\x1f"  # git pretty 里的字段分隔
RECORD = "\x1e"  # git pretty 里的记录分隔

API_ROOT = "https://api.github.com"

# Conventional Commits 前缀 → 分节标题（顺序即输出顺序，其余归入「其它变更」）
TYPE_GROUPS: List[Tuple[Tuple[str, ...], str]] = [
    (("feat", "feature"), "✨ 新功能"),
    (("fix", "bugfix", "hotfix"), "🐛 缺陷修复"),
    (("perf",), "⚡ 性能优化"),
    (("refactor",), "♻️ 代码重构"),
    (("docs",), "📝 文档"),
    (("test", "tests"), "✅ 测试"),
    (("build", "deps"), "📦 构建 / 依赖"),
    (("ci",), "👷 CI / 工作流"),
    (("style",), "💄 代码风格"),
    (("revert",), "⏪ 回滚"),
    (("chore",), "🔧 杂项"),
]
OTHER_HEADING = "📌 其它变更"

_CONVENTIONAL = re.compile(
    r"^(?P<type>[a-zA-Z]+)"
    r"(?:\((?P<scope>[^)]*)\))?"
    r"(?P<breaking>!)?"
    r":\s*(?P<desc>.*)$"
)


class Commit:
    def __init__(self, sha: str, short: str, author: str, date: str, subject: str) -> None:
        self.sha = sha
        self.short = short
        self.author = author
        self.date = date
        self.subject = subject

        # 解析 Conventional Commits，失败则原文进「其它变更」
        m = _CONVENTIONAL.match(subject)
        if m and m.group("desc").strip():
            self.type = m.group("type").lower()
            self.scope = (m.group("scope") or "").strip()
            self.desc = m.group("desc").strip()
            self.breaking = bool(m.group("breaking"))
        else:
            self.type = ""
            self.scope = ""
            self.desc = subject.strip()
            self.breaking = False

        self.pr = None  # type: Optional[Dict[str, object]]

    @property
    def display(self) -> str:
        """正文中展示的文案：有 scope 的前置加粗，便于一眼看出影响面。"""
        return "**({})** {}".format(self.scope, self.desc) if self.scope else self.desc


def _git(args: List[str], cwd: str, check: bool = True) -> str:
    proc = subprocess.run(
        ["git"] + args,
        cwd=cwd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            "git {} 失败（退出码 {}）：{}".format(
                " ".join(args), proc.returncode, (proc.stderr or "").strip()
            )
        )
    return proc.stdout or ""


def repo_root() -> str:
    """定位 git 仓库根。优先当前工作目录（CI 就是仓库根），
    否则退回脚本自身所在位置，这样在别的目录里调用也不会炸。"""
    candidates = [
        os.getcwd(),
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    ]
    for d in candidates:
        try:
            root = _git(["rev-parse", "--show-toplevel"], cwd=d).strip()
        except Exception:  # noqa: BLE001
            continue
        if root:
            return root
    raise RuntimeError("当前目录与脚本所在目录都不是 git 仓库，无法读取提交历史")


def resolve_tag(explicit: Optional[str], cwd: str) -> str:
    if explicit:
        tag = explicit.strip()
    else:
        tag = (os.environ.get("GITHUB_REF_NAME") or "").strip()
        if not tag:
            tag = _git(["describe", "--tags", "--abbrev=0"], cwd=cwd).strip()
    if not tag:
        raise RuntimeError("无法确定当前 tag，请显式传 --tag")

    # 校验 tag 是否真实存在于仓库中
    _git(["rev-parse", "--verify", "refs/tags/" + tag], cwd=cwd)
    return tag


def resolve_prev(tag: str, explicit: Optional[str], cwd: str) -> Optional[str]:
    if explicit is not None:
        prev = explicit.strip()
        if prev:
            _git(["rev-parse", "--verify", "refs/tags/" + prev], cwd=cwd)
            return prev
        return None
    out = _git(
        ["describe", "--tags", "--abbrev=0", tag + "^"], cwd=cwd, check=False
    ).strip()
    return out or None


def resolve_repo(explicit: Optional[str], cwd: str) -> str:
    if explicit:
        return explicit.strip()
    env = (os.environ.get("GITHUB_REPOSITORY") or "").strip()
    if env:
        return env
    url = _git(["remote", "get-url", "origin"], cwd=cwd, check=False).strip()
    m = re.search(r"github\.com[:/]+([^/]+)/([^/\s]+?)(?:\.git)?$", url)
    if m:
        return "{}/{}".format(m.group(1), m.group(2))
    return ""


def collect_commits(rev_range: str, cwd: str) -> List[Commit]:
    fmt = FIELD.join(["%H", "%h", "%an", "%aI", "%s"]) + RECORD
    out = _git(["log", "--no-merges", "--pretty=format:" + fmt, rev_range], cwd=cwd)

    commits = []  # type: List[Commit]
    for chunk in out.split(RECORD):
        chunk = chunk.strip("\n")
        if not chunk:
            continue
        parts = chunk.split(FIELD)
        if len(parts) != 5:
            continue
        commits.append(Commit(parts[0], parts[1], parts[2], parts[3], parts[4]))
    return commits


def fetch_pr(commit: Commit, repo: str, token: str, state: Dict[str, bool]) -> None:
    """反查提交归属的 PR。失败时只告警一次并整体停用查询，避免刷屏 / 浪费配额。"""
    if state.get("disabled"):
        return
    url = "{}/repos/{}/commits/{}/pulls".format(API_ROOT, repo, commit.sha)
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "daro-release-notes",
    }
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001 — 网络 / 鉴权问题一律降级
        if not state.get("warned"):
            print(
                "[gen_release_notes] 告警：GitHub API 查询失败（{}），"
                "本次 Release 正文将不含 PR 信息。".format(exc),
                file=sys.stderr,
            )
            state["warned"] = True
        state["disabled"] = True
        return

    if not isinstance(payload, list):
        return
    # 提交可能同时归属于多个 PR（例如被 cherry-pick），只展示编号最小的那个
    prs = [p for p in payload if isinstance(p, dict) and p.get("number")]
    if not prs:
        return
    prs.sort(key=lambda p: p.get("number") or 0)
    first = prs[0]
    user = first.get("user") or {}
    commit.pr = {
        "number": first.get("number"),
        "title": (first.get("title") or "").strip(),
        "url": first.get("html_url") or "",
        "login": (user.get("login") or "").strip(),
    }


def _title_for(ctype: str) -> str:
    for keys, heading in TYPE_GROUPS:
        if ctype in keys:
            return heading
    return OTHER_HEADING


def render(
    tag: str,
    prev: Optional[str],
    repo: str,
    commits: List[Commit],
    pr_lookup_ran: bool,
) -> str:
    lines = []  # type: List[str]
    lines.append("<!-- 自动生成：tool/gen_release_notes.py，请勿手工维护 -->")
    lines.append("")

    link = "https://github.com/{}".format(repo) if repo else ""
    prs = {}  # type: Dict[int, Dict[str, object]]
    for c in commits:
        if c.pr:
            prs.setdefault(int(c.pr["number"]), c.pr)

    summary = "本次发布包含 **{}** 个提交".format(len(commits))
    if pr_lookup_ran:
        summary += "、**{}** 个 Pull Request".format(len(prs))
    if prev:
        summary += "（`{}` → `{}`）".format(prev, tag)
    else:
        summary += "（首个发布，区间截至 `{}`）".format(tag)
    lines.append(summary + "。")
    lines.append("")

    breaking = [c for c in commits if c.breaking]

    # 按分节标题归类，保持 TYPE_GROUPS 的既定顺序
    buckets = {}  # type: Dict[str, List[Commit]]
    for c in commits:
        buckets.setdefault(_title_for(c.type), []).append(c)
    order = [h for _, h in TYPE_GROUPS if h in buckets]
    if OTHER_HEADING in buckets:
        order.append(OTHER_HEADING)

    if breaking:
        lines.append("### ⚠️ 破坏性变更")
        lines.append("")
        for c in breaking:
            lines.append("- " + _render_commit(c, link))
        lines.append("")

    for heading in order:
        lines.append("### " + heading)
        lines.append("")
        for c in buckets[heading]:
            lines.append("- " + _render_commit(c, link))
        lines.append("")

    if prs:
        lines.append("### 🔀 合并的 Pull Request")
        lines.append("")
        for number in sorted(prs):
            pr = prs[number]
            title = pr["title"] or "(无标题)"
            suffix = " · @{}".format(pr["login"]) if pr["login"] else ""
            lines.append("- [#{}]({}) {}{}".format(number, pr["url"], title, suffix))
        lines.append("")

    authors = []  # type: List[str]
    for c in commits:
        if c.author and c.author not in authors:
            authors.append(c.author)
    if authors:
        lines.append("贡献者：" + "、".join(authors))
        lines.append("")

    if prev and link:
        lines.append("**Full Changelog**: {}/compare/{}...{}".format(link, prev, tag))
        lines.append("")
    elif link:
        lines.append("**Full Changelog**: {}/commits/{}".format(link, tag))
        lines.append("")

    return "\n".join(lines).rstrip("\n") + "\n"


def _render_commit(c: Commit, link: str) -> str:
    parts = [c.display]
    if link:
        parts.append("[`{}`]({}/commit/{})".format(c.short, link, c.sha))
    else:
        parts.append("`{}`".format(c.short))
    if c.author:
        parts.append(c.author)
    if c.pr:
        parts.append("[#{}]({})".format(c.pr["number"], c.pr["url"]))
    return " · ".join(parts)


def parse_args(argv: List[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="生成 GitHub Release 正文（提交清单 + 关联 PR + Full Changelog）",
    )
    p.add_argument("--tag", help="当前发布的 tag，默认 GITHUB_REF_NAME 或 git describe")
    p.add_argument("--prev", help="上一个 tag；默认自动推断，传空串表示按首个发布处理")
    p.add_argument("--repo", help="owner/repo，默认 GITHUB_REPOSITORY 或 origin 地址")
    p.add_argument("--output", help="输出文件路径（UTF-8 / LF）；省略则打到 stdout")
    p.add_argument("--token", help="GitHub token，默认 GITHUB_TOKEN / GH_TOKEN")
    p.add_argument("--no-pr", action="store_true", help="跳过 GitHub API，正文不含 PR 信息")
    return p.parse_args(argv)


def main(argv: List[str]) -> int:
    # Windows 控制台默认用 ANSI/OEM 代码页，这里统一成 UTF-8，避免中文 print 崩掉
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:  # noqa: BLE001
                pass

    args = parse_args(argv)

    try:
        cwd = repo_root()
        tag = resolve_tag(args.tag, cwd)
        prev = resolve_prev(tag, args.prev, cwd)
    except Exception as exc:  # noqa: BLE001
        print("[gen_release_notes] 错误：{}".format(exc), file=sys.stderr)
        return 2

    repo = resolve_repo(args.repo, cwd)
    rev_range = "{}..{}".format(prev, tag) if prev else tag
    commits = collect_commits(rev_range, cwd)

    token = (args.token or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or "").strip()
    pr_lookup_ran = False
    if args.no_pr:
        print("[gen_release_notes] 已按 --no-pr 跳过 PR 反查。", file=sys.stderr)
    elif not repo:
        print(
            "[gen_release_notes] 告警：无法确定 owner/repo，本次正文不含 PR 信息。",
            file=sys.stderr,
        )
    else:
        pr_lookup_ran = True
        if not token:
            # 公开仓库允许匿名调用，只是配额低（60 次/小时）；失败会自动降级
            print(
                "[gen_release_notes] 提示：未提供 token（--token / GITHUB_TOKEN），"
                "将以匿名方式查询 PR，可能受接口限流影响。",
                file=sys.stderr,
            )
        state = {}  # type: Dict[str, bool]
        for c in commits:
            fetch_pr(c, repo, token, state)

    body = render(tag, prev, repo, commits, pr_lookup_ran)

    if args.output:
        with open(args.output, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)
        print(
            "[gen_release_notes] 已写入 {}（{} → {}，{} 个提交）。".format(
                args.output, prev or "(首个发布)", tag, len(commits)
            )
        )
    else:
        sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
