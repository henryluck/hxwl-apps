"""测试请求解析依赖：验证请求头与请求体的解密、IP提取、空body处理及data数组透传。"""
import time

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.crypto import encrypt_to_b64
from app.deps import ParsedRequest, parse_request


def _app():
    """构造带有parse_request依赖的测试FastAPI应用。"""
    app = FastAPI()

    @app.post("/probe")
    async def probe(parsed: ParsedRequest = Depends_parse()):
        return {"adhead": parsed.adhead, "data": parsed.data, "ip": parsed.client_ip}

    return app


def Depends_parse():
    """FastAPI依赖注入工厂：返回parse_request依赖。"""
    from fastapi import Depends
    return Depends(parse_request)


def test_parse_decrypts_header_and_body():
    """验证parse_request能正确解密请求头与请求体，并提取客户端IP。"""
    adhead = {"deviceId": "dev1", "platform": "android"}
    body = encrypt_to_b64({"data": {"commodityId": "c1", "commoditNum": "1"}})
    client = TestClient(_app())
    r = client.post("/probe", content=body,
                    headers={"Authorization": encrypt_to_b64(adhead),
                             "Content-Type": "application/json",
                             "X-Forwarded-For": "203.0.113.7, 10.0.0.1"})
    assert r.status_code == 200
    body_json = r.json()
    assert body_json["adhead"] == adhead
    assert body_json["data"] == {"commodityId": "c1", "commoditNum": "1"}
    assert body_json["ip"] == "203.0.113.7"


def test_parse_empty_body_yields_empty_data():
    """验证空请求体会被解析为空data字典。"""
    client = TestClient(_app())
    r = client.post("/probe", content="",
                    headers={"Authorization": encrypt_to_b64({"deviceId": "d"}),
                             "Content-Type": "application/json"})
    assert r.status_code == 200
    assert r.json()["data"] == {}


def test_parse_list_data_passthrough():
    """验证data为数组时能正确透传。"""
    client = TestClient(_app())
    body = encrypt_to_b64({"data": [{"key": "digital_union_id", "val": "DU1"}]})
    r = client.post("/probe", content=body,
                    headers={"Authorization": encrypt_to_b64({}),
                             "Content-Type": "application/json"})
    assert r.json()["data"] == [{"key": "digital_union_id", "val": "DU1"}]
