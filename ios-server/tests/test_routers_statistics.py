"""测试统计路由：验证事件上报与用户属性上报会正确转发到天枢shence接口。"""
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.crypto import encrypt_to_b64


class FakeTianxu:
    """天枢客户端的测试替身：记录调用参数并返回预设响应。"""
    def __init__(self):
        self.calls = []

    async def forward(self, path, adheader, data, rid=""):
        self.calls.append((path, data))
        return {"ok": True, "code": 0, "message": "", "result": {"echoPath": path}}

    async def get_access_token(self):
        return "TOK"


def _app(fake):
    """构造注入FakeTianxu的测试应用。"""
    from app.routers import statistics
    a = FastAPI()
    a.include_router(statistics.router)
    a.state.tianxu = fake
    return a


def _post(client, path, data):
    """构造并发送加密的POST请求。"""
    body = encrypt_to_b64({"data": data})
    return client.post(path, content=body,
                       headers={"Authorization": encrypt_to_b64({"deviceId": "d"}), "Content-Type": "application/json"})


def test_event_forwards_to_shence():
    """验证事件上报会正确转发到天枢shence上传接口。"""
    fake = FakeTianxu()
    client = TestClient(_app(fake))
    data = {"eventName": "$AppStart", "params": {"$os": "iOS"}}
    r = _post(client, "/api/v1/telemetry/event", data)
    assert r.status_code == 200
    assert r.json()["result"]["echoPath"] == "commerce_shence_service/api/common/uploadShenceData"
    assert fake.calls[0][0] == "commerce_shence_service/api/common/uploadShenceData"
    assert fake.calls[0][1] == data  # 原样透传，含 eventName/params


def test_profile_forwards_to_shence():
    """验证用户属性上报会正确转发到天枢shence用户属性上传接口。"""
    fake = FakeTianxu()
    client = TestClient(_app(fake))
    data = {"params": {"vip_level": 3}, "create": False}
    r = _post(client, "/api/v1/telemetry/profile", data)
    assert r.status_code == 200
    assert r.json()["result"]["echoPath"] == "commerce_shence_service/api/common/uploadShenceUserProperty"
    assert fake.calls[0][0] == "commerce_shence_service/api/common/uploadShenceUserProperty"
    assert fake.calls[0][1] == data  # 原样透传，含 create


def test_event_batch_forwards_to_sensor_event():
    """验证批量事件上报转发到天枢 scenead_shence_service 批量接口，sensorList 原样透传。"""
    fake = FakeTianxu()
    client = TestClient(_app(fake))
    data = {"sensorList": [
        {"eventName": "app_purchase", "offset": 1200, "params": {"state": 4}},
        {"eventName": "$AppStart", "offset": 0, "params": {"$os": "iOS"}},
    ]}
    r = _post(client, "/api/v1/telemetry/event/batch", data)
    assert r.status_code == 200
    assert r.json()["result"]["echoPath"] == "scenead_shence_service/api/sensor/event"
    assert fake.calls[0][0] == "scenead_shence_service/api/sensor/event"
    assert fake.calls[0][1] == data  # sensorList 原样透传


def test_event_batch_rejects_invalid_sensor_list():
    """sensorList 缺失/为空/非数组时拒绝请求，不转发天枢。"""
    fake = FakeTianxu()
    client = TestClient(_app(fake))
    for bad in ({}, {"sensorList": []}, {"sensorList": "x"}, {"sensorList": None}):
        r = _post(client, "/api/v1/telemetry/event/batch", bad)
        assert r.status_code == 200  # 错误也是 HTTP 200 统一包络
        assert r.json()["ok"] is False
    assert fake.calls == []  # 均未转发
