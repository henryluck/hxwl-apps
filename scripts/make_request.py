"""联调工具：用与客户端相同的 Key/IV 加密请求，发往本 server 并打印响应。

用法:
    python scripts/make_request.py --url http://127.0.0.1:8000/api/v1/session/start --data '{}'

prdId 由客户端透传（服务端不再覆盖），本脚本默认用 `4115205`，
可用环境变量 `PRD_ID=...` 覆盖（如 `PRD_ID=4115206`）以验证多产品透传。
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

# Add project root to path so we can import app modules
project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root))

from app.crypto import encrypt_to_b64

DEFAULT_PRD_ID = "4115205"  # 本产品线 prdId（另一产品线为 4115206）；与 App spec.json integrations.edge.prdId 保持一致


def build_adhead(user_id: str | None = None) -> dict:
    """构造天枢上报所需的 adheader（设备信息与渠道参数）。

    Args:
        user_id: 用户 ID（登录后由 login 接口返回）。**login 接口不传**——userId 是 login
            的返回值，传空字符串 "" 会被天枢拒为 "empty String"；登录后的其他接口才传入。
    """
    adhead = {
        "phone": "iPhone15,2", "model": "iPhone15,2", "sys": "17.0", "sysVersion": "17.0",
        "platform": "iOS", "phoneType": "iOS", "manufacturer": "Apple",
        "deviceId": "test-device-id", "prdId": os.getenv("PRD_ID", DEFAULT_PRD_ID), "currentChannel": 61,
        "appVersion": "1.0.0", "appVersionCode": 1, "version": "3.0.6.5", "versionCode": 3065,
        "packageName": "com.yourcompany.appname",  # 与新 App 线上包 bundle id 一致
        "phoneId": "00000000-0000-0000-0000-000000000000",
        "activityChannel": 0, "digitalUnionId": "none", "timestamp": "0",
    }
    if user_id is not None:
        adhead["userId"] = user_id  # 登录后的数字 userId（login 返回）
    return adhead


def main() -> int:
    """命令行入口：解析参数、加密请求体、发送到目标接口并输出响应。"""
    ap = argparse.ArgumentParser(description="iOS→天枢 server 联调工具")
    ap.add_argument("--url", required=True, help="目标接口 URL，如 http://127.0.0.1:8000/api/v1/session/start")
    ap.add_argument("--data", default="{}", help="data 字段的 JSON，默认 {}")
    ap.add_argument("--user-id", default=None, help="adheader.userId（login 不传；登录后的接口传入数字 userId）")
    args = ap.parse_args()

    auth = encrypt_to_b64(build_adhead(args.user_id))
    body = encrypt_to_b64({"data": json.loads(args.data)})

    req = urllib.request.Request(
        args.url, data=body.encode("utf-8"), method="POST",
        headers={"Content-Type": "application/json", "Authorization": auth})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            print("HTTP", resp.status)
            print(resp.read().decode("utf-8"))
            return 0
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, file=sys.stderr)
        print(e.read().decode("utf-8"), file=sys.stderr)
        return 1
    except urllib.error.URLError as e:
        print("连接失败:", e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
