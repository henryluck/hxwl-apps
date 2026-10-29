import os
from dataclasses import dataclass

from dotenv import load_dotenv

load_dotenv()

_DEFAULT_LLM_MODEL = "Qwen/Qwen3.5-4B"  # SiliconFlow 默认对话模型（默认值与白名单兜底共用，防单边漂移）

_CHAT_HISTORY_MODES = ("full", "current_only")  # 对话历史模式：全量携带 / 只发当前问题


def _parse_chat_history_mode(raw: str) -> str:
    """解析对话历史模式：full（默认，全量历史）/ current_only（只发当前问题）。

    非法值一律回落 full：拼错配置时保持既有行为（携带历史），不会意外丢上下文。

    Args:
        raw: CHAT_HISTORY_MODE 原始值

    Returns:
        合法模式字符串（full 或 current_only）
    """
    v = (raw or "").strip().lower()
    return v if v in _CHAT_HISTORY_MODES else "full"


def _parse_allowed_models(default_model: str, raw: str) -> tuple:
    """解析模型白名单：逗号分隔、剔除空白，并确保默认模型始终在白名单内。

    Args:
        default_model: 默认模型名（必须始终可用，作为客户端未指定时的回落值）
        raw: SILICONFLOW_ALLOWED_MODELS 原始值（逗号分隔模型名，可为空）

    Returns:
        模型名元组（顺序保持配置顺序，默认模型追加在末尾若未显式列入）
    """
    allowed = tuple(m.strip() for m in raw.split(",") if m.strip())  # 去空白项
    if default_model not in allowed:
        allowed = allowed + (default_model,)  # 默认模型兜底加入白名单
    return allowed


@dataclass(frozen=True)
class Settings:
    """应用配置数据类（不可变）"""
    tianxu_app_key: str  # 天枢 AppKey
    tianxu_app_secret: str  # 天枢 AppSecret
    tianxu_env: str  # 环境：test/prod
    server_host: str  # 服务器监听地址
    server_port: int  # 服务器监听端口
    aes_key: str  # AES 加密密钥（需 16 字节）
    aes_iv: str  # AES 加密 IV（需 16 字节）
    access_token_refresh_lead_sec: int  # AccessToken 提前刷新秒数（避免过期）
    tianxu_timeout_sec: float  # 天枢 API 请求超时秒数
    log_level: str  # 日志级别
    feedback_db_path: str  # 意见反馈 SQLite 数据库路径
    docs_enabled: bool  # 是否暴露 /docs /redoc /openapi.json（默认关：仅本地开发显式开启）
    siliconflow_api_key: str  # SiliconFlow API Key（服务端持有，绝不下发给客户端）
    siliconflow_base_url: str  # SiliconFlow OpenAI 兼容 API 基础 URL
    siliconflow_model: str  # 默认对话模型（客户端未指定时使用）
    siliconflow_allowed_models: tuple  # 允许客户端使用的模型白名单（始终包含默认模型）
    siliconflow_max_tokens: int  # 单次响应 token 上限（控制上游成本）
    siliconflow_enable_thinking: bool  # 思考模式开关（false=thinking disabled，直接出答案，首字节更快）
    llm_timeout_sec: float  # LLM 流式请求读超时（秒）
    rate_limit_per_minute: int  # 每设备每分钟对话上限（0=不限）
    rate_limit_per_day: int  # 每设备每日对话上限（0=不限）
    chat_history_mode: str  # 对话历史模式：full=全量携带历史 / current_only=只发当前问题
    token_cache_path: str  # 天枢 AccessToken 共享缓存文件路径（空=仅进程内缓存）
    qweather_kid: str  # 和风天气凭证 kid（JWT 头，控制台「凭证管理」获取）
    qweather_project_id: str  # 和风项目 ID（JWT sub）
    qweather_api_host: str  # 和风 API 主机（如 api.qweather.com；专属版为各自域名）
    qweather_private_key_path: str  # Ed25519 私钥 PEM 路径（服务端持有，绝不下发）
    token_api_url: str  # Token provider 地址（如 https://qnsjgj.juliangshuke.com/api/accesstoken）
    token_api_key: str  # 向 provider 拉取 token 的 X-API-Key 鉴权密钥（空=无法刷新）

    @property
    def tianxu_base_url(self) -> str:
        """获取天枢 API 基础 URL（优先取环境变量覆盖；按环境回落到官方生产/测试地址）"""
        if self.tianxu_env == "prod":
            return os.getenv(
                "TIANXU_BASE_URL_PROD",
                "https://open-api.yingzhongshare.com")  # 生产环境
        return os.getenv(
            "TIANXU_BASE_URL_TEST",
            "https://open-test.yingzhongshare.com")  # 测试环境

    @property
    def has_credentials(self) -> bool:
        """检查是否已配置有效的天枢凭证（非空且非 TODO_ 开头）"""
        def ok(v: str) -> bool:
            return bool(v) and not v.startswith("TODO_")
        return ok(self.tianxu_app_key) and ok(self.tianxu_app_secret)


def load_settings() -> Settings:
    """从环境变量加载配置并返回 Settings 实例"""
    return Settings(
        tianxu_app_key=os.getenv("TIANXU_APP_KEY", ""),  # 从环境变量读取天枢 AppKey
        tianxu_app_secret=os.getenv("TIANXU_APP_SECRET", ""),  # 从环境变量读取天枢 AppSecret
        tianxu_env=os.getenv("TIANXU_ENV", "test"),  # 环境（默认 test）
        server_host=os.getenv("SERVER_HOST", "0.0.0.0"),  # 服务器地址（默认监听所有网卡）
        server_port=int(os.getenv("SERVER_PORT", "8000")),  # 服务器端口（默认 8000）
        aes_key=os.getenv("AES_KEY", "CHANGE_ME_AES_KEY_16"),  # AES 密钥（16 字节占位默认值，生产环境必须从环境变量读取真实密钥）
        aes_iv=os.getenv("AES_IV", "CHANGE_ME_AES_IV_16"),  # AES IV（16 字节占位默认值，生产环境必须从环境变量读取真实 IV）
        access_token_refresh_lead_sec=int(os.getenv("ACCESS_TOKEN_REFRESH_LEAD_SEC", "600")),  # Token 提前刷新时间（秒）
        tianxu_timeout_sec=float(os.getenv("TIANXU_TIMEOUT_SEC", "10")),  # 天枢 API 超时（秒）
        log_level=os.getenv("LOG_LEVEL", "INFO"),  # 日志级别
        feedback_db_path=os.getenv("FEEDBACK_DB_PATH", "data/feedback.db"),  # 意见反馈 SQLite 路径
        # API 文档开关：默认 false（非本地运行一律屏蔽 /docs /redoc /openapi.json）
        docs_enabled=os.getenv("DOCS_ENABLED", "false").strip().lower() in ("1", "true", "yes", "on"),
        siliconflow_api_key=os.getenv("SILICONFLOW_API_KEY", ""),  # SiliconFlow API Key
        siliconflow_base_url=os.getenv("SILICONFLOW_BASE_URL", "https://api.siliconflow.cn/v1"),  # 官方地址
        siliconflow_model=os.getenv("SILICONFLOW_MODEL", _DEFAULT_LLM_MODEL),  # 默认模型
        siliconflow_allowed_models=_parse_allowed_models(
            os.getenv("SILICONFLOW_MODEL", _DEFAULT_LLM_MODEL),
            os.getenv("SILICONFLOW_ALLOWED_MODELS", "")),  # 模型白名单（逗号分隔）
        siliconflow_max_tokens=int(os.getenv("SILICONFLOW_MAX_TOKENS", "2048")),  # 单响应 token 上限
        # 推理模型（如 Qwen3 系）默认先输出思考链，既拖慢首字节又占 token 预算；
        # 本场景是短问答，默认关闭思考直接出答案（与客户端收敛到代理前的行为一致）
        siliconflow_enable_thinking=os.getenv("SILICONFLOW_ENABLE_THINKING", "false").strip().lower()
        in ("1", "true", "yes", "on"),
        llm_timeout_sec=float(os.getenv("LLM_TIMEOUT_SEC", "120")),  # LLM 流式读超时（秒）
        rate_limit_per_minute=int(os.getenv("RATE_LIMIT_PER_MIN", "10")),  # 每设备每分钟对话上限
        rate_limit_per_day=int(os.getenv("RATE_LIMIT_PER_DAY", "200")),  # 每设备每日对话上限
        chat_history_mode=_parse_chat_history_mode(os.getenv("CHAT_HISTORY_MODE", "full")),  # 对话历史模式
        # 天枢 token 共享缓存：多 worker 部署下所有 worker 共用同一 AccessToken（防止
        # 一家 refresh 使其他 worker 的 token 失效互踢）；空字符串=关闭共享（仅进程内）
        token_cache_path=os.getenv("TOKEN_CACHE_PATH", "data/.tianxu_token.json"),
        # 和风天气（四项缺任一 → /api/v1/forecast/* 降级 9011 天气服务未配置）
        qweather_kid=os.getenv("QWEATHER_KID", ""),  # 凭证 kid
        qweather_project_id=os.getenv("QWEATHER_PROJECT_ID", ""),  # 项目 ID
        qweather_api_host=os.getenv("QWEATHER_API_HOST", ""),  # API 主机
        qweather_private_key_path=os.getenv("QWEATHER_PRIVATE_KEY_PATH", ""),  # 私钥 PEM 路径
        # AccessToken 集中管理：本 server 作为消费方，从 provider 拉取 token，
        # 不再自己调天枢 refresh（避免多实例互踢 310002）。
        # provider 地址 + X-API-Key 两项缺任一 → get_access_token 抛 9002。
        token_api_url=os.getenv("TOKEN_API_URL", ""),  # provider 地址
        token_api_key=os.getenv("TOKEN_API_KEY", ""),  # 鉴权密钥
    )


# 全局配置实例（启动时加载）
settings = load_settings()
