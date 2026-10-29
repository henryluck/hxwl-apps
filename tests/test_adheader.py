"""测试天枢adheader构建：验证固定字段覆盖、prdId 客户端透传与归一化、输入不被修改。

prdId 的权威来源已从服务端配置迁移到客户端（App 的 spec.json → integrations.edge.prdId），
服务端只透传，这样同一台 server 可同时服务多个 App（2026-10 改造）。
"""
from app.adheader import build_tianxu_adheader


def test_overrides_fixed_fields():
    """验证固定字段（如platform/version等）会被强制覆盖为iOS预期值。"""
    out = build_tianxu_adheader({"platform": "android", "deviceId": "dev1"}, "1.2.3.4", 1700000000000)
    assert out["platform"] == "iOS"
    assert out["phoneType"] == "iOS"
    assert out["manufacturer"] == "Apple"
    assert out["currentChannel"] == 61
    assert out["version"] == "3.0.6.5"
    assert out["versionCode"] == 3065
    assert out["ip"] == "1.2.3.4"
    assert out["timestamp"] == 1700000000000


def test_client_prd_id_passthrough():
    """验证客户端 prdId 原样透传（服务端不再按环境覆盖）。"""
    out = build_tianxu_adheader({"deviceId": "dev1", "prdId": "1234501"}, "9.9.9.9", 1)
    assert out["prdId"] == "1234501"


def test_prd_id_number_normalized_to_string():
    """客户端把 prdId 传成数字时归一化为字符串（天枢侧契约是字符串）。"""
    out = build_tianxu_adheader({"deviceId": "dev1", "prdId": 1234501}, "9.9.9.9", 1)
    assert out["prdId"] == "1234501"


def test_prd_id_whitespace_stripped():
    """prdId 前后空白被剔除（防 spec.json 里误留空格导致上游判为无效产品）。"""
    out = build_tianxu_adheader({"prdId": "  1234501  "}, "9.9.9.9", 1)
    assert out["prdId"] == "1234501"


def test_missing_prd_id_not_injected():
    """客户端未带 prdId 时**不注入**任何默认值，交由 forward 本地拦截。"""
    out = build_tianxu_adheader({"deviceId": "dev1"}, "9.9.9.9", 1)
    assert "prdId" not in out


def test_blank_prd_id_dropped():
    """prdId 为空串/空白时不注入空值（否则会带着空串打上游）。"""
    for blank in ("", "   ", None):
        out = build_tianxu_adheader({"deviceId": "dev1", "prdId": blank}, "9.9.9.9", 1)
        assert "prdId" not in out, f"prdId={blank!r} 应被删除"


def test_passthrough_keeps_client_fields():
    """验证客户端传入的 deviceId/userId 等字段会被保留。"""
    out = build_tianxu_adheader(
        {"deviceId": "dev1", "prdId": "23000", "userId": "u9", "activityChannel": 7,
         "digitalUnionId": "DU123", "model": "iPhone15,2"}, "9.9.9.9", 1)
    assert out["deviceId"] == "dev1"
    assert out["prdId"] == "23000"
    assert out["userId"] == "u9"
    assert out["activityChannel"] == 7
    assert out["digitalUnionId"] == "DU123"
    assert out["model"] == "iPhone15,2"


def test_does_not_mutate_input():
    """验证构建过程不修改原始输入字典。"""
    src = {"deviceId": "dev1"}
    build_tianxu_adheader(src, "1.1.1.1", 1)
    assert src == {"deviceId": "dev1"}
