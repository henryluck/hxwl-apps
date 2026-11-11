"""测试意见反馈路由：验证加密请求能正确解密并写入本地 SQLite。"""
import asyncio
import sqlite3

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.crypto import encrypt_to_b64
from app.storage import init_db


def _make_app(db_path: str) -> FastAPI:
    """构造注入临时数据库的测试应用（建表后挂路由）。"""
    asyncio.run(init_db(db_path))
    from app.routers import feedback
    a = FastAPI()
    a.include_router(feedback.router)
    a.state.feedback_db_path = db_path
    return a


def _post(client, path, data, adhead):
    """构造并发送加密的 POST 请求。"""
    body = encrypt_to_b64({"data": data})
    return client.post(path, content=body, headers={
        "Authorization": encrypt_to_b64(adhead),
        "Content-Type": "application/json",
    })


def test_save_feedback(tmp_path):
    """验证反馈接口写入 SQLite，且响应符合标准信封。"""
    db_path = str(tmp_path / "feedback.db")
    c = TestClient(_make_app(db_path))
    adhead = {"deviceId": "dev1", "model": "iPhone", "sysVersion": "17.5",
              "appVersion": "1.0.0", "appVersionCode": 24}
    data = {"type": "功能建议", "content": "希望增加深色模式",
            "contact": "a@b.com", "appVersion": "1.0.0", "appVersionCode": 24}

    resp = _post(c, "/api/v1/support/feedback", data, adhead)
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body["code"] == 0
    rid = body["result"]["id"]

    # 校验落库（业务字段来自 data，设备字段来自 adhead）
    con = sqlite3.connect(db_path)
    row = con.execute(
        "SELECT type, content, contact, app_version, device_model, system_version, device_id "
        "FROM feedback WHERE id=?", (rid,)).fetchone()
    con.close()
    assert row is not None
    assert row[0] == "功能建议"
    assert row[1] == "希望增加深色模式"
    assert row[2] == "a@b.com"
    assert row[3] == "1.0.0"
    assert row[4] == "iPhone"
    assert row[5] == "17.5"
    assert row[6] == "dev1"


def test_save_feedback_minimal(tmp_path):
    """仅有 type/content 也能落库（contact 等可选字段为空）。"""
    db_path = str(tmp_path / "feedback.db")
    c = TestClient(_make_app(db_path))
    resp = _post(c, "/api/v1/support/feedback", {"type": "Bug 反馈", "content": "x"}, {})
    assert resp.status_code == 200
    assert resp.json()["ok"] is True


def test_save_feedback_fields_payload(tmp_path):
    """iOS 真实载荷：用户输入在 data.fields 里（不是平铺顶层）。

    回归用例：早期实现只读顶层 data["content"]，线上反馈 content 全是空串，
    用户写的内容整条丢失。
    """
    db_path = str(tmp_path / "feedback.db")
    c = TestClient(_make_app(db_path))
    adhead = {"deviceId": "dev2", "model": "iPhone18,1", "sysVersion": "18.0",
              "appVersion": "1.0.0", "appVersionCode": 100}
    data = {
        "fields": {"content": "导航语音播报偶尔没有声音"},
        "appVersion": "1.0.0",
        "deviceModel": "iPhone",
        "systemVersion": "18.0",
        "userId": 42,
    }

    resp = _post(c, "/api/v1/support/feedback", data, adhead)
    assert resp.status_code == 200
    rid = resp.json()["result"]["id"]

    con = sqlite3.connect(db_path)
    row = con.execute(
        "SELECT content, app_version, device_model, device_id FROM feedback WHERE id=?",
        (rid,)).fetchone()
    con.close()
    assert row is not None
    assert row[0] == "导航语音播报偶尔没有声音"   # 关键：内容不能为空
    assert row[1] == "1.0.0"
    assert row[2] == "iPhone18,1"                # 设备信息取 adhead（比客户端自报更可信）
    assert row[3] == "dev2"


def test_save_feedback_app_identity(tmp_path):
    """两个 App 共用一台 server：落库必须带 prd_id/package_name/app_name 才能区分来源。"""
    db_path = str(tmp_path / "feedback.db")
    c = TestClient(_make_app(db_path))
    adhead = {"deviceId": "dev3", "model": "iPhone", "sysVersion": "17.5", "appVersion": "1.2.0",
              "prdId": "1234501", "packageName": "com.yourcompany.appname"}
    data = {"fields": {"content": "示例应用A的反馈"},
            "userId": 42, "appVersion": "1.2.0"}

    resp = _post(c, "/api/v1/support/feedback", data, adhead)
    rid = resp.json()["result"]["id"]

    con = sqlite3.connect(db_path)
    row = con.execute(
        "SELECT prd_id, package_name, app_name, user_id FROM feedback WHERE id=?",
        (rid,)).fetchone()
    con.close()
    assert row == ("1234501", "com.yourcompany.appname", "", "42")  # 未知 prdId 展示名留空


def test_save_feedback_identity_fallback_to_data(tmp_path):
    """adhead 没带 prdId/packageName 时回退 data（兼容旧客户端），user_id 取 data.userId。"""
    db_path = str(tmp_path / "feedback.db")
    c = TestClient(_make_app(db_path))
    data = {"fields": {"content": "x"}, "prdId": "1234502", "packageName": "com.yourcompany.appname2"}

    resp = _post(c, "/api/v1/support/feedback", data, {})
    rid = resp.json()["result"]["id"]

    con = sqlite3.connect(db_path)
    row = con.execute(
        "SELECT prd_id, package_name, app_name, user_id FROM feedback WHERE id=?",
        (rid,)).fetchone()
    con.close()
    assert row == ("1234502", "com.yourcompany.appname2", "", "")  # 未知 prdId 展示名留空


def test_init_db_migrates_legacy_columns(tmp_path):
    """旧库（2026-09-28 上线时建的 11 列表）启动时自动补列，历史数据不动。"""
    import asyncio

    db_path = str(tmp_path / "feedback.db")
    legacy = sqlite3.connect(db_path)
    legacy.executescript(
        """CREATE TABLE feedback (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL, content TEXT NOT NULL, contact TEXT,
            app_version TEXT, app_version_code TEXT,
            device_model TEXT, system_version TEXT, device_id TEXT,
            client_ip TEXT, created_at INTEGER NOT NULL);""")
    legacy.execute(
        "INSERT INTO feedback (type, content, device_id, client_ip, created_at)"
        " VALUES ('历史', '旧库存量行', 'dev-old', '1.2.3.4', 1)")
    legacy.commit()
    legacy.close()

    asyncio.run(init_db(db_path))

    con = sqlite3.connect(db_path)
    cols = {d[1] for d in con.execute("PRAGMA table_info(feedback)")}
    row = con.execute(
        "SELECT content, prd_id, package_name, app_name, user_id FROM feedback WHERE id=1"
    ).fetchone()
    con.close()
    assert {"prd_id", "package_name", "app_name", "user_id"} <= cols
    assert row == ("旧库存量行", None, None, None, None)


# 注：解密失败（code 9001）由 app.main 的全局 CryptoError 处理器返回，
# 已在 tests/test_main.py 覆盖，此处不重复测试路由级行为。
