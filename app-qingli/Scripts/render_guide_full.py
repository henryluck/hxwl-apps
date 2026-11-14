#!/usr/bin/env python3
"""重生成 App 清理指引的整页长图资源（Resources/assets/proto/guide_full/*.jpg）。

用法：
    python3 Scripts/render_guide_full.py
    python3 Scripts/render_guide_full.py --proto "/path/to/清理工具"

背景 / 易错点：
  原型 SVG 自带 width/height/viewBox（402 x H，H 各页不同）。必须让页面尺寸
  精确等于该尺寸，再用 --force-device-scale-factor=2 输出 2 倍像素。
  早期版本把 SVG 塞进固定 550x1300 视口「拉伸/裁切」，产出的 1100x2600 JPG
  内容左偏、右半纯白、文字与手机截图被横向切掉 —— 表现为 App 里
  「指引截图只能显示一半」。这是资源问题，不是 Image 布局问题。

  原型长图顶部还自带一行「< XX清理指引」返回箭头 + 标题（Figma 画板标题栏），
  而 App 的 NavigationStack 已经有同款标题栏，属于重复显示。这里通过改写根
  <svg> 的 viewBox 为 `0 CROP_TOP w (h-CROP_TOP)` 把顶部裁掉：
  原型标题文字在 y≈67~86 CSS px，「第一步」标题在 y≈130，裁 100px 后
  既完全去掉重复标题，又给「第一步」保留约 25px 上间距。

编号 -> App 映射已逐张核对过 SVG 顶部标题，与 CacheApp 的 case 顺序一致。
"""
import argparse
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_PROTO = pathlib.Path('/Users/gx/Downloads/清理工具')
DEFAULT_OUT = ROOT / 'Resources/assets/proto/guide_full'
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
# 原型画板顶部「< XX清理指引」标题栏高度（CSS px），与 App 导航栏重复，裁掉
CROP_TOP = 100

MAPPING = {
    127: 'wechat',
    128: 'qq',
    129: 'pinduoduo',
    130: 'youku',
    131: 'douyin',
    132: 'kuaishou',
    133: 'xiaohongshu',
    134: 'tencentVideo',
    135: 'taobao',
    136: 'iqiyi',
}

WRAPPER = '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width={w}, initial-scale=1">
<style>
  html, body {{ margin:0; padding:0; background:#fff; overflow:hidden; }}
  svg {{ display:block; width:{w}px; height:{h}px; }}
</style></head><body>
{svg}
</body></html>'''


def crop_top_svg(text: str, w: int, h: int) -> tuple[str, int]:
    """下移根 <svg> 的 viewBox，等效裁掉原型自带的标题栏（不缩放、不变形）。

    返回 (改写后的 SVG 文本, 裁剪后的可见高度)。
    """
    visible_h = h - CROP_TOP
    if visible_h <= 0:
        raise SystemExit(f'SVG 高度 {h} 小于 CROP_TOP={CROP_TOP}')

    def rewrite(match):
        tag = re.sub(r'\bheight="\d+"', f'height="{visible_h}"',
                     match.group(0), count=1)
        new_vb = f'viewBox="0 {CROP_TOP} {w} {visible_h}"'
        if 'viewBox=' in tag:
            tag = re.sub(r'\bviewBox="[^"]*"', new_vb, tag, count=1)
        else:
            tag = tag[:-1].rstrip() + ' ' + new_vb + '>'
        return tag

    text, n = re.subn(r'<svg\b[^>]*>', rewrite, text, count=1)
    if n != 1:
        raise SystemExit('找不到根 <svg> 标签')
    return text, visible_h


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--proto', type=pathlib.Path, default=DEFAULT_PROTO,
                    help='原型 SVG 所在目录')
    ap.add_argument('--out', type=pathlib.Path, default=DEFAULT_OUT,
                    help='输出 guide_full 目录')
    args = ap.parse_args()

    if not pathlib.Path(CHROME).exists():
        raise SystemExit(f'找不到 Chrome: {CHROME}')
    args.out.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix='guide_full_') as tmp:
        work = pathlib.Path(tmp)
        profile = work / 'chrome-profile'
        for num, app in MAPPING.items():
            src = args.proto / f'iPhone 16 & 17 Pro - {num}.svg'
            if not src.exists():
                raise SystemExit(f'缺少原型文件: {src}')
            text = src.read_text(encoding='utf-8')
            m = re.search(r'<svg[^>]*?width="(\d+)"[^>]*?height="(\d+)"', text)
            if not m:
                raise SystemExit(f'{src.name}: 找不到 svg width/height')
            w, h = int(m.group(1)), int(m.group(2))
            text = re.sub(r'^\s*<\?xml[^>]*\?>\s*', '', text)
            text, view_h = crop_top_svg(text, w, h)

            html = work / f'{num}.html'
            html.write_text(WRAPPER.format(w=w, h=view_h, svg=text), encoding='utf-8')
            png = work / f'{num}.png'
            subprocess.run([
                CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars',
                '--no-first-run', '--no-default-browser-check',
                '--disable-extensions', '--no-sandbox',
                '--force-device-scale-factor=2',
                f'--window-size={w},{view_h}', '--virtual-time-budget=10000',
                f'--user-data-dir={profile}', f'--screenshot={png}',
                html.as_uri(),
            ], check=True, capture_output=True, text=True, timeout=180)
            if not png.exists():
                raise SystemExit(f'{num}: Chrome 未产出截图')

            jpg = args.out / f'{app}_full.jpg'
            subprocess.run([
                'sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '88',
                str(png), '--out', str(jpg),
            ], check=True, capture_output=True, text=True)
            dims = subprocess.check_output(
                ['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(jpg)],
                text=True)
            pw, ph = [int(x) for x in re.findall(r': (\d+)', dims)]
            if pw != w * 2 or ph != view_h * 2:
                raise SystemExit(f'{app}: 尺寸异常 {pw}x{ph}，期望 {w*2}x{view_h*2}')
            print(f'{num:3d} {app:14s} {w}x{h} -{CROP_TOP} -> {pw}x{ph}  '
                  f'{jpg.stat().st_size // 1024} KB')

    print(f'完成，输出目录: {args.out}')


if __name__ == '__main__':
    main()
