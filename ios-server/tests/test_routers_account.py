"""测试账户路由：验证登录、数字联盟、行为统计等接口的转发与数据转换逻辑。"""
import json

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.crypto import encrypt_to_b64
from app.deps import get_tianxu


class FakeTianxu:
    """天枢客户端的测试替身：记录调用参数并返回预设响应。"""
    def __init__(self):
        self.calls = []

    async def forward(self, path, adheader, data, rid=""):
        self.calls.append((path, adheader, data))
        return {"ok": True, "code": 0, "message": "", "result": {"echoPath": path}}

    async def get_access_token(self):
        return "TOK"


def _app(fake):
    """构造注入FakeTianxu的测试应用。"""
    from app.routers import account
    a = FastAPI()
    a.include_router(account.router)
    a.state.tianxu = fake
    return a


def _headers(adhead, data):
    """构造加密的请求头与请求体。"""
    return {"Authorization": encrypt_to_b64(adhead), "Content-Type": "application/json"}, encrypt_to_b64({"data": data})


def test_login_forwards_empty_data():
    """验证登录接口会正确转发空data，并将platform强制为iOS。"""
    fake = FakeTianxu()
    client = TestClient(_app(fake))
    h, body = _headers({"deviceId": "d"}, {})
    r = client.post("/api/v1/session/start", content=body, headers=h)
    assert r.status_code == 200
    assert r.json()["result"]["echoPath"] == "commerce_account_service/api/account/login"
    assert fake.calls[0][2] == {}
    assert fake.calls[0][1]["platform"] == "iOS"


def test_digital_union_forwards_list_data():
    """验证数字联盟接口会正确透传数组格式的data。"""
    fake = FakeTianxu()
    client = TestClient(_app(fake))
    h, body = _headers({"deviceId": "d"}, [{"key": "digital_union_id", "val": "DU1"}])
    r = client.post("/api/v1/device/union", content=body, headers=h)
    assert r.status_code == 200
    assert fake.calls[0][2] == [{"key": "digital_union_id", "val": "DU1"}]


def test_behavior_coerces_value_to_int():
    """验证行为统计接口会将value字段强制转换为整数。"""
    fake = FakeTianxu()
    client = TestClient(_app(fake))
    h, body = _headers({"deviceId": "d"}, {"code": 3, "value": "5"})
    r = client.post("/api/v1/action/report", content=body, headers=h)
    assert r.status_code == 200
    assert fake.calls[0][2] == {"code": 3, "value": 5}
