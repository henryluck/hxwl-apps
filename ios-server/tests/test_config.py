"""测试配置加载：验证环境变量对天枢 base URL、凭证状态、AES密钥、产品ID的读取逻辑。"""
import os

from app.config import load_settings


def test_base_url_test_env(monkeypatch):
    """验证测试环境下选择正确的天枢 base URL。"""
    monkeypatch.setenv("TIANXU_ENV", "test")
    monkeypatch.delenv("TIANXU_BASE_URL_TEST", raising=False)
    s = load_settings()
    assert s.tianxu_base_url == "https://open-test.yingzhongshare.com"


def test_base_url_prod_env(monkeypatch):
    """验证生产环境下选择正确的天枢 base URL。"""
    monkeypatch.setenv("TIANXU_ENV", "prod")
    monkeypatch.delenv("TIANXU_BASE_URL_PROD", raising=False)
    s = load_settings()
    assert s.tianxu_base_url == "https://open-api.yingzhongshare.com"


def test_base_url_env_override(monkeypatch):
    """验证上游 base URL 可用环境变量覆盖为真实地址。"""
    monkeypatch.setenv("TIANXU_ENV", "test")
    monkeypatch.setenv("TIANXU_BASE_URL_TEST", "https://upstream-test.example.com")
    assert load_settings().tianxu_base_url == "https://upstream-test.example.com"
    monkeypatch.setenv("TIANXU_ENV", "prod")
    monkeypatch.setenv("TIANXU_BASE_URL_PROD", "https://upstream-prod.example.com")
    assert load_settings().tianxu_base_url == "https://upstream-prod.example.com"


def test_has_credentials_false_for_placeholder(monkeypatch):
    """验证占位凭证（TODO_xxx/TODO_yyy）会被识别为无有效凭证。"""
    monkeypatch.setenv("TIANXU_APP_KEY", "TODO_xxx")
    monkeypatch.setenv("TIANXU_APP_SECRET", "TODO_yyy")
    assert load_settings().has_credentials is False


def test_has_credentials_true_when_filled(monkeypatch):
    """验证真实凭证会被识别为有效凭证。"""
    monkeypatch.setenv("TIANXU_APP_KEY", "real_key")
    monkeypatch.setenv("TIANXU_APP_SECRET", "real_secret")
    assert load_settings().has_credentials is True


def test_aes_defaults(monkeypatch):
    """验证AES密钥缺失时使用占位默认值（非真实密钥）。"""
    monkeypatch.delenv("AES_KEY", raising=False)
    monkeypatch.delenv("AES_IV", raising=False)
    s = load_settings()
    assert s.aes_key == "CHANGE_ME_AES_KEY_16"
    assert s.aes_iv == "CHANGE_ME_AES_IV_16"


def test_siliconflow_defaults(monkeypatch):
    """验证 SiliconFlow 配置缺省值：默认模型、官方地址、白名单仅含默认模型。"""
    for name in ("SILICONFLOW_API_KEY", "SILICONFLOW_BASE_URL", "SILICONFLOW_MODEL",
                 "SILICONFLOW_ALLOWED_MODELS", "LLM_TIMEOUT_SEC"):
        monkeypatch.delenv(name, raising=False)
    s = load_settings()
    assert s.siliconflow_api_key == ""
    assert s.siliconflow_base_url == "https://api.siliconflow.cn/v1"
    assert s.siliconflow_model == "Qwen/Qwen3.5-4B"
    assert s.llm_timeout_sec == 120.0
    # 白名单默认仅允许默认模型，防止客户端刷昂贵模型
    assert s.siliconflow_allowed_models == ("Qwen/Qwen3.5-4B",)


def test_siliconflow_env_overrides(monkeypatch):
    """验证 SiliconFlow 配置可被环境变量覆盖，白名单按逗号解析且始终包含默认模型。"""
    monkeypatch.setenv("SILICONFLOW_API_KEY", "sk-test")
    monkeypatch.setenv("SILICONFLOW_BASE_URL", "https://example.com/v1")
    monkeypatch.setenv("SILICONFLOW_MODEL", "Qwen/Qwen3.5-8B")
    monkeypatch.setenv("SILICONFLOW_ALLOWED_MODELS", "Qwen/Qwen3.5-4B, deepseek-ai/DeepSeek-V3 , ")
    monkeypatch.setenv("LLM_TIMEOUT_SEC", "60")
    s = load_settings()
    assert s.siliconflow_api_key == "sk-test"
    assert s.siliconflow_base_url == "https://example.com/v1"
    assert s.siliconflow_model == "Qwen/Qwen3.5-8B"
    assert s.llm_timeout_sec == 60.0
    # 逗号分隔、剔除空白；默认模型即使未列入也自动合并进白名单
    assert s.siliconflow_allowed_models == ("Qwen/Qwen3.5-4B", "deepseek-ai/DeepSeek-V3",
                                            "Qwen/Qwen3.5-8B")


def test_siliconflow_max_tokens(monkeypatch):
    """验证 max_tokens 默认 2048，可被环境变量覆盖。"""
    monkeypatch.delenv("SILICONFLOW_MAX_TOKENS", raising=False)
    assert load_settings().siliconflow_max_tokens == 2048
    monkeypatch.setenv("SILICONFLOW_MAX_TOKENS", "512")
    assert load_settings().siliconflow_max_tokens == 512


def test_siliconflow_enable_thinking(monkeypatch):
    """验证 enable_thinking 默认 false（短问答直接出答案），可被环境变量开启。"""
    monkeypatch.delenv("SILICONFLOW_ENABLE_THINKING", raising=False)
    assert load_settings().siliconflow_enable_thinking is False
    monkeypatch.setenv("SILICONFLOW_ENABLE_THINKING", "true")
    assert load_settings().siliconflow_enable_thinking is True


def test_rate_limit_defaults_and_env(monkeypatch):
    """验证限流默认 10 次/分钟、200 次/天，可被环境变量覆盖。"""
    monkeypatch.delenv("RATE_LIMIT_PER_MIN", raising=False)
    monkeypatch.delenv("RATE_LIMIT_PER_DAY", raising=False)
    s = load_settings()
    assert s.rate_limit_per_minute == 10
    assert s.rate_limit_per_day == 200
    monkeypatch.setenv("RATE_LIMIT_PER_MIN", "3")
    monkeypatch.setenv("RATE_LIMIT_PER_DAY", "50")
    s = load_settings()
    assert s.rate_limit_per_minute == 3
    assert s.rate_limit_per_day == 50


def test_chat_history_mode_default_and_env(monkeypatch):
    """验证对话历史模式默认 full，可被环境变量切换，非法值回落 full。"""
    monkeypatch.delenv("CHAT_HISTORY_MODE", raising=False)
    assert load_settings().chat_history_mode == "full"
    monkeypatch.setenv("CHAT_HISTORY_MODE", "current_only")
    assert load_settings().chat_history_mode == "current_only"
    monkeypatch.setenv("CHAT_HISTORY_MODE", "  Current_Only  ")  # 大小写/空白容错
    assert load_settings().chat_history_mode == "current_only"
    monkeypatch.setenv("CHAT_HISTORY_MODE", "typo")  # 非法值回落 full（保持现有行为）
    assert load_settings().chat_history_mode == "full"


def test_token_api_url_and_key_default_and_env(monkeypatch):
    """验证 TOKEN_API_URL/TOKEN_API_KEY 默认空（未配置），可被环境变量设置。"""
    monkeypatch.delenv("TOKEN_API_URL", raising=False)
    monkeypatch.delenv("TOKEN_API_KEY", raising=False)
    s = load_settings()
    assert s.token_api_url == ""  # 空 = 未配置 provider，get_access_token 抛 9002
    assert s.token_api_key == ""
    monkeypatch.setenv("TOKEN_API_URL", "https://provider.example.com/api/accesstoken")
    monkeypatch.setenv("TOKEN_API_KEY", "my-secret-key")
    s = load_settings()
    assert s.token_api_url == "https://provider.example.com/api/accesstoken"
    assert s.token_api_key == "my-secret-key"
