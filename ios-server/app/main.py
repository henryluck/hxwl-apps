import asyncio
import logging
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles

from app.config import Settings, settings as default_settings
from app.crypto import CryptoError
from app.errors import CODE_DECRYPT_FAILED, CODE_INTERNAL, error_response
from app.ratelimit import SlidingWindowLimiter
from app.qweather import QWeatherClient
from app.routers import (account, attribution, chat, feedback, geo, iap,
                         paywall, statistics, weather)
from app.siliconflow import SiliconFlowClient
from app.storage import init_db
from app.tianxu import TianxuClient, TianxuError

logger = logging.getLogger("edge")

# AccessToken 集中管理：后台刷新间隔（秒）。本 server 作为消费方，
# 后台每 5 分钟从 provider 拉取 token 确保新鲜（缓存有效则不发 HTTP，
# 进入提前刷新窗口才真正拉取）。
_TOKEN_REFRESH_INTERVAL_SEC = 300  # 5 分钟


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用生命周期管理：启动时创建 HTTP 客户端和天枢客户端，关闭时清理资源"""
    http = httpx.AsyncClient(timeout=app.state.settings.tianxu_timeout_sec)
    app.state.http = http
    app.state.tianxu = TianxuClient(http, app.state.settings)
    app.state.siliconflow = SiliconFlowClient(http, app.state.settings)  # 复用连接池，超时按请求覆盖
    app.state.qweather = QWeatherClient(http, app.state.settings)  # 和风天气（未配置时路由层降级 9011）
    # 意见反馈：本地 SQLite，启动时建库建表
    app.state.feedback_db_path = app.state.settings.feedback_db_path
    await init_db(app.state.settings.feedback_db_path)
    logger.info("edge started: env=%s base=%s docs=%s",
                app.state.settings.tianxu_env, app.state.settings.tianxu_base_url,
                "on" if app.state.settings.docs_enabled else "off")

    # AccessToken 集中管理：本 server 作为消费方，后台每 5 分钟从 provider
    # 拉取 token 确保新鲜（缓存有效则不发 HTTP，进入提前刷新窗口才真正拉取）。
    token_task = asyncio.create_task(_token_refresher(app.state.tianxu))

    yield

    # 停止后台刷新任务
    token_task.cancel()
    try:
        await token_task
    except asyncio.CancelledError:
        pass
    # 关闭 HTTP 客户端连接
    await http.aclose()


async def _token_refresher(tianxu: TianxuClient) -> None:
    """后台定时从 provider 拉取天枢 AccessToken（每 5 分钟检查一次，仅进入提前刷新窗口才发 HTTP）。

    失败不退出：日志告警后继续等下一轮（provider 不可达恢复后自动恢复）。
    """
    while True:
        try:
            await tianxu.get_access_token()
        except TianxuError as e:
            logger.warning("token refresher: failed code=%s msg=%s", e.code, e.msg)
        except Exception as e:  # noqa: BLE001
            logger.warning("token refresher: unexpected %s", e)
        await asyncio.sleep(_TOKEN_REFRESH_INTERVAL_SEC)


def create_app(settings: Optional[Settings] = None,
               http_client: Optional[httpx.AsyncClient] = None) -> FastAPI:
    """创建 FastAPI 应用实例，配置异常处理器和路由挂载"""
    s = settings or default_settings
    # API 文档默认屏蔽（DOCS_ENABLED=true 才暴露）：非本地运行不泄漏接口结构，与 Nginx 层 404 形成双重防护
    app = FastAPI(
        title="Edge API",
        lifespan=lifespan,
        docs_url="/docs" if s.docs_enabled else None,
        redoc_url="/redoc" if s.docs_enabled else None,
        openapi_url="/openapi.json" if s.docs_enabled else None,
    )
    app.state.settings = s
    # AI 对话限流器（内存滑动窗：deviceId 优先/IP 兜底，分钟+日双窗口）
    app.state.chat_limiter = SlidingWindowLimiter(s.rate_limit_per_minute, s.rate_limit_per_day)
    # 高程永久缓存（高程不随时间变：key=round4 坐标序列，进程内存）
    app.state.elev_cache = {}

    # 便于测试注入已构造的 client；否则 lifespan 会新建
    if http_client is not None:
        # 直接设置状态供测试使用，不关闭外部 client
        app.state.http = http_client
        app.state.tianxu = TianxuClient(http_client, s)
        app.state.siliconflow = SiliconFlowClient(http_client, s)
        app.state.qweather = QWeatherClient(http_client, s)

    # 加密异常处理器：返回 HTTP 200 + 解密失败错误码
    @app.exception_handler(CryptoError)
    async def _crypto_error_handler(request: Request, exc: CryptoError):
        """加密错误异常处理器：返回 HTTP 200 + 解密失败错误码"""
        logger.warning("decrypt failed: %s", exc)
        # 对外只给固定文案：异常原文可能含密钥长度/填充块/字段名等内部细节（信息泄露 + 指纹）
        return JSONResponse(status_code=200, content=error_response(CODE_DECRYPT_FAILED, "请求解密失败"))

    # 上游异常处理器：返回 HTTP 200 + 上游错误码（上游业务文案对客户端有意义，原样透传）
    @app.exception_handler(TianxuError)
    async def _tianxu_error_handler(request: Request, exc: TianxuError):
        """上游错误异常处理器：返回 HTTP 200 + 上游错误码"""
        logger.warning("upstream error: %s", exc.msg)
        return JSONResponse(status_code=200, content=error_response(exc.code, exc.msg))

    # 内部异常处理器：返回 HTTP 200 + 内部错误码
    @app.exception_handler(Exception)
    async def _internal_error_handler(request: Request, exc: Exception):
        """内部错误异常处理器：返回 HTTP 200 + 内部错误码"""
        logger.exception("internal error")
        # 同上：异常原文（含类名/路径/库版本）只进日志，不下发客户端
        return JSONResponse(status_code=200, content=error_response(CODE_INTERNAL, "内部错误"))

    # 请求关联日志中间件：为每个 /api/v1 请求生成 rid，串联「入口→天枢转发→响应」全链路，便于真机联调定位
    @app.middleware("http")
    async def _request_id_middleware(request: Request, call_next):
        rid = request.headers.get("x-request-id") or uuid.uuid4().hex[:8]  # 复用客户端 rid 或生成
        request.state.rid = rid
        if not request.url.path.startswith("/api/v1/"):  # 静态/docs 请求不记入口日志
            return await call_next(request)
        start = time.time()
        logger.info("[%s] -> %s %s", rid, request.method, request.url.path)
        response = await call_next(request)
        ms = int((time.time() - start) * 1000)
        # SSE 流式响应不做全量缓冲（否则会把 LLM 流攒成整包、破坏逐块下发），只记状态码
        if "text/event-stream" in response.headers.get("content-type", ""):
            logger.info("[%s] <- %s %sms sse-stream", rid, response.status_code, ms)
            return response
        # 读取返回给 app 端的响应体并记录；body_iterator 被消费后需重建响应再返回，否则客户端收到空体
        body = b"".join([chunk async for chunk in response.body_iterator])
        logger.info("[%s] <- %s %sms body=%s", rid, response.status_code, ms,
                    body.decode("utf-8", "ignore"))
        return Response(content=body, status_code=response.status_code,
                        headers=dict(response.headers), media_type=response.media_type)

    # 挂载各业务路由模块
    app.include_router(account.router)
    app.include_router(attribution.router)
    app.include_router(chat.router)
    app.include_router(feedback.router)
    app.include_router(geo.router)
    app.include_router(iap.router)
    app.include_router(paywall.router)
    app.include_router(statistics.router)
    app.include_router(weather.router)

    # 静态 HTML：把 .html 等文件放进 app/static/，即可通过 http://<host>:8000/<文件名> 访问
    # 挂载在根路径并放在所有 API 路由之后，确保 /api/v1/* 与 /docs 等仍优先匹配；html=True 支持 / 目录索引
    static_dir = Path(__file__).resolve().parent / "static"
    if not static_dir.exists():
        static_dir.mkdir(parents=True, exist_ok=True)
    app.mount("/", StaticFiles(directory=str(static_dir), html=True), name="static")
    return app


settings = default_settings
logging.basicConfig(level=settings.log_level)
app = create_app()
