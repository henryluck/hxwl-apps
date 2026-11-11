"""测试配置：为测试环境提供默认的凭证与加密密钥，避免因环境变量缺失而报错。"""
import os

# 测试环境默认提供占位凭证（避免测试因凭证缺失而报错）
os.environ.setdefault("TIANXU_APP_KEY", "test_key")
os.environ.setdefault("TIANXU_APP_SECRET", "test_secret")
os.environ.setdefault("TIANXU_ENV", "test")
os.environ.setdefault("AES_KEY", "7JkKJHW075iEdXbH")
os.environ.setdefault("AES_IV", "7JkKJHW075iEdXbH")
# LLM 对话测试默认值（覆盖本地 .env 的真实 Key，测试绝不外呼）
os.environ.setdefault("SILICONFLOW_API_KEY", "test_sk")
os.environ.setdefault("SILICONFLOW_MODEL", "Qwen/Qwen3.5-4B")
# 天枢 token 共享缓存测试隔离：置空（仅进程内缓存），需要验证共享行为的用例自行启用
os.environ["TOKEN_CACHE_PATH"] = ""
# Token provider 测试隔离：置空本地 .env 的真实配置，避免测试外呼真实 provider；
# 需要验证 provider 链路的用例自行 monkeypatch
os.environ["TOKEN_API_URL"] = ""
os.environ["TOKEN_API_KEY"] = ""
# 和风天气测试隔离：置空本地 .env 的真实配置（置空而非删除——load_dotenv 不覆盖已存在的变量），
# 「默认未配置」类用例不受影响；需要配置的用例自建 Settings
for _k in ("QWEATHER_KID", "QWEATHER_PROJECT_ID", "QWEATHER_API_HOST",
           "QWEATHER_PRIVATE_KEY_PATH"):
    os.environ[_k] = ""
