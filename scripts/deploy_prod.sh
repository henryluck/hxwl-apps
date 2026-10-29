#!/usr/bin/env bash
#
# Edge API 生产部署脚本（幂等，可重复执行）
#
# 结构：本地打包 → scp 上传 → 远端执行 deploy_remote.sh
#       （远端脚本用 **quoted** heredoc 落盘，本地不做展开，避免嵌套 heredoc 的变量转义陷阱）
#
# 用法：
#   ./scripts/deploy_prod.sh
#   SSH_OPTS="-i ~/.ssh/deploy_key" ./scripts/deploy_prod.sh
#   SKIP_DNS_CHECK=1 ./scripts/deploy_prod.sh      # 跳过 DNS 预检（同时跳过证书签发）
#
# 可覆盖的环境变量：
#   DEPLOY_HOST     目标服务器公网 IP   （默认 123.57.186.174）
#   DEPLOY_USER     SSH 登录用户        （默认 root）
#   DEPLOY_DOMAIN   生产域名            （默认 znwxdh.gzhuanxiwl.com）
#   APP_DIR         远端安装目录        （默认 /opt/edge-api）
#   APP_USER        远端运行用户        （默认 edgeapp）
#   SERVICE         systemd 服务名      （默认 edge-api）
#   PYTHON_BIN      指定远端 Python（>=3.9；默认自动探测/安装）
#   SSH_OPTS        额外 ssh 选项（如 -i /path/to/key）
#   SKIP_DNS_CHECK  1 = 跳过 DNS 预检
#   DNS_SERVER      DNS 预检使用的公共 DNS（默认 223.5.5.5）
#
# 前置条件：
#   1. 域名 A 记录已指向 DEPLOY_HOST（否则 certbot 无法签发，脚本会跳过 HTTPS）
#   2. 本机可 SSH 登录目标服务器（该用户具备免密 sudo，或本身是 root）
#
set -euo pipefail

DEPLOY_HOST="${DEPLOY_HOST:-123.57.186.174}"
DEPLOY_USER="${DEPLOY_USER:-root}"
DEPLOY_DOMAIN="${DEPLOY_DOMAIN:-znwxdh.gzhuanxiwl.com}"
APP_DIR="${APP_DIR:-/opt/edge-api}"
APP_USER="${APP_USER:-edgeapp}"
SERVICE="${SERVICE:-edge-api}"
PYTHON_BIN="${PYTHON_BIN:-}"
SSH_OPTS="${SSH_OPTS:-}"
SKIP_DNS_CHECK="${SKIP_DNS_CHECK:-0}"

# 默认部署目标：znwxdh.gzhuanxiwl.com → 123.57.186.174（可用环境变量覆盖）
[ -n "$DEPLOY_HOST" ]   || { printf '[x] 必须设置 DEPLOY_HOST（目标服务器公网 IP）\n' >&2; exit 1; }
[ -n "$DEPLOY_DOMAIN" ] || { printf '[x] 必须设置 DEPLOY_DOMAIN（生产域名）\n' >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="/tmp/edge-deploy.$$"
TARBALL="$WORK/code.tar.gz"
ENVFILE="$WORK/edge-api.env"
REMOTE_SH="$WORK/deploy_remote.sh"

# 登录用户是 root 时不需要 sudo（RHEL/CentOS 上可能根本没装 sudo）
if [ "$DEPLOY_USER" = "root" ]; then SUDO=""; else SUDO="sudo"; fi

SSH_BASE=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)
if [ -n "$SSH_OPTS" ]; then
    # shellcheck disable=SC2206
    SSH_BASE+=($SSH_OPTS)
fi
TARGET="$DEPLOY_USER@$DEPLOY_HOST"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }
cleanup() { [ "${KEEP_WORK:-0}" = "1" ] || rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK"
echo "工作目录: $WORK （KEEP_WORK=1 可保留以便检查生成的远端脚本）"

# ================================================================ 0. 预检
log "0/5 预检"

[ -f "$REPO_ROOT/app/main.py" ] || die "未找到 $REPO_ROOT/app/main.py —— 请在项目根目录内运行本脚本"
[ -f "$REPO_ROOT/.env" ]        || die "未找到 $REPO_ROOT/.env —— 请先按 .env.example 配置生产凭证"

CERTBOT_OK=0
if [ "$SKIP_DNS_CHECK" = "1" ]; then
    warn "已跳过 DNS 预检（SKIP_DNS_CHECK=1）→ 本次不签发证书"
else
    DNS_SERVER="${DNS_SERVER:-223.5.5.5}"  # DNS 预检用公共 DNS（外部服务，可覆盖）
    RESOLVED="$(dig +short "$DEPLOY_DOMAIN" A @"$DNS_SERVER" 2>/dev/null | tail -1 || true)"
    if [ -z "$RESOLVED" ]; then
        warn "${DEPLOY_DOMAIN} 无 A 记录 → 跳过证书签发"
        warn "请先添加：A  ${DEPLOY_DOMAIN}  →  ${DEPLOY_HOST}"
    elif [ "$RESOLVED" != "$DEPLOY_HOST" ]; then
        warn "${DEPLOY_DOMAIN} 解析到 ${RESOLVED}，与目标机 ${DEPLOY_HOST} 不一致 → 跳过证书签发"
    else
        log "DNS 校验通过：${DEPLOY_DOMAIN} → ${RESOLVED}"
        CERTBOT_OK=1
    fi
fi

log "SSH 连通性测试：$TARGET"
ssh "${SSH_BASE[@]}" "$TARGET" 'echo SSH_OK; id -un; head -2 /etc/os-release 2>/dev/null; python3 -V 2>&1 || true' \
    || die "SSH 登录失败：请确认用户名/密码（或密钥）与安全组 22 端口"

# ================================================================ 1. 打包
log "1/5 打包代码"
tar czf "$TARBALL" -C "$REPO_ROOT" \
    --exclude='__pycache__' --exclude='*.pyc' --exclude='.DS_Store' \
    --exclude='._*' --exclude='.venv' --exclude='.venv313' --exclude='.git' \
    --exclude='.pytest_cache' --exclude='.omc' --exclude='.superpowers' \
    --exclude='docs/superpowers' \
    app requirements.txt README.md scripts keys
cp "$REPO_ROOT/.env" "$ENVFILE"
log "已打包 code $(du -h "$TARBALL" | cut -f1) / env $(du -h "$ENVFILE" | cut -f1)"

# ================================================================ 2. 生成远端脚本
# ⚠️ 下面用 quoted heredoc（'EOS'）：本地不做任何展开。
#    远端需要的参数由 ssh 命令行以环境变量注入（见 §4）。
log "2/5 生成远端脚本"
cat > "$REMOTE_SH" <<'EOS'
set -euo pipefail

echo "--- 远端环境 ---"
head -2 /etc/os-release 2>/dev/null || true
echo "APP_DIR=$APP_DIR  APP_USER=$APP_USER  SERVICE=$SERVICE  DOMAIN=$DEPLOY_DOMAIN"
echo "SUDO='$SUDO'  PYTHON_BIN='${PYTHON_BIN:-自动探测}'  CERTBOT_OK=$CERTBOT_OK"

PKG=""
if   command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
elif command -v yum     >/dev/null 2>&1; then PKG=yum
else echo "!! 未识别的包管理器（apt/dnf/yum 都没有），请手动安装 nginx / python3 / certbot"; exit 1
fi
echo "包管理器: $PKG"

# ---------------------------------------------------------------- A. 系统依赖
echo "--- A. 安装系统依赖 ---"
case "$PKG" in
  apt)
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -qq
    # 必需包：缺一即失败
    $SUDO apt-get install -y -qq nginx python3-venv python3-dev build-essential \
        certbot python3-certbot-nginx curl
    # 可选包：Ubuntu 26.04 起 dnsutils 被 bind9-dnsutils 取代（老包名会 MISSING）
    $SUDO apt-get install -y -qq dnsutils 2>/dev/null \
        || $SUDO apt-get install -y -qq bind9-dnsutils 2>/dev/null \
        || true
    ;;
  dnf)
    $SUDO dnf install -y nginx python3 python3-devel gcc certbot python3-certbot-nginx curl bind-utils \
        policycoreutils-python-utils || \
    $SUDO dnf install -y nginx python3 python3-devel gcc certbot python3-certbot-nginx curl bind-utils
    ;;
  yum)
    $SUDO yum install -y nginx python3 python3-devel gcc certbot python3-certbot-nginx curl bind-utils \
        policycoreutils-python || \
    $SUDO yum install -y nginx python3 python3-devel gcc certbot python3-certbot-nginx curl bind-utils
    ;;
esac
nginx -v 2>&1 | head -1 || true
$SUDO systemctl enable nginx >/dev/null 2>&1 || true

# ---------------------------------------------------------------- B. Python >= 3.9
# 依赖 fastapi>=0.110（需 3.8+）；tianxu.py 的 `tuple[str,int] | None` 已用 PEP 563 兜住。
# RHEL/CentOS 8 默认 python3 是 3.6，需要装更新的版本。
echo "--- B. 确定 Python (>=3.9) ---"
PY=""
if [ -n "${PYTHON_BIN:-}" ] && command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    PY="$PYTHON_BIN"
else
    for c in python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python3; do
        if command -v "$c" >/dev/null 2>&1 && \
           "$c" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
            PY="$c"; break
        fi
    done
fi

if [ -z "$PY" ]; then
    echo "未找到 >=3.9，尝试安装 …"
    case "$PKG" in
      apt) $SUDO apt-get install -y -qq python3.11 python3.11-venv || true ;;
      dnf) $SUDO dnf install -y python3.11 python3.11-devel || $SUDO dnf module install -y python39 || true ;;
      yum) $SUDO yum install -y python3.11 python3.11-devel || $SUDO yum install -y python39 || true ;;
    esac
    for c in python3.11 python3.10 python3.9; do
        if command -v "$c" >/dev/null 2>&1 && \
           "$c" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
            PY="$c"; break
        fi
    done
fi
[ -n "$PY" ] || { echo "!! 未找到 Python >= 3.9；请安装后重跑（可用 PYTHON_BIN=/path/to/python3.11 指定）"; exit 1; }
echo "使用 $PY : $("$PY" -V 2>&1)"

# ---------------------------------------------------------------- C. 用户 + 代码 + venv
echo "--- C. 部署代码到 $APP_DIR ---"
$SUDO id -u "$APP_USER" >/dev/null 2>&1 || \
    $SUDO useradd -r -m -d "$APP_DIR" -s /sbin/nologin "$APP_USER" 2>/dev/null || \
    $SUDO useradd -r -m -d "$APP_DIR" -s /usr/sbin/nologin "$APP_USER"

$SUDO mkdir -p "$APP_DIR/data"
if [ -f "$APP_DIR/.env" ]; then
    $SUDO cp -p "$APP_DIR/.env" "$APP_DIR/.env.bak.$(date +%Y%m%d%H%M%S)"
fi

$SUDO tar xzf /tmp/edge-api-code.tar.gz -C "$APP_DIR"
$SUDO cp /tmp/edge-api.env "$APP_DIR/.env"
$SUDO chmod 600 "$APP_DIR/.env"
$SUDO find "$APP_DIR" -name '._*' -delete 2>/dev/null || true

$SUDO chown -R "$APP_USER:$APP_USER" "$APP_DIR"
$SUDO chmod 755 "$APP_DIR"
$SUDO chmod -R a+rX "$APP_DIR/app"        # nginx worker 需读静态页

if [ ! -x "$APP_DIR/.venv/bin/python" ]; then
    $SUDO "$PY" -m venv "$APP_DIR/.venv"
fi
PIP_INDEX=""
[ "$PKG" = apt ] && PIP_INDEX="-i https://mirrors.aliyun.com/pypi/simple/"
$SUDO "$APP_DIR/.venv/bin/pip" install --upgrade pip -q $PIP_INDEX
$SUDO "$APP_DIR/.venv/bin/pip" install -q $PIP_INDEX -r "$APP_DIR/requirements.txt" gunicorn
echo "--- 依赖安装完成 ---"
$SUDO "$APP_DIR/.venv/bin/python" -c "import fastapi, uvicorn, gunicorn, httpx, jwt, Crypto; print('imports OK')"

# ---------------------------------------------------------------- D. systemd
echo "--- D. systemd unit ---"
$SUDO tee /etc/systemd/system/$SERVICE.service >/dev/null <<UNIT
[Unit]
Description=Edge API (FastAPI / Gunicorn UvicornWorker)
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/.venv/bin/gunicorn app.main:app -k uvicorn.workers.UvicornWorker --workers 3 --bind 127.0.0.1:8000 --timeout 60 --graceful-timeout 30 --keep-alive 5 --access-logfile - --error-logfile -
Restart=always
RestartSec=3
KillSignal=SIGQUIT
TimeoutStopSec=35
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
ReadWritePaths=$APP_DIR/data

[Install]
WantedBy=multi-user.target
UNIT

# ---------------------------------------------------------------- E. nginx（先 HTTP-only，HTTPS 由 certbot 注入）
echo "--- E. nginx 站点 ---"
$SUDO tee /etc/nginx/conf.d/edge-api.conf >/dev/null <<NGINX
upstream edge_upstream {
    server 127.0.0.1:8000;
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DEPLOY_DOMAIN;

    # 生产环境不暴露接口结构（请求不进 Python，直接 404）
    location = /docs         { return 404; }
    location = /redoc        { return 404; }
    location = /openapi.json { return 404; }

    root $APP_DIR/app/static;
    index index.html;
    client_max_body_size 10m;
    server_tokens off;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;

    location ~* \.(html|htm|css|js|png|jpe?g|gif|svg|ico|woff2?|ttf|map)\$ {
        expires 1h;
        add_header Cache-Control "public";
        try_files \$uri =404;
    }

    location = / {
        try_files /index.html =404;
    }

    # SSE 流式对话依赖：应用响应头 X-Accel-Buffering:no 已禁用代理缓冲；
    # gzip_types 不含 text/event-stream，SSE 不压缩，逐块下发
    location / {
        proxy_pass http://edge_upstream;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 10s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
NGINX

# Ubuntu 默认站点占用 80
if [ -e /etc/nginx/sites-enabled/default ]; then
    $SUDO rm -f /etc/nginx/sites-enabled/default
fi

# SELinux（RHEL/CentOS 系）：放行 nginx 反代 + 静态目录读权限（best-effort）
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
    echo "SELinux=Enforcing，配置放行规则"
    $SUDO setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    if command -v semanage >/dev/null 2>&1; then
        $SUDO semanage fcontext -a -t httpd_sys_content_t "$APP_DIR/app/static(/.*)?" 2>/dev/null || true
        command -v restorecon >/dev/null 2>&1 && $SUDO restorecon -R "$APP_DIR/app/static" 2>/dev/null || true
    fi
fi

$SUDO nginx -t
$SUDO systemctl daemon-reload
$SUDO systemctl enable $SERVICE >/dev/null 2>&1 || true
$SUDO systemctl restart $SERVICE
$SUDO systemctl restart nginx      # 必须 restart：装完 nginx 已自启，写配置对运行中进程无效
sleep 3
echo "服务状态: $SERVICE=$(systemctl is-active $SERVICE) nginx=$(systemctl is-active nginx)"

# ---------------------------------------------------------------- F. 应用自检（证书之前）
echo "--- F. 应用自检（HTTP） ---"
curl -s -o /dev/null -w "  GET  /privacy.html       -> %{http_code}\n" http://127.0.0.1/privacy.html || true
curl -s -o /dev/null -w "  GET  /terms.html         -> %{http_code}\n" http://127.0.0.1/terms.html || true
curl -s -o /dev/null -w "  GET  /permissions.html   -> %{http_code}\n" http://127.0.0.1/permissions.html || true
curl -s -o /dev/null -w "  GET  /docs               -> %{http_code}  (期望 404)\n" http://127.0.0.1/docs || true
curl -s -o /dev/null -w "  POST /api/v1/forecast/now -> %{http_code}\n" -X POST http://127.0.0.1/api/v1/forecast/now -H 'Content-Type: application/json' -d '{}' || true
echo "--- 启动日志 ---"
$SUDO journalctl -u $SERVICE --since "2 min ago" --no-pager 2>/dev/null | grep -E "edge started|prdId|base=|Traceback|Error" | tail -8 || true

# ---------------------------------------------------------------- G. 证书
if [ "$CERTBOT_OK" = "1" ]; then
    echo "--- G. 签发 Let's Encrypt 证书 ---"
    $SUDO mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/sh\n/usr/bin/systemctl reload nginx\n' | $SUDO tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh >/dev/null
    $SUDO chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    $SUDO certbot --nginx -d "$DEPLOY_DOMAIN" \
        --non-interactive --agree-tos --register-unsafely-without-email --redirect
    $SUDO nginx -t && $SUDO systemctl reload nginx
    $SUDO certbot certificates 2>/dev/null | grep -E "Certificate Name|Expiry Date" || true

    echo "--- H. HTTPS 自检 ---"
    curl -s -o /dev/null -w "  https://$DEPLOY_DOMAIN/privacy.html -> %{http_code}\n" "https://$DEPLOY_DOMAIN/privacy.html" || true
    curl -s -o /dev/null -w "  http 跳转 -> %{http_code} (期望 301)\n" "http://$DEPLOY_DOMAIN/" || true
else
    echo "--- G. 跳过证书签发（DNS 未指向本机）---"
    echo "    DNS 就绪后单独执行（在服务器上）："
    echo "    certbot --nginx -d $DEPLOY_DOMAIN --non-interactive --agree-tos --register-unsafely-without-email --redirect"
fi

# 清理临时文件（含 .env 副本）
rm -f /tmp/edge-api.env /tmp/edge-api-code.tar.gz /tmp/deploy_remote.sh
echo "--- 远端部署完成 ---"
EOS

# ================================================================ 3. 上传
log "3/5 上传到 $DEPLOY_HOST:/tmp/"
scp "${SSH_BASE[@]}" "$TARBALL" "$ENVFILE" "$REMOTE_SH" "$TARGET:/tmp/" || die "scp 上传失败"
ssh "${SSH_BASE[@]}" "$TARGET" \
    "mv -f /tmp/code.tar.gz /tmp/edge-api-code.tar.gz"

# ================================================================ 4. 远端执行
log "4/5 远端执行（输出较多，请稍候）"
ssh "${SSH_BASE[@]}" "$TARGET" \
    "SUDO='$SUDO' APP_DIR='$APP_DIR' APP_USER='$APP_USER' SERVICE='$SERVICE' DEPLOY_DOMAIN='$DEPLOY_DOMAIN' PYTHON_BIN='$PYTHON_BIN' CERTBOT_OK='$CERTBOT_OK' bash /tmp/deploy_remote.sh" \
    || die "远端部署失败（见上方输出）"

# ================================================================ 5. 本地冒烟
log "5/5 本地公网冒烟"
echo -n "  http://$DEPLOY_HOST/privacy.html      -> "
curl -s -o /dev/null -m 15 -w "%{http_code}\n" "http://$DEPLOY_HOST/privacy.html" || echo "(失败)"
if [ "$CERTBOT_OK" = "1" ]; then
    echo -n "  https://$DEPLOY_DOMAIN/privacy.html    -> "
    curl -s -o /dev/null -m 15 -w "%{http_code}\n" "https://$DEPLOY_DOMAIN/privacy.html" || echo "(失败)"
    echo -n "  http://$DEPLOY_DOMAIN/ (期望 301)      -> "
    curl -s -o /dev/null -m 15 -w "%{http_code}\n" "http://$DEPLOY_DOMAIN/" || echo "(失败)"
fi

log "完成"
