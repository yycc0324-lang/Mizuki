#!/usr/bin/env python3
"""
首屏传输量测量（优化前后对比用）

设计要点：
  - 不新增项目依赖：用系统 Python + Playwright + 本机 Chrome（channel="chrome"）
  - 脚本自带一个「贴近线上 nginx 配置」的静态服务器（gzip on / comp_level 5 / 同样的 gzip_types），
    这样 transferSize 才有可比性（`astro preview` 不做压缩，会低估线上表现）
  - 采集：按类型汇总传输字节、资源清单、LCP/FCP/CLS、主线程长任务、关键元素出现时刻

前置：
  pnpm build                      # 生成 dist
  python3 -c "import playwright"  # 需要 Playwright（本机已装：/opt/homebrew/bin/playwright）

用法：
  python3 scripts/measure-first-load.py --dist dist --tag before
  python3 scripts/measure-first-load.py --url http://localhost:4399 --tag after
"""

import argparse
import gzip
import io
import json
import os
import socket
import threading
import time
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

from playwright.sync_api import sync_playwright

# 与 docs/nginx/baota.conf 的压缩配置保持一致
GZIP_TYPES = {
    "text/plain",
    "text/css",
    "text/html",
    "application/javascript",
    "application/json",
    "image/svg+xml",
    "application/xml",
    "application/rss+xml",
}
GZIP_MIN_LENGTH = 1024
GZIP_LEVEL = 5

VIEWPORTS = {
    "desktop": {
        "viewport": {"width": 1440, "height": 900},
        "device_scale_factor": 2,
        "is_mobile": False,
        "user_agent": None,
    },
    "mobile": {
        "viewport": {"width": 390, "height": 844},
        "device_scale_factor": 3,
        "is_mobile": True,
        "user_agent": (
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        ),
    },
}

# 在页面里安装观测器（越早越好）
INIT_SCRIPT = """
window.__m = { lcp: 0, fcp: 0, cls: 0, longTasks: [], marks: {} };
try {
  new PerformanceObserver((l) => {
    for (const e of l.getEntries()) window.__m.lcp = e.startTime;
  }).observe({ type: "largest-contentful-paint", buffered: true });
  new PerformanceObserver((l) => {
    for (const e of l.getEntries())
      if (!e.hadRecentInput) window.__m.cls += e.value;
  }).observe({ type: "layout-shift", buffered: true });
  new PerformanceObserver((l) => {
    for (const e of l.getEntries()) window.__m.longTasks.push(e.duration);
  }).observe({ type: "longtask", buffered: true });
  new PerformanceObserver((l) => {
    for (const e of l.getEntries())
      if (e.name === "first-contentful-paint") window.__m.fcp = e.startTime;
  }).observe({ type: "paint", buffered: true });
} catch (e) {}
// 关键元素出现时刻
const watch = {
  banner_img: () => document.querySelector('#banner-wrapper img'),
  rainy_banner: () => document.getElementById('rainy-window'),
  rainy_viewport: () => document.getElementById('rainy-window-fullscreen'),
};
const t0 = performance.now();
const poll = setInterval(() => {
  for (const [k, fn] of Object.entries(watch)) {
    if (window.__m.marks[k] === undefined && fn()) window.__m.marks[k] = performance.now() - t0;
  }
}, 50);
window.addEventListener('load', () => { window.__m.loadAt = performance.now(); }, { once: true });
"""

COLLECT_JS = """
() => {
  const res = performance.getEntriesByType("resource").map((r) => ({
    name: r.name,
    type: r.initiatorType,
    transfer: r.transferSize,
    encoded: r.encodedBodySize,
    start: Math.round(r.startTime),
  }));
  const nav = performance.getEntriesByType("navigation")[0];
  return {
    metrics: window.__m,
    resources: res,
    nav: nav
      ? {
          domContentLoaded: Math.round(nav.domContentLoadedEventEnd),
          loadEvent: Math.round(nav.loadEventEnd),
          transfer: nav.transferSize,
          encoded: nav.encodedBodySize,
        }
      : null,
    imgInDom: Array.from(document.querySelectorAll("#banner-wrapper img")).map((i) => i.currentSrc || i.src),
  };
}
"""


class GzipHandler(SimpleHTTPRequestHandler):
    """静态服务器 + 与线上 nginx 一致的 gzip 行为"""

    def log_message(self, *args):  # 静音
        pass

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            path = os.path.join(path, "index.html")
        if not os.path.isfile(path):
            self.send_error(404, "Not found")
            return None
        try:
            with open(path, "rb") as fh:
                body = fh.read()
        except OSError:
            self.send_error(404, "Not found")
            return None

        ctype = self.guess_type(path)
        accept = self.headers.get("Accept-Encoding", "")
        # 缓存策略与 docs/nginx/baota.conf 对齐，否则轮播换帧会重复下载图片，基线会虚高
        if path.startswith("/_astro/"):
            cache = "public, max-age=31536000, immutable"
        elif path.startswith(("/assets/", "/images/", "/pio/", "/js/")):
            cache = "public, max-age=2592000"
        elif path.startswith("/pagefind/"):
            cache = "public, max-age=604800"
        elif ctype.startswith("text/html"):
            cache = "no-cache"
        else:
            cache = "public, max-age=604800"
        headers = [("Content-Type", ctype), ("Cache-Control", cache)]
        if (
            "gzip" in accept
            and ctype in GZIP_TYPES
            and len(body) >= GZIP_MIN_LENGTH
        ):
            buf = io.BytesIO()
            with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=GZIP_LEVEL) as gz:
                gz.write(body)
            body = buf.getvalue()
            headers.append(("Content-Encoding", "gzip"))
            headers.append(("Vary", "Accept-Encoding"))
        headers.append(("Content-Length", str(len(body))))
        self.send_response(200)
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        return io.BytesIO(body)


def serve(dist: str, port: int) -> ThreadingHTTPServer:
    handler = partial(GzipHandler, directory=dist)
    httpd = ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

IMAGE_EXT = (".webp", ".png", ".jpg", ".jpeg", ".avif", ".gif", ".svg", ".ico")
FONT_EXT = (".woff2", ".woff", ".ttf", ".otf")


def classify(url: str) -> str:
    path = url.split("?")[0].lower()
    if path.endswith(IMAGE_EXT):
        return "image"
    if path.endswith(".js"):
        return "js"
    if path.endswith(".css"):
        return "css"
    if path.endswith(FONT_EXT):
        return "font"
    if path.endswith(".html") or path.endswith("/"):
        return "html"
    return "other"


def kb(n) -> str:
    return f"{int(n) / 1024:.0f}K" if n else "0"


def summarize(data: dict, viewport: str) -> dict:
    resources = data["resources"]
    totals: dict = {}
    for r in resources:
        kind = classify(r["name"])
        slot = totals.setdefault(kind, {"count": 0, "transfer": 0})
        slot["count"] += 1
        slot["transfer"] += r["transfer"]

    wasted = []
    for r in resources:
        if classify(r["name"]) != "image":
            continue
        if viewport == "desktop" and "/mobile-banner/" in r["name"]:
            wasted.append(r)
        if viewport == "mobile" and "/desktop-banner/" in r["name"]:
            wasted.append(r)

    m = data["metrics"]
    long_tasks = m.get("longTasks", [])
    js = sorted(
        [r for r in resources if classify(r["name"]) == "js"],
        key=lambda r: -r["transfer"],
    )
    images = sorted(
        [r for r in resources if classify(r["name"]) == "image"],
        key=lambda r: -r["transfer"],
    )
    top = sorted(resources, key=lambda r: -r["transfer"])[:12]

    return {
        "viewport": viewport,
        "metrics": {
            "fcp": round(m.get("fcp", 0)),
            "lcp": round(m.get("lcp", 0)),
            "cls": round(m.get("cls", 0), 4),
            "loadAt": round(m.get("loadAt", 0)),
            "longTaskCount": len(long_tasks),
            "longTaskTotalMs": round(sum(long_tasks)),
            "longTaskMaxMs": round(max(long_tasks)) if long_tasks else 0,
            "marks": {k: round(v) for k, v in (m.get("marks") or {}).items()},
        },
        "nav": data["nav"],
        "totals": totals,
        "grandTotal": sum(v["transfer"] for v in totals.values()),
        "images": images,
        "js": js,
        "wastedImages": wasted,
        "top": top,
    }


def print_report(rep: dict) -> None:
    print(f"\n{'=' * 72}\n【{rep['viewport']}】首屏测量")
    m = rep["metrics"]
    print(
        f"  FCP {m['fcp']}ms | LCP {m['lcp']}ms | CLS {m['cls']} | load {m['loadAt']}ms"
        f" | 长任务 {m['longTaskCount']} 个 / 共 {m['longTaskTotalMs']}ms（最长 {m['longTaskMaxMs']}ms）"
    )
    marks = m.get("marks") or {}
    print(
        "  元素出现时刻：banner 图 "
        f"{marks.get('banner_img', '未出现')}ms | 雨(横幅) {marks.get('rainy_banner', '未出现')}ms"
        f" | 雨(征文区) {marks.get('rainy_viewport', '未出现')}ms"
    )
    print(f"  传输合计 {kb(rep['grandTotal'])}")
    print("  按类型：")
    for kind, v in sorted(rep["totals"].items(), key=lambda kv: -kv[1]["transfer"]):
        print(f"    {kind:6} {v['count']:3} 项  {kb(v['transfer']):>7}")
    print("  最大的 5 个 JS：")
    for r in rep["js"][:5]:
        print(
            f"    {kb(r['transfer']):>7}  起始 {r['start']:>6}ms  "
            f"{r['name'].split('/')[-1][:48]}"
        )
    print("  图片（按体积）：")
    wasted_names = {id(r) for r in rep["wastedImages"]}
    for r in rep["images"][:8]:
        flag = " ← 本端用不到" if id(r) in wasted_names else ""
        print(
            f"    {kb(r['transfer']):>7}  起始 {r['start']:>6}ms  "
            f"{r['name'].split('/')[-1][:44]}{flag}"
        )
    if rep["wastedImages"]:
        total = sum(r["transfer"] for r in rep["wastedImages"])
        print(f"  ⚠ 本端用不到的图片：{len(rep['wastedImages'])} 项 / {kb(total)}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", help="直接测量已运行的站点（优先）")
    ap.add_argument("--dist", help="dist 目录（脚本自起静态服务器，类 nginx gzip）")
    ap.add_argument("--tag", default="run", help="标签，输出 reports/first-load-<tag>.json")
    ap.add_argument("--settle-ms", type=int, default=6000, help="load 后再等多久（捕捉延后加载）")
    ap.add_argument("--viewports", default="desktop,mobile")
    args = ap.parse_args()

    httpd = None
    if args.url:
        base = args.url.rstrip("/") + "/"
    elif args.dist:
        port = free_port()
        httpd = serve(args.dist, port)
        base = f"http://127.0.0.1:{port}/"
        time.sleep(0.5)
    else:
        ap.error("需要 --url 或 --dist")

    results = []
    external_hits: list[str] = []
    with sync_playwright() as p:
        browser = p.chromium.launch(
            channel="chrome",
            headless=True,
            args=[
                "--enable-unsafe-swiftshader",
                "--use-angle=swiftshader",
                # 外网域名一律解析到黑洞端口（快速失败，不挂起），
                # 且**不用** Playwright 的 route 拦截 —— 拦截会让 Chrome 绕过 HTTP 缓存，
                # 从而把"缓存命中"误判成"重复下载"。
                "--host-resolver-rules=MAP * 127.0.0.1:1, EXCLUDE localhost, EXCLUDE 127.0.0.1",
            ],
        )
        for name in args.viewports.split(","):
            cfg = VIEWPORTS[name.strip()]
            ctx = browser.new_context(
                viewport=cfg["viewport"],
                device_scale_factor=cfg["device_scale_factor"],
                is_mobile=cfg["is_mobile"],
                user_agent=cfg["user_agent"],
            )
            page = ctx.new_page()
            page.add_init_script(INIT_SCRIPT)
            # 固定随机起始帧，保证多次测量可复现（轮播默认随机选首帧）
            page.add_init_script("Math.random = () => 0.42;")

            def on_request(req, _base=base, _sink=external_hits):
                if not req.url.startswith(_base) and not req.url.startswith(
                    ("data:", "blob:")
                ):
                    _sink.append(req.url)

            page.on("request", on_request)
            try:
                page.goto(base, wait_until="load", timeout=45000)
            except Exception as exc:  # load 未触发也继续，用固定等待兜底
                print(f"  ({name}: load 事件未在 45s 内触发 - {type(exc).__name__}，改用固定等待)")
            page.wait_for_timeout(args.settle_ms)
            data = page.evaluate(COLLECT_JS)
            ctx.close()
            rep = summarize(data, name.strip())
            rep["url"] = base
            results.append(rep)
            print_report(rep)
        browser.close()
        if external_hits:
            uniq = sorted(set(external_hits))
            print(f"\n⚠ 页面尝试请求的第三方地址（本机无外网，已快速失败）：{len(uniq)} 个")
            for u in uniq[:8]:
                print(f"    {u[:100]}")

    if httpd:
        httpd.shutdown()

    out_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "reports"
    )
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"first-load-{args.tag}.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(
            {"tag": args.tag, "url": base, "results": results},
            fh,
            ensure_ascii=False,
            indent=2,
        )
    print(f"\n结果已写入 {out}")


if __name__ == "__main__":
    main()

