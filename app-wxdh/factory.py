#!/usr/bin/env python3
"""factory.py — App 工厂命令行

用法：
  python3 factory.py list                  列出所有注册产品
  python3 factory.py show --app <id>       查看产品定义
  python3 factory.py build --app <id>      构建产品（xcodegen + xcodebuild）
  python3 factory.py packet --file <path>  用构建包（definition packet JSON）构建产品
"""

import argparse
import datetime
import html as html_mod
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
APPS_DIR = ROOT / "Apps"


# ---------------------------------------------------------------------------
# 极简 YAML 解析：支持工厂 App.yml 的两级嵌套 map + 标量 + 注释
# （避免依赖 PyYAML；字段增加时注意保持该子集）
# ---------------------------------------------------------------------------

def parse_app_yml(path: pathlib.Path) -> dict:
    root: dict = {}
    stack: list[tuple[int, dict]] = [(-1, root)]
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        key, sep, value = line.strip().partition(":")
        if not sep:
            continue
        key, value = key.strip(), value.strip()
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if value == "":
            child: dict = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = parse_scalar(value)
    return root


def parse_scalar(value: str):
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [parse_scalar(item.strip()) for item in inner.split(",")]
    if value.lower() in ("true", "yes"):
        return True
    if value.lower() in ("false", "no"):
        return False
    try:
        return int(value)
    except ValueError:
        pass
    try:
        return float(value)
    except ValueError:
        pass
    return value.strip('"\'')


def _from_definition_json(defn: dict) -> dict:
    """把全保真 definition.json 归一成 build_spec/cmd_* 期望的形状（含合成 app 键）。
    App.yml 极简解析器不支持对象数组，复杂段（support.feedback.fields 等）只走本路径。"""
    ident = defn.get("identity", {}) or {}
    brand = defn.get("brand", {}) or {}
    factory = defn.get("factory", {}) or {}
    app = {
        "id": ident.get("id", ""), "name": ident.get("name", ""),
        "bundle_id": ident.get("bundle_id", ""), "version": ident.get("version", "1.0.0"),
        "build": int(ident.get("build", 1) or 1), "type": ident.get("type", "content_app"),
        "accent": brand.get("accent", ""), "plus_name": brand.get("plus_name", "Plus"),
        "theme_pack": brand.get("theme_pack", ""), "scheme": factory.get("scheme"),
        "project": factory.get("project"),
    }
    out = {"app": app}
    for k, v in defn.items():           # 其余段（monetization/compliance/support/...）原样透传
        if k not in ("identity", "brand", "factory"):
            out[k] = v
    return out


def load_app(app_id: str) -> dict:
    base = APPS_DIR / app_id
    jf = base / "definition.json"
    if jf.exists():                      # 全保真优先（含 support/legal 等复杂段）
        return _from_definition_json(json.loads(jf.read_text(encoding="utf-8")))
    yml = base / "App.yml"
    if not yml.exists():
        sys.exit(f"产品未注册: {app_id}（{yml} 不存在）")
    return parse_app_yml(yml)            # 兜底：手写/旧包（无复杂段）


def all_apps() -> list[str]:
    if not APPS_DIR.exists():
        return []
    return sorted(p.name for p in APPS_DIR.iterdir()
                  if p.is_dir() and (p / "App.yml").exists())


# ---------------------------------------------------------------------------
# 命令
# ---------------------------------------------------------------------------

def cmd_list(_args):
    apps = all_apps()
    if not apps:
        print("还没有注册产品（Apps/ 为空）")
        return
    print(f"{'id':<16}{'名称':<10}{'bundle_id':<32}{'版本':<8}{'主色'}")
    print("-" * 78)
    for app_id in apps:
        d = load_app(app_id)["app"]
        print(f"{app_id:<16}{d['name']:<10}{d['bundle_id']:<32}"
              f"{d['version']:<8}#{d.get('accent', '-')}")


def cmd_show(args):
    import json
    print(json.dumps(load_app(args.app), ensure_ascii=False, indent=2))


def run(cmd: list[str], cwd: pathlib.Path):
    print(f"$ {' '.join(cmd)}")
    p = subprocess.run(cmd, cwd=cwd)
    if p.returncode != 0:
        sys.exit(p.returncode)


def _inject_icon(uploads_dir: pathlib.Path, project_root: pathlib.Path):
    """从 uploads_dir 找 icon.* 生成 Assets.xcassets/AppIcon.appiconset 到工程内

    苹果要求 AppIcon 是 1024×1024；非 1024 或非正方形时用 PIL 自动处理：
    - 非正方形：居中裁正方形
    - 尺寸≠1024：缩放到 1024×1024
    PIL 不可用或处理失败则跳过（用母工程预置占位 AppIcon，不阻塞构建）。
    """
    icon_file = None
    for ext in (".png", ".jpg", ".jpeg"):
        cand = uploads_dir / f"icon{ext}"
        if cand.exists():
            icon_file = cand
            break
    if not icon_file:
        return False
    try:
        from PIL import Image
        img = Image.open(icon_file).convert("RGBA")
        w, h = img.size
        # 非正方形：居中裁正方形
        if w != h:
            side = min(w, h)
            left = (w - side) // 2
            top = (h - side) // 2
            img = img.crop((left, top, left + side, top + side))
            print(f"  ℹ icon 非正方形 {w}×{h}，已居中裁为 {side}×{side}")
        # 缩放到 1024×1024
        if img.size != (1024, 1024):
            img = img.resize((1024, 1024), Image.LANCZOS)
            print(f"  ℹ icon 已缩放到 1024×1024（原 {w}×{h}）")
    except ImportError:
        print("  ⚠ 未安装 Pillow，无法处理 icon 尺寸，跳过注入")
        return False
    except Exception as e:
        print(f"  ⚠ icon 处理失败：{e}，跳过注入")
        return False
    xcassets = project_root / "Resources" / "Assets.xcassets"
    appiconset = xcassets / "AppIcon.appiconset"
    appiconset.mkdir(parents=True, exist_ok=True)
    img.save(appiconset / "icon.png", "PNG")
    (appiconset / "Contents.json").write_text(json.dumps({
        "images": [{"idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon.png"}],
        "info": {"author": "xcode", "version": 1},
    }), encoding="utf-8")
    root_contents = xcassets / "Contents.json"
    if not root_contents.exists():
        root_contents.write_text('{"info":{"author":"xcode","version":1}}', encoding="utf-8")
    return True


def _inject_assets(uploads_dir: pathlib.Path, assets_out: pathlib.Path):
    """拷贝开机物料（splash 图/视频、guide-N、paywall-bg）到工程 Resources/assets/，跳过 icon（icon 走 _inject_icon）"""
    import shutil
    assets_out.mkdir(parents=True, exist_ok=True)
    for f in sorted(uploads_dir.iterdir()):
        if not f.is_file() or f.suffix.lower() not in (".png", ".jpg", ".jpeg", ".webp", ".mp4", ".gif"):
            continue
        if f.name.lower().startswith("icon."):
            continue                # icon 走 AppIcon 注入
        shutil.copy2(f, assets_out / f.name)


def do_build(d: dict, device: bool, project_dir: pathlib.Path):
    """执行 xcodegen + xcodebuild 构建（build 与 packet 子命令共用）"""
    if not project_dir.exists():
        sys.exit(f"工程不存在: {project_dir}")
    if (project_dir / "project.yml").exists():
        run(["xcodegen"], cwd=project_dir)
    scheme = d.get("scheme") or d["name"]
    destination = ("generic/platform=iOS" if device
                   else "generic/platform=iOS Simulator")
    # derivedDataPath 放工程内，让产物路径可预测：<project>/DerivedData/Build/Products/...
    derived = project_dir / "DerivedData"
    run(["xcodebuild", "-project", f"{scheme}.xcodeproj",
         "-scheme", scheme, "-destination", destination,
         "-configuration", "Debug",
         "-derivedDataPath", str(derived), "build"], cwd=project_dir)
    print(f"\n构建完成: {d['name']} ({d['bundle_id']})")


def cmd_build(args):
    d = load_app(args.app)["app"]
    do_build(d, args.device, (APPS_DIR / args.app / d["project"]).resolve())


def cmd_packet(args):
    """读 definition packet（自包含 JSON），打印定义摘要后走现有 build 流程"""
    packet_path = pathlib.Path(args.file).expanduser().resolve()
    if not packet_path.exists():
        sys.exit(f"packet 不存在: {packet_path}")
    packet = json.loads(packet_path.read_text(encoding="utf-8"))
    defn = packet.get("definition") or {}
    ident = defn.get("identity") or {}
    app_id = packet.get("app_id") or ident.get("id") or "unknown"

    # 定义摘要
    brand = defn.get("brand") or {}
    feats = defn.get("features") or {}
    mon = defn.get("monetization") or {}
    print(f"packet: {packet_path.name}（factory_version: {packet.get('factory_version', '?')}）")
    print(f"产品: {ident.get('name', '?')} ({app_id})  bundle_id: {ident.get('bundle_id', '?')}")
    print(f"版本: {ident.get('version', '?')} (build {ident.get('build', '?')})"
          f"  主色: #{brand.get('accent', '-')}")
    print(f"插件: {', '.join(k for k, v in feats.items() if v) or '无'}")
    print(f"定价: 首期 {mon.get('weekly_intro', '?')} 元/周，"
          f"续费 {mon.get('weekly_renew', '?')} 元/周")
    print()

    # 还原 build 流程需要的 app 段，并解析工程路径（相对 packet 所在仓库根）
    factory_info = defn.get("factory") or {}
    d = {**ident, "accent": brand.get("accent", ""),
         "scheme": factory_info.get("scheme"),
         "project": factory_info.get("project")}
    if not d.get("project"):
        sys.exit("packet 缺少工程路径（definition.factory.project）")
    candidates = [
        (APPS_DIR / app_id / d["project"]).resolve(),   # 与 App.yml 语义一致：相对 Apps/<id>/
        (packet_path.parent / d["project"]).resolve(),  # 兜底：相对 packet 所在目录
    ]
    project_dir = next((c for c in candidates if c.exists()), candidates[0])

    # packet 同目录的 assets/ 文件夹（离线构建机配套传物料；有则注入工程）
    packet_assets = packet_path.parent / "assets"
    if packet_assets.exists():
        _inject_assets(packet_assets, project_dir / "Resources" / "assets")
        if _inject_icon(packet_assets, project_dir):
            print(f"  ✓ App Icon 已注入（来自 packet 同目录 assets/icon.*）")

    do_build(d, args.device, project_dir)


# ---------------------------------------------------------------------------
# assemble：复制母工程 → 按说明书装配 → 构建出包
# ---------------------------------------------------------------------------

FACTORY_CORE = ROOT / "FactoryCore"
BUILD_DIR = ROOT / "build"

# ---------------------------------------------------------------------------
# 协议正文兜底（compliance.legal 三重兜底：definition 正文 → uploads 生效版 → 模板渲染）
# 不 import server 包（CLI 仅 stdlib）；与 server/generators.py render_legal 同读
# server/legal_templates/ 单一模板源。变量表是 server legal_vars 的子集——只覆盖
# privacy/terms 两个模板实际用到的占位符（见模板内 {{var}}）。
# ---------------------------------------------------------------------------

SERVER_UPLOADS_DIR = ROOT / "server" / "uploads"
LEGAL_TEMPLATES_DIR = ROOT / "server" / "legal_templates"
LEGAL_TITLES = {"privacy": "隐私政策", "terms": "用户协议"}

_LEGAL_SHELL = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} - {name}</title>
<style>
  body {{ margin:0; font-family:-apple-system,"PingFang SC",sans-serif; background:#f6f7f9; color:#222; line-height:1.75; }}
  main {{ max-width:760px; margin:0 auto; padding:28px 20px 60px; background:#fff; min-height:100vh; }}
  h1 {{ font-size:22px; }} h2 {{ font-size:16px; margin-top:28px; }}
  table {{ width:100%; border-collapse:collapse; font-size:14px; margin:10px 0; }}
  th,td {{ border:1px solid #dfe3ea; padding:8px 10px; text-align:left; vertical-align:top; }}
  th {{ background:#f2f4f8; }}
  .meta {{ color:#889; font-size:13px; }}
  .banner {{ background:#fdf3e3; color:#b9770e; font-size:13px; padding:8px 20px; text-align:center; }}
</style>
</head>
<body>
<div class="banner">本文档由模板自动生成，上架前需法务审核确认</div>
<main>
{body}
</main>
</body>
</html>
"""


def _legal_vars(definition: dict) -> dict:
    """privacy/terms 模板占位符变量表（server legal_vars 子集 + 同名同义）"""
    ident = definition.get("identity") or definition.get("app") or {}
    comp = definition.get("compliance", {})
    mon = definition.get("monetization", {})
    brand = definition.get("brand") or {}
    esc = html_mod.escape
    company = comp.get("company_name") or "【公司/主体名称待补充】"
    email = comp.get("contact_email") or comp.get("support_email") or "【联系邮箱待补充】"
    icp = comp.get("icp") or ""
    plus_name = brand.get("plus_name") or ident.get("plus_name") or "Plus"
    return {
        "name": esc(str(ident.get("name", ""))),
        "version": esc(str(ident.get("version", ""))),
        "bundle_id": esc(str(ident.get("bundle_id", ""))),
        "age_rating": esc(str(ident.get("age_rating", "4+"))),
        "company_name": esc(company),
        "contact_email": esc(email),
        "address": esc(str(comp.get("address", ""))),
        "icp": esc(icp),
        "icp_text": esc(f"备案号：{icp}" if icp else "（ICP 备案号待回填）"),
        "update_date": datetime.date.today().isoformat(),
        "plus_name": esc(plus_name),
        "weekly_intro": esc(str(mon.get("weekly_intro", 0))),
        "weekly_renew": esc(str(mon.get("weekly_renew", 0))),
        "trial_days": esc(str(mon.get("trial_days", 0))),
        "strategy": mon.get("strategy") or "intro_price",
        # privacy/terms 模板不含 pii/sdk 表占位符，给空串防残留
        "pii_rows": "", "sdk_rows": "",
    }


def render_legal_fallback(definition: dict, doc: str) -> str:
    """模板实时渲染协议正文（server render_legal 的 stdlib 版）；失败返回 "" """
    tpl = LEGAL_TEMPLATES_DIR / f"{doc}.html"
    if not tpl.exists():
        print(f"  ⚠ 协议模板缺失: {tpl}", file=sys.stderr)
        return ""
    try:
        body = tpl.read_text(encoding="utf-8")
        variables = _legal_vars(definition)
        for key, value in variables.items():
            body = body.replace("{{" + key + "}}", str(value))
        return _LEGAL_SHELL.format(
            title=LEGAL_TITLES.get(doc, doc), name=variables["name"], body=body)
    except Exception as e:
        print(f"  ⚠ 协议模板渲染失败（{doc}）: {e}", file=sys.stderr)
        return ""


def _legal_html(definition: dict, doc: str) -> tuple[str, str]:
    """三重兜底取协议正文：definition 正文 → uploads 生效版 → 模板渲染。
    返回 (html, source)；html 空串 = iOS 回退外链。"""
    legal = (definition.get("compliance") or {}).get("legal") or {}
    doc_cfg = legal.get(doc) or {}
    # 1) definition 已带正文（中控台保存时写入或 packet 自带）
    if doc_cfg.get("html"):
        return doc_cfg["html"], doc_cfg.get("source") or "uploaded"
    # 2) uploads/<slug>/legal/{doc}.html 生效版（上传/AI 采纳）——与 server get_legal_html
    #    同门槛：legal_sources[doc] ∈ {uploaded, ai} 才读生效版，标签与内容不漂移。
    #    slug = Apps/<id> 目录名；definition 由 load_app 读入时 app.id 即产品代号，
    #    uploads 目录用 slug（首次创建锁定），cmd_assemble 传给本函数时由调用方解析
    slug = definition.get("_slug") or (definition.get("app") or {}).get("id") or ""
    eff = SERVER_UPLOADS_DIR / slug / "legal" / f"{doc}.html"
    src = (definition.get("compliance") or {}).get("legal_sources") or {}
    if src.get(doc) in ("uploaded", "ai") and eff.exists():
        try:
            text = eff.read_text(encoding="utf-8", errors="replace")
            if text.strip():
                return text, src[doc]
        except Exception:
            pass
    # 3) 模板实时渲染
    html = render_legal_fallback(definition, doc)
    return html, ("template" if html else "")


def _normalize_paywall_copy(pc: dict | None) -> dict:
    """paywall_copy 归一：bullets→features 改名、空文案回落默认、按钮文字/开关透传。

    Swift AppSpec.PaywallCopy 的 welcome/features 是非可选 key，缺失会让整个
    spec.json 解码失败（fatalError），所以形状必须在这里保证；
    定义侧（console/definition.json）用的是 bullets，改名历史上只在 App.yml 渲染做，
    definition.json 优先路径漏掉了，此函数补齐两条路径。"""
    pc = pc or {}
    out = {
        "welcome": pc.get("welcome") or "解锁全部会员内容",
        "features": (pc.get("features") or pc.get("bullets")
                     or ["全部内容", "专属功能", "无广告", "持续更新"]),
    }
    if pc.get("button_label"):
        out["button_label"] = pc["button_label"]
    for k in ("show_privacy", "show_terms", "show_restore"):
        if k in pc:
            out[k] = pc[k]
    return out


def build_spec(definition: dict) -> dict:
    """把产品定义（App.yml）转成母工程消费的 spec.json"""
    import time
    a = definition["app"]
    m = definition.get("monetization", {})
    c = definition.get("compliance", {})
    features = definition.get("features", {})
    # 选配插件：features 里为 true/字典 的项（标配组件不进 plugins）
    plugins = [{"id": pid, "config": (enabled if isinstance(enabled, dict) else {})}
               for pid, enabled in features.items()
               if enabled and pid not in ("paywall", "settings_kit", "review_kit")]
    return {
        "revision": int(time.time()),   # 装配版本号（每次 assemble 不同；引导页据此重置）
        "identity": {
            "id": a["id"], "name": a["name"],
            "bundle_id": a["bundle_id"],
            "version": str(a.get("version", "1.0.0")),
            "build": int(a.get("build", 1)),
        },
        "brand": {
            "accent": a.get("accent", "FF87C5"),
            "plus_name": a.get("plus_name", "Plus"),
            "theme_pack": a.get("theme_pack", "lavender"),
        },
        "plugins": plugins,
        "content": definition.get("content", {"catalog": "bundle"}),
        "onboarding": definition.get("onboarding", {}),   # 开机三件套物料（splash/pages/paywall_bg）
        "integrations": definition.get("integrations", {}),   # 接入卡配置（zhongtai 等）
        "monetization": {
            "strategy": m.get("strategy", "intro_price"),   # intro_price(首期低价) | free_trial(免费试用N天)
            "weekly_intro": int(m.get("weekly_intro", 18)),
            "weekly_renew": int(m.get("weekly_renew", 48)),
            "trial_days": int(m.get("trial_days", 0)),       # 免费试用天数（仅 free_trial）
            "product_id": m.get("product_id", ""),
            "subscription_name": m.get("subscription_name", ""),   # 订阅名称（审核 3.1.2 应用内明示；空=付费墙回退「{App名} {Plus名}」）
            "retention_enabled": bool(m.get("retention_enabled", False)),   # 挽留套餐（诱导页）
            "retention_price": int(m.get("retention_price", 0)),
            "retention_product_id": m.get("retention_product_id", ""),
            "paywall_copy": _normalize_paywall_copy(m.get("paywall_copy")),
        },
        "compliance": {
            "privacy_url": c.get("privacy_url", "https://example.com/privacy"),
            "terms_url": c.get("terms_url", "https://example.com/terms"),
            "support_email": c.get("support_email", "support@example.com"),
            # 隐私/条款正文（离线浏览）：三重兜底保证尽量非空；
            # legal 透传收窄为 privacy/terms（Swift AppSpec 契约仅这两份）
            "legal": {
                doc: (lambda h, s: {"source": s, "html": h})(*_legal_html(definition, doc))
                for doc in ("privacy", "terms")
            },
        },
        "support": definition.get("support", {}),              # 我的页 6 项配置（关于/反馈/FAQ/评价）
    }


def _apply_product_identity(text: str, name: str, bundle_id: str) -> str:
    """project.yml 改名：bundle id + PRODUCT_NAME + CFBundleDisplayName。

    显示名必须加引号：纯数字名（如 "111"）不加引号会被 xcodegen 的 YAML 解析成
    int，Info.plist 的 CFBundleDisplayName 变成 NSNumber——WebKit GPU 进程启动时
    applicationVisibleName() 按 CFString 构造 WTF::String → -[__NSCFNumber length]
    未捕获异常，App 内打开协议（WKWebView）必崩（2026-08 实测，仅数字名产品触发）。"""
    text = text.replace("com.factory.core", bundle_id)
    # PRODUCT_NAME：CFBundleName=$(PRODUCT_NAME)，缺省会回退成 target 名 FactoryCore，
    # 导致所有产品可执行名相同（二进制指纹连坐）。按产品 name 覆盖（同 CFBundleDisplayName 源）。
    text = text.replace("PRODUCT_NAME: FactoryCore", f'PRODUCT_NAME: "{name}"')
    text = text.replace("UILaunchScreen: {}",
                        f'CFBundleDisplayName: "{name}"\n        UILaunchScreen: {{}}')
    return text


def cmd_assemble(args):
    import shutil
    definition = load_app(args.app)
    definition["_slug"] = (APPS_DIR / args.app).name   # uploads 目录以 slug 命名
    a = definition["app"]
    slug = (APPS_DIR / args.app).name
    # 兜底：bundle_id/name 空时用占位值（让任何配置状态都能跑出有效包）
    if not a.get("bundle_id"):
        a["bundle_id"] = f"com.preview.{slug}"
        print(f"  ⚠ bundle_id 为空，兜底用 {a['bundle_id']}")
    if not a.get("name"):
        a["name"] = "预览包"
    out = BUILD_DIR / slug
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(
        FACTORY_CORE, out,
        ignore=shutil.ignore_patterns("*.xcodeproj", "DerivedData", ".build", "*.xcuserdata"),
    )

    # 1. 写说明书
    spec = build_spec(definition)
    (out / "Resources" / "spec.json").write_text(
        json.dumps(spec, ensure_ascii=False, indent=2), encoding="utf-8")

    # 2. 开机物料 + icon：中控台上传的资源在 server/uploads/<slug>/（slug = App.yml 所在目录名）
    #    注意：slug 是首次创建时锁定的目录名，与 a["id"]（产品代号，可改）不一定相同
    slug = (APPS_DIR / args.app).name            # args.app 是命令行传入的目录名 = slug
    uploads = ROOT / "server" / "uploads" / slug
    if uploads.exists():
        _inject_assets(uploads, out / "Resources" / "assets")
        if _inject_icon(uploads, out):
            print(f"  ✓ App Icon 已注入（来自 uploads/{slug}/icon.*）")
        # 无有效 icon 时用母工程预置的占位 AppIcon（已在 Assets.xcassets/AppIcon.appiconset/）

    # 3. 改名：bundle id + 显示名（引号规则见 _apply_product_identity）
    yml = out / "project.yml"
    text = yml.read_text(encoding="utf-8")
    text = _apply_product_identity(text, a["name"], a["bundle_id"])
    # 4. 裁剪插件：未选插件的包不进依赖 + PluginRegistry.swift 同步裁剪
    plugins = {p["id"] for p in spec["plugins"]}
    if "wallpaper_kit" not in plugins:
        text = text.replace("  WallpaperKit:\n    path: Packages/WallpaperKit\n", "")
        text = text.replace("      - package: WallpaperKit\n", "")
        # 同步裁剪 PluginRegistry.swift（否则 import WallpaperKit 找不到模块）
        pr = out / "Sources" / "PluginRegistry.swift"
        if pr.exists():
            pr_text = pr.read_text(encoding="utf-8")
            pr_text = pr_text.replace("import WallpaperKit\n", "")
            pr_text = pr_text.replace('        case "wallpaper_kit": return WallpaperPlugin.self\n', "")
            pr.write_text(pr_text, encoding="utf-8")
    yml.write_text(text, encoding="utf-8")

    # 4b. 集成选配：按 spec.integrations 的 provider 在 project.yml 加适配包引用
    #     factory_integration.py 是 APP 工厂和 clone 共用的选配逻辑
    from factory_integration import apply_integration_selection
    text = yml.read_text(encoding="utf-8")
    text = apply_integration_selection(text, spec.get("integrations", {}))
    yml.write_text(text, encoding="utf-8")

    # 5. 生成 + 构建（--source-only 跳过：clone 引擎拿到源码后先做差异化处理，再统一 build-source）
    if getattr(args, "source_only", False):
        print(f"\n源码装配完成（未构建）: {out}")
        return
    run(["xcodegen"], cwd=out)
    destination = ("generic/platform=iOS" if args.device
                   else "generic/platform=iOS Simulator")
    derived = out / "DerivedData"
    run(["xcodebuild", "-project", "FactoryCore.xcodeproj",
         "-scheme", "FactoryCore", "-destination", destination,
         "-configuration", "Debug",
         "-derivedDataPath", str(derived), "build"], cwd=out)
    print(f"\n装配完成: {a['name']} ({a['bundle_id']}) → {out}")


def cmd_build_source(args):
    """在指定工程目录直接构建（不复制/不装配/不读 App.yml）。

    供 clone 引擎用：clone 自己复制种子 + 做差异化处理，
    完成后调此命令在 clone/output/<id>/ 直接 xcodegen + xcodebuild。
    """
    project_dir = pathlib.Path(args.source)
    if not project_dir.exists():
        sys.exit(f"工程目录不存在: {project_dir}")
    if not (project_dir / "project.yml").exists():
        sys.exit(f"工程目录没有 project.yml: {project_dir}")
    # scheme 从 project.yml 的 target 名读（默认 FactoryCore）
    # 用文本匹配避免 yaml 依赖
    scheme = "FactoryCore"
    try:
        yml_text = (project_dir / "project.yml").read_text(encoding="utf-8")
        import re
        m = re.search(r'^targets:\s*\n\s+(\w+):', yml_text, re.MULTILINE)
        if m:
            scheme = m.group(1)
    except Exception:
        pass
    destination = ("generic/platform=iOS" if args.device
                   else "generic/platform=iOS Simulator")
    run(["xcodegen"], cwd=project_dir)
    derived = project_dir / "DerivedData"
    # 模拟器架构：默认 arm64（Xcode 26 起已移除 Rosetta 模拟器，x86_64 包装不上）。
    # 仍需 x86_64 时用 FACTORY_SIM_ARCH=x86_64 覆盖（如引入无 arm64-sim slice 的第三方 xcframework）。
    sim_arch = os.environ.get("FACTORY_SIM_ARCH", "arm64")
    arch_args = [] if args.device else [f"ARCHS={sim_arch}"]
    run(["xcodebuild", "-project", f"{scheme}.xcodeproj",
         "-scheme", scheme, "-destination", destination,
         "-configuration", "Debug",
         "-derivedDataPath", str(derived), "build"] + arch_args, cwd=project_dir)
    print(f"\n构建完成: {project_dir} (scheme={scheme})")


def main():
    ap = argparse.ArgumentParser(description="App 工厂")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    s = sub.add_parser("show")
    s.add_argument("--app", required=True)
    s.set_defaults(fn=cmd_show)
    b = sub.add_parser("build")
    b.add_argument("--app", required=True)
    b.add_argument("--device", action="store_true", help="构建真机包")
    b.set_defaults(fn=cmd_build)
    p = sub.add_parser("packet", help="用构建包（definition packet JSON）构建")
    p.add_argument("--file", required=True, help="packet JSON 文件路径")
    p.add_argument("--device", action="store_true", help="构建真机包")
    p.set_defaults(fn=cmd_packet)
    a = sub.add_parser("assemble", help="复制母工程并按说明书装配出包")
    a.add_argument("--app", required=True)
    a.add_argument("--device", action="store_true", help="构建真机包")
    a.add_argument("--source-only", action="store_true",
                   help="只装配源码不构建（clone 引擎用：差异化处理后再 build-source）")
    a.set_defaults(fn=cmd_assemble)
    bs = sub.add_parser("build-source", help="在指定工程目录直接构建（clone 引擎用）")
    bs.add_argument("--source", required=True, help="工程目录路径")
    bs.add_argument("--device", action="store_true", help="构建真机包")
    bs.set_defaults(fn=cmd_build_source)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
