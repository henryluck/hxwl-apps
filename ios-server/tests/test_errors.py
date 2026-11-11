"""测试错误码：验证各错误码的值正确且互不相同，以及错误响应体的结构。"""
from app.errors import (CODE_DECRYPT_FAILED, CODE_INTERNAL, CODE_NO_CREDENTIALS,
                        CODE_UPSTREAM_UNREACHABLE, error_response,
                        remap_upstream, success_response)


def test_codes_distinct():
    """验证所有错误码的值符合预期且互不重复。"""
    assert {CODE_INTERNAL, CODE_DECRYPT_FAILED, CODE_NO_CREDENTIALS, CODE_UPSTREAM_UNREACHABLE} == {9000, 9001, 9002, 9003}


def test_error_response_shape():
    """验证错误响应体的结构与字段符合预期。"""
    r = error_response(9001, "bad")
    assert r == {"ok": False, "code": 9001, "message": "bad"}


def test_success_response_shape():
    """验证成功响应体的结构与字段符合预期。"""
    assert success_response({"a": 1}) == {"ok": True, "code": 0, "message": "", "result": {"a": 1}}
    assert success_response() == {"ok": True, "code": 0, "message": "", "result": None}


def test_remap_upstream_success():
    """验证上游成功响应 {success,code,msg,data} 被重映射为 {ok,code,message,result}。"""
    r = remap_upstream({"success": True, "code": 0, "msg": "", "data": {"userId": 100123}})
    assert r == {"ok": True, "code": 0, "message": "", "result": {"userId": 100123}}


def test_remap_upstream_business_error():
    """验证上游业务失败响应保留原 code/msg，且无 data 时不带 result 字段。"""
    r = remap_upstream({"success": False, "code": 310002, "msg": "token 失效"})
    assert r == {"ok": False, "code": 310002, "message": "token 失效"}
    assert "result" not in r


def test_remap_upstream_non_dict():
    """验证上游响应非 dict 时收敛为上游不可达错误。"""
    r = remap_upstream(["unexpected"])
    assert r["ok"] is False and r["code"] == CODE_UPSTREAM_UNREACHABLE
