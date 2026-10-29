"""测试天枢客户端：验证token缓存、并发请求、凭证校验、转发透传及异常处理。"""
import asyncio
import json
import time

import httpx
import pytest

from app.config import load_settings
from app.errors import (CODE_INVALID_REQUEST, CODE_NO_CREDENTIALS,
                        CODE_UPSTREAM_UNREACHABLE)
from app.tianxu import TianxuClient, TianxuError

PRD = "1234501"  # 用例用 prdId（客户端透传，forward 会校验非空）


def _settings(monkeypatch):
    """配置有效凭证并加载settings。"""
    monkeypatch.setenv("TIANXU_APP_KEY", "real_key")
    monkeypatch.setenv("TIANXU_APP_SECRET", "real_secret")
    monkeypatch.setenv("TIANXU_ENV", "test")
    monkeypatch.setenv("TOKEN_API_URL", "https://provider.example.com/api/accesstoken")
    monkeypatch.setenv("TOKEN_API_KEY", "provider-api-key")
    return load_settings()


def _token_transport(calls):
    """构造mock transport：记录请求路径，并返回预设的token响应。"""
    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        if request.url.path == "/api/accesstoken":
            return httpx.Response(200, json={
                "success": True, "code": 0, "msg": "ok",
                "data": {"accessToken": "TOK-1", "expiresIn": int(time.time() * 1000) + 86400000}})
        return httpx.Response(200, json={"success": True, "code": 0, "msg": "ok", "data": {"ok": True}})
    return httpx.MockTransport(handler)


@pytest.mark.asyncio
async def test_get_token_caches(monkeypatch):
    """验证连续两次获取token会复用缓存，只调用一次拉取接口。"""
    calls = []
    client = httpx.AsyncClient(transport=_token_transport(calls))
    tx = TianxuClient(client, _settings(monkeypatch))
    t1 = await tx.get_access_token()
    t2 = await tx.get_access_token()
    assert t1 == t2 == "TOK-1"
    assert calls.count("/api/accesstoken") == 1
    await client.aclose()


@pytest.mark.asyncio
async def test_get_token_concurrent_single_flight(monkeypatch):
    """验证并发获取token时只调用一次拉取接口（单飞模式）。"""
    calls = []
    client = httpx.AsyncClient(transport=_token_transport(calls))
    tx = TianxuClient(client, _settings(monkeypatch))
    tokens = await asyncio.gather(tx.get_access_token(), tx.get_access_token(), tx.get_access_token())
    assert all(t == "TOK-1" for t in tokens)
    assert calls.count("/api/accesstoken") == 1
    await client.aclose()


@pytest.mark.asyncio
async def test_no_credentials_raises(monkeypatch):
    """验证未配置 TOKEN_API_URL/TOKEN_API_KEY 会抛出无凭证错误。"""
    monkeypatch.delenv("TOKEN_API_URL", raising=False)
    monkeypatch.delenv("TOKEN_API_KEY", raising=False)
    client = httpx.AsyncClient(transport=_token_transport([]))
    tx = TianxuClient(client, load_settings())
    with pytest.raises(TianxuError) as ei:
        await tx.get_access_token()
    assert ei.value.code == CODE_NO_CREDENTIALS
    await client.aclose()


@pytest.mark.asyncio
async def test_forward_passes_through(monkeypatch):
    """验证转发请求会正确携带Access-Token与Authorization头，并透传响应。"""
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append((request.url.path, dict(request.headers)))
        if request.url.path == "/api/accesstoken":
            return httpx.Response(200, json={"success": True, "code": 0, "data": {
                "accessToken": "TOK-1", "expiresIn": int(time.time() * 1000) + 86400000}})
        return httpx.Response(200, json={"success": True, "code": 0, "data": {"userId": 1}})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    tx = TianxuClient(client, _settings(monkeypatch))
    resp = await tx.forward("commerce_account_service/api/account/login", {"prdId": PRD}, {})
    assert resp == {"ok": True, "code": 0, "message": "", "result": {"userId": 1}}
    # 转发请求带了 Access-Token 与 Authorization 头
    fwd_headers = calls[1][1]
    assert fwd_headers["access-token"] == "TOK-1"
    assert "authorization" in fwd_headers
    await client.aclose()


@pytest.mark.asyncio
async def test_forward_authorization_ascii_safe(monkeypatch):
    """非 ASCII 广告头字段（如 zgxMap 中文 message）必须转义，Authorization 头可编码为 ASCII。

    回归：ensure_ascii=False 时 httpx 编码头抛 'ascii' codec can't encode → 9000，
    登录/归因全链路被一个脏字段炸穿（2026-09-14 联调实录）。
    """
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(dict(request.headers))
        if request.url.path == "/api/accesstoken":
            return httpx.Response(200, json={"success": True, "code": 0, "data": {
                "accessToken": "TOK-1", "expiresIn": int(time.time() * 1000) + 86400000}})
        return httpx.Response(200, json={"success": True, "code": 0, "data": None})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    tx = TianxuClient(client, _settings(monkeypatch))
    dirty = {"prdId": PRD, "zgxMap": {"code": 30003, "message": "CAID请求中，请稍后重试！"}}
    await tx.forward("commerce_account_service/api/account/login", dirty, {})
    auth_header = calls[1]["authorization"]
    auth_header.encode("ascii")  # 不抛即通过
    assert "\\u" in auth_header  # 非 ASCII 已转义
    await client.aclose()


@pytest.mark.asyncio
async def test_forward_unreachable_raises(monkeypatch):
    """验证天枢连接失败（ConnectError）会抛出不可达错误。"""
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("boom")
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    tx = TianxuClient(client, _settings(monkeypatch))
    with pytest.raises(TianxuError) as ei:
        await tx.forward("any/path", {"prdId": PRD}, {})
    assert ei.value.code == CODE_UPSTREAM_UNREACHABLE
    await client.aclose()


@pytest.mark.asyncio
async def test_forward_passes_through_4xx_business_error(monkeypatch):
    """天枢业务错误（HTTP 4xx + JSON body，如 401+310003）应原样透传，不包成 9003。"""
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/accesstoken":
            return httpx.Response(200, json={"success": True, "code": 0, "data": {
                "accessToken": "TOK-1", "expiresIn": int(time.time() * 1000) + 86400000}})
        return httpx.Response(401, json={"success": False, "code": 310003, "msg": "接口未授权"})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    tx = TianxuClient(client, _settings(monkeypatch))
    resp = await tx.forward("commerce_account_service/api/account/login", {"prdId": PRD}, {})
    assert resp == {"ok": False, "code": 310003, "message": "接口未授权"}
    await client.aclose()


@pytest.mark.asyncio
async def test_forward_non_json_response_raises(monkeypatch):
    """天枢返回非 JSON（如网关 502 HTML）才包成 9003。"""
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/accesstoken":
            return httpx.Response(200, json={"success": True, "code": 0, "data": {
                "accessToken": "TOK-1", "expiresIn": int(time.time() * 1000) + 86400000}})
        return httpx.Response(502, content="<html>Bad Gateway</html>",
                              headers={"Content-Type": "text/html"})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    tx = TianxuClient(client, _settings(monkeypatch))
    with pytest.raises(TianxuError) as ei:
        await tx.forward("any/path", {"prdId": PRD}, {})
    assert ei.value.code == CODE_UPSTREAM_UNREACHABLE
    await client.aclose()


@pytest.mark.asyncio
async def test_forward_success_no_duplicate_request(monkeypatch):
    """成功响应必须只发一次上游请求（回归：for 循环缺 return 导致无条件二次迭代，
    addOrder 因此在天枢侧重复下单——2026-09-20 真机购买实录）。"""
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        if request.url.path == "/api/accesstoken":
            return httpx.Response(200, json={"success": True, "code": 0, "data": {
                "accessToken": "TOK-1", "expiresIn": int(time.time() * 1000) + 86400000}})
        return httpx.Response(200, json={"success": True, "code": 0, "data": {"ok": 1}})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    tx = TianxuClient(client, _settings(monkeypatch))
    resp = await tx.forward("commerce_pay_service/api/purchase/addOrder", {"prdId": PRD}, {})
    assert resp["code"] == 0
    fwd = [c for c in calls if c != "/api/accesstoken"]
    assert len(fwd) == 1, f"成功响应不应重试，实际上游请求 {len(fwd)} 次"
    await client.aclose()


@pytest.mark.asyncio
async def test_forward_retries_once_on_310002(monkeypatch):
    """天枢返回 310002（token 被其他实例刷新作废）→ 作废缓存强制刷新后重试一次成功。

    生产实录：3 个 gunicorn worker 各自缓存 token，一方 refresh 使其他方 token 失效，
    失败方从此报 310002 直至自身过期（login 85/121、uploadShenceData 119/170 失败）。
    """
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        if request.url.path == "/api/accesstoken":
            n = calls.count(request.url.path)
            return httpx.Response(200, json={"success": True, "code": 0, "data": {
                "accessToken": f"TOK-{n}", "expiresIn": int(time.time() * 1000) + 86400000}})
        n = len(calls) - calls.count("/api/accesstoken")
        if n == 1:  # 第一次转发：旧 token 已被其他实例作废
            return httpx.Response(401, json={"success": False, "code": 310002,
                                             "msg": "ACCESS_TOKEN过期"})
        return httpx.Response(200, json={"success": True, "code": 0, "data": {"ok": True}})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    tx = TianxuClient(client, _settings(monkeypatch))
    resp = await tx.forward("commerce_account_service/api/account/login", {"prdId": PRD}, {})
    assert resp["ok"] is True  # 重试后成功
    # 刷新了 2 次（初次 + 310002 后强刷），转发了 2 次
    assert calls.count("/api/accesstoken") == 2
    fwd = [c for c in calls if c != "/api/accesstoken"]
    assert len(fwd) == 2
    await client.aclose()


@pytest.mark.asyncio
async def test_forward_stops_after_second_310002(monkeypatch):
    """连续两次 310002 → 不再重试，原样透传给客户端（防循环）。"""
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        if request.url.path == "/api/accesstoken":
            return httpx.Response(200, json={"success": True, "code": 0, "data": {
                "accessToken": "TOK-X", "expiresIn": int(time.time() * 1000) + 86400000}})
        return httpx.Response(401, json={"success": False, "code": 310002,
                                         "msg": "ACCESS_TOKEN过期"})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    tx = TianxuClient(client, _settings(monkeypatch))
    resp = await tx.forward("commerce_account_service/api/account/login", {"prdId": PRD}, {})
    assert resp["code"] == 310002  # 原样透传
    fwd = [c for c in calls if c != "/api/accesstoken"]
    assert len(fwd) == 2  # 恰好重试一次，不无限循环
    await client.aclose()


@pytest.mark.asyncio
async def test_shared_token_adopted_across_clients(monkeypatch, tmp_path):
    """第二个客户端实例直接采用共享文件里的有效 token，不再触发刷新（多 worker 不互踢）。"""
    import dataclasses

    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        if request.url.path == "/api/accesstoken":
            return httpx.Response(200, json={"success": True, "code": 0, "data": {
                "accessToken": "TOK-SHARED", "expiresIn": int(time.time() * 1000) + 86400000}})
        return httpx.Response(200, json={"success": True, "code": 0, "data": None})

    cache = tmp_path / "tok.json"
    base = _settings(monkeypatch)
    s1 = dataclasses.replace(base, token_cache_path=str(cache))
    s2 = dataclasses.replace(base, token_cache_path=str(cache))

    a = TianxuClient(httpx.AsyncClient(transport=httpx.MockTransport(handler)), s1)
    b = TianxuClient(httpx.AsyncClient(transport=httpx.MockTransport(handler)), s2)
    t1 = await a.get_access_token()   # 实例 A 刷新并写共享文件
    t2 = await b.get_access_token()   # 实例 B 直接采用共享缓存
    assert t1 == t2 == "TOK-SHARED"
    assert calls.count("/api/accesstoken") == 1  # 只刷新一次
    await a._http.aclose()
    await b._http.aclose()


# MARK: - prdId 透传校验（权威来源迁移到客户端：App 的 spec.json）


@pytest.mark.asyncio
async def test_forward_rejects_missing_prd_id(monkeypatch):
    """缺少 prdId 的请求本地拦截（9004），且不发出任何上游请求。

    服务端不再补 prdId：客户端没带就必须立刻失败，否则带着空值打上游只能拿到
    「310016 没有产品数据权限」这类无法区分原因的错误，污染上游日志且难以定位。
    """
    calls = []
    client = httpx.AsyncClient(transport=_token_transport(calls))
    tx = TianxuClient(client, _settings(monkeypatch))
    with pytest.raises(TianxuError) as ei:
        await tx.forward("commerce_account_service/api/account/login", {}, {})
    assert ei.value.code == CODE_INVALID_REQUEST
    assert "prdId" in ei.value.msg
    assert calls == []  # 连 token 刷新都没触发（校验先于取 token）
    await client.aclose()


@pytest.mark.asyncio
async def test_forward_rejects_blank_prd_id(monkeypatch):
    """prdId 为空白串时同样拦截（防 spec.json 里留空或误留空格）。"""
    client = httpx.AsyncClient(transport=_token_transport([]))
    tx = TianxuClient(client, _settings(monkeypatch))
    with pytest.raises(TianxuError) as ei:
        await tx.forward("any/path", {"prdId": "  "}, {})
    assert ei.value.code == CODE_INVALID_REQUEST
    await client.aclose()


@pytest.mark.asyncio
async def test_forward_normalizes_numeric_prd_id(monkeypatch):
    """客户端把 prdId 传成数字时，发往天枢的 Authorization 头里必须是字符串。"""
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(dict(request.headers))
        if request.url.path == "/api/accesstoken":
            return httpx.Response(200, json={"success": True, "code": 0, "data": {
                "accessToken": "TOK-1", "expiresIn": int(time.time() * 1000) + 86400000}})
        return httpx.Response(200, json={"success": True, "code": 0, "data": None})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    tx = TianxuClient(client, _settings(monkeypatch))
    await tx.forward("commerce_account_service/api/account/login", {"prdId": 1234501}, {})
    sent = json.loads(calls[1]["authorization"])  # calls[0] 是取 token 的请求
    assert sent["prdId"] == "1234501"
    await client.aclose()


@pytest.mark.asyncio
async def test_forward_accepts_any_prd_id(monkeypatch):
    """任意 prdId 都放行（服务端零配置服务任意 App，不做产品白名单）。"""
    client = httpx.AsyncClient(transport=_token_transport([]))
    tx = TianxuClient(client, _settings(monkeypatch))
    for prd in (PRD, "4115202", "9999999"):
        resp = await tx.forward("commerce_account_service/api/account/login", {"prdId": prd}, {})
        assert resp["code"] == 0, prd
    await client.aclose()
