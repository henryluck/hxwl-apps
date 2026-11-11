"""意见反馈本地持久化（SQLite）。

ios-server 首个本地存储层：用户反馈写入 SQLite，便于后续查阅/导出。
为保持简单、适配低写入量，每次写入即时「打开-提交-关闭」连接，无需连接池。

多台 App 共用本 server，且客户端**可伪造 adhead**
（AES 密钥随包分发），所以 prdId/packageName 只作**记录**用途：
来源识别靠它们，但白名单/拦截决策不在这里做（产品口径：零配置服务任意 App）。
"""
import time
from pathlib import Path
from typing import Any, Optional

import aiosqlite

from app.config import settings

# 已知 App 的展示名（仅用于人工查阅/导出，**不做校验、不做拦截**；
# 未知 prdId 存空串，新增 App 无需改服务器 —— 零配置服务任意 App）。
_APP_LABELS: dict = {
    # 已知产品的展示名映射：按新 App 的 prdId 在此补充，未知 prdId 留空
    # 本产品线 prdId：4115205 / 4115206（产品展示名待定，确认后填入 value）
    "4115205": "",
    "4115206": "",
}

_SCHEMA = """
CREATE TABLE IF NOT EXISTS feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    type TEXT NOT NULL,
    content TEXT NOT NULL,
    contact TEXT,
    app_version TEXT,
    app_version_code TEXT,
    device_model TEXT,
    system_version TEXT,
    device_id TEXT,
    prd_id TEXT,
    package_name TEXT,
    app_name TEXT,
    user_id TEXT,
    client_ip TEXT,
    created_at INTEGER NOT NULL
);
"""

# 增量迁移列为已经上线的旧库补齐 v2 字段（幂等：已存在的列跳过，历史数据不动）。
_MIGRATION_COLUMNS = ("prd_id", "package_name", "app_name", "user_id")


async def init_db(db_path: Optional[str] = None) -> None:
    """初始化数据库：确保目录存在并建表（幂等，启动时调用）。"""
    path = db_path or settings.feedback_db_path
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    async with aiosqlite.connect(path) as db:
        await db.executescript(_SCHEMA)
        await _migrate_legacy_columns(db)
        await db.commit()


async def _migrate_legacy_columns(db: Any) -> None:
    """给上线时建的旧表补列（ALTER TABLE ADD COLUMN，幂等）。

    线上 2026-09-28 建的表没有 prd_id/package_name/app_name/user_id 四列，
    不补的话新代码 INSERT 会直接报错（no such column）。
    """
    cur = await db.execute("PRAGMA table_info(feedback)")
    existing = {row[1] for row in await cur.fetchall()}
    for col in _MIGRATION_COLUMNS:
        if col not in existing:
            await db.execute(f"ALTER TABLE feedback ADD COLUMN {col} TEXT")


def _str(value: Any, default: str = "") -> str:
    """安全取字符串：None → 默认值，其余 str()。"""
    return default if value is None else str(value)


def _pick(source: Any, key: str, fallback: Any = "", default: str = "") -> str:
    """从字典优先取非空值，缺失则回退 fallback，再回退 default。"""
    if isinstance(source, dict) and source.get(key) not in (None, ""):
        return _str(source.get(key), default)
    return _str(fallback, default)


async def save_feedback(adhead: Any, data: Any, client_ip: str,
                         db_path: Optional[str] = None) -> int:
    """保存一条反馈，返回自增主键 id。

    业务字段（type/content/contact/appVersion）取自 data（用户输入），
    设备信息（model/sys/deviceId）取自 adhead（Authorization 解密结果），
    来源标识（prdId/packageName/userId）取自 adhead → data 兜底，
    client_ip 与 created_at 由服务端补全。

    ⚠️ 客户端把用户输入放在 **data.fields**（按 spec.support.feedback.fields
    动态键值上报，见 iOS EdgeService.submitFeedback），不是平铺在 data 顶层。
    早期实现只读顶层 key，导致线上反馈的 content 全是空串（用户写的内容丢了）。
    这里 fields 优先、顶层兜底，兼容老客户端与直接调用。

    ⚠️ adhead/packageName 里的 prdId 由客户端透传（零配置服务任意 App），
    只落库不校验：两个 App 共用一台 server 时，靠这两列区分反馈来源。
    """
    path = db_path or settings.feedback_db_path
    ad = adhead if isinstance(adhead, dict) else {}
    fields = data.get("fields") if isinstance(data, dict) else None
    if not isinstance(fields, dict):
        fields = {}
    prd_id = _pick(ad, "prdId", _pick(data, "prdId"))
    package_name = _pick(ad, "packageName", _pick(data, "packageName"))
    app_name = _APP_LABELS.get(prd_id, "")
    user_id = _pick(data, "userId", ad.get("userId"))
    created_at = int(time.time() * 1000)
    async with aiosqlite.connect(path) as db:
        cur = await db.execute(
            """INSERT INTO feedback
               (type, content, contact, app_version, app_version_code,
                device_model, system_version, device_id,
                prd_id, package_name, app_name, user_id,
                client_ip, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                _pick(fields, "type", _pick(data, "type")),
                _pick(fields, "content", _pick(data, "content")),
                _pick(fields, "contact", _pick(data, "contact")),
                _pick(data, "appVersion", ad.get("appVersion")),
                _pick(data, "appVersionCode", ad.get("appVersionCode")),
                _pick(ad, "model", ad.get("phone")),
                _pick(ad, "sysVersion", ad.get("sys")),
                _pick(ad, "deviceId"),
                prd_id,
                package_name,
                app_name,
                user_id,
                client_ip,
                created_at,
            ),
        )
        await db.commit()
        return cur.lastrowid
