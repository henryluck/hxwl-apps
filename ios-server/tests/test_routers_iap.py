"""测试IAP路由：验证商品列表、订单创建、恢复购买、收据验证及支付状态上报的转发。"""
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.crypto import encrypt_to_b64


class FakeTianxu:
    """天枢客户端的测试替身：记录调用参数并返回预设响应。"""
    def __init__(self):
        self.calls = []

    async def forward(self, path, adheader, data, rid=""):
        self.calls.append((path, data))
        return {"ok": True, "code": 0, "message": "", "result": {"path": path}}

    async def get_access_token(self):
        return "TOK"


def _app(fake):
    """构造注入FakeTianxu的测试应用。"""
    from app.routers import iap
    a = FastAPI()
    a.include_router(iap.router)
    a.state.tianxu = fake
    return a


def _post(client, path, data):
    """构造并发送加密的POST请求。"""
    body = encrypt_to_b64({"data": data})
    return client.post(path, content=body,
                       headers={"Authorization": encrypt_to_b64({"deviceId": "d"}), "Content-Type": "application/json"})


def test_products():
    """验证商品列表接口会正确转发到天枢商品列表接口。"""
    fake = FakeTianxu(); c = TestClient(_app(fake))
    assert _post(c, "/api/v1/store/catalog", {"commodityProperty": "TYPE_COMSUMABLE"}).status_code == 200
    assert fake.calls[0] == ("commerce_pay_service/api/purchase/goodsList", {"commodityProperty": "TYPE_COMSUMABLE"})


def test_order():
    """验证订单创建接口会正确转发到天枢订单接口。"""
    fake = FakeTianxu(); c = TestClient(_app(fake))
    d = {"type": 3, "commodityId": "c1", "commoditNum": 1}
    _post(c, "/api/v1/store/order", d)
    assert fake.calls[0] == ("commerce_pay_service/api/purchase/addOrder", d)


def test_restore():
    """验证恢复购买接口会正确转发到天枢恢复接口。"""
    fake = FakeTianxu(); c = TestClient(_app(fake))
    d = {"orderInfoList": [{"transactionId": "t1", "originTransactionId": "o1"}]}
    _post(c, "/api/v1/store/restore", d)
    assert fake.calls[0] == ("commerce_pay_service/api/purchase/recover", d)


def test_verify():
    """验单接口转发到天枢 V2 验单接口（iosVerifyOrderV2），原样透传 V2 入参。"""
    fake = FakeTianxu(); c = TestClient(_app(fake))
    d = {"transactionId": "123456789012345", "simulatesAskToBuyInSandbox": False, "identifier": "123"}
    _post(c, "/api/v1/store/verify", d)
    assert fake.calls[0] == ("commerce_pay_service/api/purchase/iosVerifyOrderV2", d)


def test_verify_forwards_sandbox_environment():
    """沙盒交易必须明确转发沙盒标识，避免审核交易按正式环境验单。"""
    fake = FakeTianxu(); c = TestClient(_app(fake))
    d = {"transactionId": "123456789012345", "simulatesAskToBuyInSandbox": True}
    response = _post(c, "/api/v1/store/verify", d)
    assert response.json()["ok"] is True
    assert fake.calls[0][1]["simulatesAskToBuyInSandbox"] is True


def test_verify_rejects_missing_sandbox_environment():
    """缺少环境字段时必须拒绝请求，不能静默回落到正式环境。"""
    fake = FakeTianxu(); c = TestClient(_app(fake))
    response = _post(c, "/api/v1/store/verify", {"transactionId": "123456789012345"})
    assert response.json() == {
        "ok": False,
        "code": 9004,
        "message": "simulatesAskToBuyInSandbox 必须为布尔值",
    }
    assert fake.calls == []


def test_verify_rejects_non_boolean_sandbox_environment():
    """字符串等非布尔值不能被当作环境标识转发。"""
    fake = FakeTianxu(); c = TestClient(_app(fake))
    response = _post(c, "/api/v1/store/verify", {
        "transactionId": "123456789012345",
        "simulatesAskToBuyInSandbox": "true",
    })
    assert response.json()["code"] == 9004
    assert fake.calls == []


def test_pay_state_adds_platform():
    """验证支付状态上报会自动补充platform字段为apple。"""
    fake = FakeTianxu(); c = TestClient(_app(fake))
    _post(c, "/api/v1/store/state", {"orderState": "PAY_SUCCESS", "orderId": "o1", "tranId": "t1"})
    path, data = fake.calls[0]
    assert path == "commerce_pay_service/api/purchase/reportState"
    assert data["platform"] == "apple"
    assert data["orderState"] == "PAY_SUCCESS"
