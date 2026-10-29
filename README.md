# App Backend API Server

客户端请求代理服务：解密客户端 AES-128-CBC 密文请求，重构为上游明文请求并转发，再把上游响应统一重映射为本服务包络返回。

## 响应包络

所有 JSON 接口（除 SSE 流）统一返回：

```json
{"ok": true,  "code": 0,    "message": "",       "result": { ...业务数据... }}
{"ok": false, "code": 9001, "message": "请求解密失败"}
```

- 成功：`ok=true`、`code=0`、`result` 为业务数据
- 失败：`ok=false`、`code` 为错误码、无 `result`
- 上游的 `{success, code, msg, data}` 由 `remap_upstream` 转为上述形状后返回，客户端只见到一种包络
- 上游业务错误码（如 `310002`、`310003`）原样透传在 `code` 字段

## 配置

1. `cp .env.example .env`
2. 在 `.env` 填入 `TIANXU_APP_KEY` / `TIANXU_APP_SECRET`（上游开发者后台获取）。
3. `TIANXU_ENV`：`test`（open-test）/ `prod`（open-api）；天枢基础地址可用 `TIANXU_BASE_URL_TEST` / `TIANXU_BASE_URL_PROD` 覆盖。
4. **prdId 由客户端透传**（App 的 `spec.json → integrations.edge.prdId` 为唯一权威来源，服务端不覆盖、也不做产品白名单），一台 server 零配置可同时服务多个 App；客户端未带 prdId 时服务端本地拦截为 `9004`。
   当前接入的产品线（2026-10-27 确认）：`4115206`（智能卫星导航 com.hxwl.wxdh）/ `4115205`（另一产品线）——**共用本 server 与同一份 AES 密钥**。
5. `AES_KEY` / `AES_IV`：客户端信封的 AES-128 密钥/偏移（16 字节 ASCII），须与客户端 `spec.json` 一致。**勿复用任何旧工程密钥，务必重新生成。** 换密钥时所有共用此 server 的 App 必须同步更新 spec.json 后一起发版。
6. 天气：`QWEATHER_KID` / `QWEATHER_PROJECT_ID` / `QWEATHER_API_HOST` / `QWEATHER_PRIVATE_KEY_PATH`（Ed25519 私钥仅在服务端）。
7. 对话：`SILICONFLOW_API_KEY`（仅服务端持有，绝不下发客户端）。

## 启动

```bash
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

启动后访问 `http://127.0.0.1:8000/docs` 查看全部接口（需 `.env` 设 `DOCS_ENABLED=true`；默认屏蔽，生产等非本地环境务必保持关闭）。

## 接口（19 个，客户端把占位符替换为对应真实地址）

| 客户端占位符 | 真实路径 |
|---|---|
| 登录-URL | `POST /api/v1/session/start` |
| 归因-URL | `POST /api/v1/install/attribute` |
| 上报数盟id-URL | `POST /api/v1/device/union` |
| 查询商品列表-URL | `POST /api/v1/store/catalog` |
| 商品下单-URL | `POST /api/v1/store/order` |
| 恢复购买-URL | `POST /api/v1/store/restore` |
| 验单-URL | `POST /api/v1/store/verify` |
| 上报支付状态-URL | `POST /api/v1/store/state` |
| 关键行为回传-URL | `POST /api/v1/action/report` |
| 上报埋点数据-URL | `POST /api/v1/telemetry/event` |
| 上报用户属性-URL | `POST /api/v1/telemetry/profile` |
| 埋点批量事件-URL | `POST /api/v1/telemetry/event/batch` |
| 订阅策略-URL | `POST /api/v1/paywall/strategy` |
| 意见反馈-URL | `POST /api/v1/support/feedback`（本地 SQLite 持久化） |
| AI对话-URL | `POST /api/v1/assistant/chat`（LLM 流式转发） |
| 天气-URL | `POST /api/v1/forecast/now`、`/24h`、`/7d`（天气上游代理） |
| 高程-URL | `POST /api/v1/terrain/height`（高程服务代理） |

### AI 对话接口（流式）

- 请求：与其他接口一致的 AES 加密信封，`data` 内为 `{"messages": [{"role": "system|user|assistant", "content": "..."}], "model": "可选，须在白名单内"}`
- 响应：`text/event-stream`（SSE），原样透传上游 OpenAI 兼容事件（`data: {...}` … `data: [DONE]`）
- 流开始前失败：HTTP 200 + 标准错误信封；流中途失败：流内追加 `data: {"error":{...}}` 后以 `data: [DONE]` 收尾
- 上游模型/Key/白名单/超时由服务端 `.env` 配置（`SILICONFLOW_*`、`LLM_TIMEOUT_SEC`），Key 绝不下发给客户端
- 历史模式（`CHAT_HISTORY_MODE`）：`full`=全量历史发上游（默认）/ `current_only`=只发当前问题
- 限流：每设备默认 10 次/分钟 + 200 次/天（`RATE_LIMIT_PER_MIN/DAY`），超限返回 9007

## 错误码

| code | 含义 |
|---|---|
| 0 | 成功 |
| 9000 | 本 server 内部错误 |
| 9001 | 请求解密失败 |
| 9002 | 上游凭证未配置 |
| 9003 | 上游不可达（网络失败或响应非 JSON） |
| 9004 | 请求业务参数缺失或类型错误 |
| 9005 | 对话上游 Key 未配置 |
| 9006 | 对话上游不可达 |
| 9007 | 对话请求超过限流阈值 |
| 9010 | 领域上游接口失败（天气/高程） |
| 9011 | 天气上游凭证未配置 |
| 31xxxx | 上游业务错误码（原样透传） |

## 联调

```bash
python scripts/make_request.py --url http://127.0.0.1:8000/api/v1/session/start --data '{}'
```

## 测试

```bash
pytest -q
```

## 部署

```bash
./scripts/deploy_prod.sh   # 默认部署到 znwxdh.gzhuanxiwl.com（→ 123.57.186.174）
# 也可显式覆盖：
DEPLOY_HOST=<服务器公网IP> DEPLOY_DOMAIN=<生产域名> ./scripts/deploy_prod.sh
```

## 客户端替换清单

新 App 客户端内各 `@"xxx-URL"` 占位符替换为上表真实地址（前缀 `https://<你的域名>`）。
