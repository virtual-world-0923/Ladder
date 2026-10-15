#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Xray VLESS + REALITY + Vision + TCP/RAW
# Ubuntu Server 26.04 LTS
#
# Clean reinstall script
#
# Features:
#   VLESS
#   REALITY
#   xtls-rprx-vision
#   TCP / RAW
#   Xray systemd service
#   systemd runs Xray as root
#
# WARNING:
#   This script completely removes the existing Xray installation,
#   configuration, logs and systemd service before reinstalling.
###############################################################################

SCRIPT_NAME="$(basename "$0")"

###############################################################################
# Basic settings
###############################################################################

XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

XRAY_BIN="/usr/local/bin/xray"

XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"

XRAY_LOG_DIR="/var/log/xray"
XRAY_ACCESS_LOG="${XRAY_LOG_DIR}/access.log"
XRAY_ERROR_LOG="${XRAY_LOG_DIR}/error.log"

XRAY_SERVICE="/etc/systemd/system/xray.service"
XRAY_SERVICE_DIR="/etc/systemd/system/xray.service.d"

CLIENT_FILE="/root/xray-client.txt"

PORT="443"

###############################################################################
# REALITY settings
#
# You can change these before running the script if needed.
###############################################################################

REALITY_TARGET="${REALITY_TARGET:-www.cloudflare.com:443}"
REALITY_SNI="${REALITY_SNI:-www.cloudflare.com}"

REALITY_FP="chrome"

###############################################################################
# Colors
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

###############################################################################
# Helper functions
###############################################################################

log() {
    echo -e "${GREEN}[+]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

die() {
    error "$*"
    exit 1
}

trap 'error "脚本在第 ${LINENO} 行执行失败。"' ERR

###############################################################################
# Root check
###############################################################################

if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 运行：sudo ${SCRIPT_NAME}"
fi

###############################################################################
# OS check
###############################################################################

if [[ ! -f /etc/os-release ]]; then
    die "无法检测操作系统。"
fi

source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
    warn "当前系统不是 Ubuntu：${ID}"
    warn "本脚本主要针对 Ubuntu Server。"
fi

###############################################################################
# Confirmation
###############################################################################

echo
echo -e "${YELLOW}============================================================${NC}"
echo -e "${YELLOW}           Xray 完整重装脚本${NC}"
echo -e "${YELLOW}============================================================${NC}"
echo

echo "此脚本会删除现有 Xray："
echo
echo "  ${XRAY_BIN}"
echo "  ${XRAY_CONFIG_DIR}"
echo "  ${XRAY_LOG_DIR}"
echo "  ${XRAY_SERVICE}"
echo "  ${XRAY_SERVICE_DIR}"
echo

echo "然后重新安装："
echo
echo "  VLESS + REALITY + Vision + TCP/RAW"
echo "  TCP ${PORT}"
echo "  systemd User=root"
echo

echo -e "${RED}注意：现有 Xray 配置和 REALITY 密钥会被删除。${NC}"
echo

read -r -p "确认继续请输入 DELETE： " CONFIRM

if [[ "${CONFIRM}" != "DELETE" ]]; then
    echo "已取消。"
    exit 0
fi

###############################################################################
# Install dependencies
###############################################################################

log "更新软件包列表..."

export DEBIAN_FRONTEND=noninteractive

apt-get update

log "安装基础依赖..."

apt-get install -y --no-install-recommends \
    curl \
    unzip \
    ca-certificates \
    openssl \
    jq

###############################################################################
# Stop existing Xray
###############################################################################

log "停止现有 Xray 服务..."

systemctl stop xray.service 2>/dev/null || true
systemctl disable xray.service 2>/dev/null || true

# Try to stop template instances if they exist.
systemctl stop 'xray@*.service' 2>/dev/null || true

###############################################################################
# Kill remaining Xray process
###############################################################################

if pgrep -x xray >/dev/null 2>&1; then

    warn "发现残留 Xray 进程，正在终止..."

    pkill -TERM -x xray 2>/dev/null || true

    sleep 2

    if pgrep -x xray >/dev/null 2>&1; then
        pkill -KILL -x xray 2>/dev/null || true
        sleep 1
    fi

fi

###############################################################################
# Remove old Xray installation
###############################################################################

log "清理旧 Xray 文件..."

rm -f /usr/local/bin/xray
rm -f /usr/local/bin/xray.bak

rm -rf "${XRAY_CONFIG_DIR}"
rm -rf /usr/local/share/xray
rm -rf "${XRAY_LOG_DIR}"

rm -f "${XRAY_SERVICE}"
rm -f /etc/systemd/system/xray@.service

rm -rf "${XRAY_SERVICE_DIR}"
rm -rf /etc/systemd/system/xray@.service.d

rm -f /etc/logrotate.d/xray

rm -f "${CLIENT_FILE}"

systemctl daemon-reload

###############################################################################
# Download official Xray installer
###############################################################################

log "下载 Xray 官方安装脚本..."

INSTALL_SCRIPT="$(mktemp)"

curl -fsSL \
    "${XRAY_INSTALL_URL}" \
    -o "${INSTALL_SCRIPT}"

chmod 700 "${INSTALL_SCRIPT}"

###############################################################################
# Install Xray as root
###############################################################################

log "安装 Xray，并指定 systemd User=root..."

bash "${INSTALL_SCRIPT}" install -u root --force

rm -f "${INSTALL_SCRIPT}"

###############################################################################
# Verify binary
###############################################################################

if [[ ! -x "${XRAY_BIN}" ]]; then
    die "Xray 安装失败：${XRAY_BIN} 不存在。"
fi

XRAY_VERSION="$(
    "${XRAY_BIN}" version |
    head -n 1
)"

log "Xray 安装成功：${XRAY_VERSION}"

###############################################################################
# Ensure systemd service exists
###############################################################################

if [[ ! -f "${XRAY_SERVICE}" ]]; then

    warn "官方安装器没有创建 xray.service。"
    warn "正在创建标准 systemd 服务..."

    mkdir -p "${XRAY_SERVICE_DIR}"

    cat > "${XRAY_SERVICE}" <<'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
Group=root

CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

NoNewPrivileges=false

ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json

Restart=on-failure
RestartPreventExitStatus=23

LimitNPROC=10000
LimitNOFILE=1000000

RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

fi

###############################################################################
# Force Xray to run as root
#
# This override wins over an installer-created User=nobody.
###############################################################################

log "设置 Xray systemd User=root..."

mkdir -p "${XRAY_SERVICE_DIR}"

cat > "${XRAY_SERVICE_DIR}/99-run-as-root.conf" <<'EOF'
[Service]
User=root
Group=root
NoNewPrivileges=false
EOF

systemctl daemon-reload

###############################################################################
# Verify effective systemd user
###############################################################################

SYSTEMD_USER="$(
    systemctl show xray.service \
        --property=User \
        --value
)"

if [[ "${SYSTEMD_USER}" != "root" ]]; then

    warn "systemd 当前 User=${SYSTEMD_USER}"
    warn "重新写入 root override..."

    cat > "${XRAY_SERVICE_DIR}/99-run-as-root.conf" <<'EOF'
[Service]
User=root
Group=root
NoNewPrivileges=false
EOF

    systemctl daemon-reload

    SYSTEMD_USER="$(
        systemctl show xray.service \
            --property=User \
            --value
    )"

fi

if [[ "${SYSTEMD_USER}" != "root" ]]; then
    die "无法让 xray.service 使用 root 运行。当前 User=${SYSTEMD_USER}"
fi

log "systemd User=root"

###############################################################################
# Generate UUID
###############################################################################

log "生成 VLESS UUID..."

UUID="$(
    "${XRAY_BIN}" uuid |
    head -n 1 |
    tr -d '[:space:]'
)"

if [[ -z "${UUID}" ]]; then
    die "UUID 生成失败。"
fi

log "UUID 已生成。"

###############################################################################
# Generate REALITY X25519 keys
###############################################################################

log "生成 REALITY X25519 密钥..."

X25519_OUTPUT="$(
    "${XRAY_BIN}" x25519 2>&1
)"

echo
echo "X25519 输出："
echo "${X25519_OUTPUT}"
echo

###############################################################################
# Parse PrivateKey
#
# Current Xray 26.x:
#
#   PrivateKey: XXXXX
#
# Older Xray versions:
#
#   Private key: XXXXX
###############################################################################

PRIVATE_KEY="$(
    echo "${X25519_OUTPUT}" |
    sed -nE \
        -e 's/^PrivateKey:[[:space:]]*(.+)$/\1/p' \
        -e 's/^Private key:[[:space:]]*(.+)$/\1/p' |
    tail -n 1 |
    tr -d '[:space:]'
)"

###############################################################################
# Parse PublicKey
#
# Current Xray 26.x:
#
#   Password (PublicKey): XXXXX
#
# Older variants:
#
#   Password: XXXXX
#   Public key: XXXXX
###############################################################################

PUBLIC_KEY="$(
    echo "${X25519_OUTPUT}" |
    sed -nE \
        -e 's/^Password[[:space:]]*\(PublicKey\):[[:space:]]*(.+)$/\1/p' \
        -e 's/^Password:[[:space:]]*(.+)$/\1/p' \
        -e 's/^Public key:[[:space:]]*(.+)$/\1/p' |
    tail -n 1 |
    tr -d '[:space:]'
)"

###############################################################################
# Validate X25519 keys
###############################################################################

if [[ -z "${PRIVATE_KEY}" ]]; then
    die "REALITY PrivateKey 生成/解析失败。"
fi

if [[ -z "${PUBLIC_KEY}" ]]; then
    die "REALITY PublicKey 生成/解析失败。"
fi

log "REALITY X25519 密钥生成成功。"

###############################################################################
# Generate REALITY shortId
###############################################################################

log "生成 REALITY shortId..."

SHORT_ID="$(
    openssl rand -hex 8
)"

if [[ ! "${SHORT_ID}" =~ ^[0-9a-f]{16}$ ]]; then
    die "shortId 生成失败。"
fi

log "shortId 已生成。"

###############################################################################
# Get public IPv4
###############################################################################

log "获取服务器公网 IPv4..."

PUBLIC_IP=""

for URL in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com"
do

    CANDIDATE="$(
        curl -4 -fsSL \
            --connect-timeout 5 \
            --max-time 10 \
            "${URL}" 2>/dev/null |
        tr -d '[:space:]'
    )" || true

    if [[ "${CANDIDATE}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        PUBLIC_IP="${CANDIDATE}"
        break
    fi

done

if [[ -z "${PUBLIC_IP}" ]]; then
    die "无法自动获取公网 IPv4。"
fi

log "公网 IPv4：${PUBLIC_IP}"

###############################################################################
# Check port before creating configuration
###############################################################################

log "检查 TCP ${PORT} 是否已经被占用..."

PORT_OWNER="$(
    ss -lntp 2>/dev/null |
    grep -E ":${PORT}[[:space:]]" |
    head -n 1 ||
    true
)"

if [[ -n "${PORT_OWNER}" ]]; then
    echo
    warn "TCP ${PORT} 当前已有监听："
    echo "${PORT_OWNER}"
    echo

    if ! echo "${PORT_OWNER}" | grep -qi xray; then
        die "TCP ${PORT} 已被其他程序占用。"
    fi
fi

###############################################################################
# Create directories
###############################################################################

log "创建 Xray 配置目录..."

mkdir -p "${XRAY_CONFIG_DIR}"
mkdir -p "${XRAY_LOG_DIR}"

chown root:root "${XRAY_CONFIG_DIR}"
chmod 755 "${XRAY_CONFIG_DIR}"

chown root:root "${XRAY_LOG_DIR}"
chmod 755 "${XRAY_LOG_DIR}"

###############################################################################
# Create log files
###############################################################################

log "创建 Xray 日志文件..."

touch "${XRAY_ACCESS_LOG}"
touch "${XRAY_ERROR_LOG}"

chown root:root \
    "${XRAY_ACCESS_LOG}" \
    "${XRAY_ERROR_LOG}"

chmod 600 \
    "${XRAY_ACCESS_LOG}" \
    "${XRAY_ERROR_LOG}"

###############################################################################
# Create Xray configuration
###############################################################################

log "生成 Xray config.json..."

cat > "${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_ACCESS_LOG}",
    "error": "${XRAY_ERROR_LOG}"
  },

  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",

      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },

      "streamSettings": {
        "network": "raw",
        "security": "reality",

        "realitySettings": {
          "show": false,
          "dest": "${REALITY_TARGET}",
          "xver": 0,

          "serverNames": [
            "${REALITY_SNI}"
          ],

          "privateKey": "${PRIVATE_KEY}",

          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },

      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],

  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

###############################################################################
# Secure configuration
###############################################################################

chown root:root "${XRAY_CONFIG}"
chmod 600 "${XRAY_CONFIG}"

###############################################################################
# Test Xray configuration
###############################################################################

log "检查 Xray 配置..."

if ! "${XRAY_BIN}" run \
    -test \
    -config "${XRAY_CONFIG}"
then

    echo
    error "Xray 配置检查失败。"
    echo
    echo "当前配置："
    echo
    cat "${XRAY_CONFIG}"
    echo

    exit 1
fi

log "Xray 配置检查通过。"

###############################################################################
# Reload systemd
###############################################################################

systemctl daemon-reload

###############################################################################
# Enable Xray
###############################################################################

log "设置 Xray 开机启动..."

systemctl enable xray

###############################################################################
# Start Xray
###############################################################################

log "启动 Xray..."

systemctl restart xray

sleep 2

###############################################################################
# Verify service
###############################################################################

if ! systemctl is-active --quiet xray; then

    error "Xray 启动失败。"
    echo

    systemctl status xray --no-pager -l

    echo
    echo "最近 Xray 日志："

    journalctl \
        -u xray \
        -n 50 \
        --no-pager

    exit 1
fi

log "Xray 服务运行正常。"

###############################################################################
# Verify TCP 443
###############################################################################

log "检查 TCP ${PORT}..."

LISTEN_LINE="$(
    ss -lntp 2>/dev/null |
    grep -E ":${PORT}[[:space:]]" |
    grep -i xray |
    head -n 1 ||
    true
)"

if [[ -z "${LISTEN_LINE}" ]]; then

    warn "Xray 服务虽然运行，但没有检测到 TCP ${PORT} 监听。"

    echo
    ss -lntp | grep ":${PORT}" || true
    echo

    die "TCP ${PORT} 监听检查失败。"
fi

log "TCP ${PORT} 监听正常。"

###############################################################################
# Build client VLESS URI
###############################################################################

CLIENT_URI="vless://${UUID}@${PUBLIC_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=${REALITY_FP}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Xray-REALITY-Vision"

###############################################################################
# Save client configuration
###############################################################################

log "保存客户端配置..."

cat > "${CLIENT_FILE}" <<EOF
============================================================
Xray VLESS + REALITY + Vision
============================================================

Server IP:
${PUBLIC_IP}

Port:
${PORT}

Protocol:
VLESS

Network:
raw

Security:
reality

Flow:
xtls-rprx-vision

SNI:
${REALITY_SNI}

Fingerprint:
${REALITY_FP}

REALITY Public Key:
${PUBLIC_KEY}

REALITY Short ID:
${SHORT_ID}

UUID:
${UUID}

REALITY Target:
${REALITY_TARGET}

------------------------------------------------------------
VLESS URI
------------------------------------------------------------

${CLIENT_URI}

============================================================
IMPORTANT
============================================================

Keep this file private.

The URI contains the connection parameters required
by the VLESS client.

============================================================
EOF

chown root:root "${CLIENT_FILE}"
chmod 600 "${CLIENT_FILE}"

###############################################################################
# Final permissions
###############################################################################

chown root:root "${XRAY_CONFIG}"
chmod 600 "${XRAY_CONFIG}"

chown root:root "${XRAY_CONFIG_DIR}"
chmod 755 "${XRAY_CONFIG_DIR}"

chown root:root "${XRAY_LOG_DIR}"
chmod 755 "${XRAY_LOG_DIR}"

chown root:root \
    "${XRAY_ACCESS_LOG}" \
    "${XRAY_ERROR_LOG}"

chmod 600 \
    "${XRAY_ACCESS_LOG}" \
    "${XRAY_ERROR_LOG}"

###############################################################################
# Final daemon reload
###############################################################################

systemctl daemon-reload

###############################################################################
# Final verification
###############################################################################

echo
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}              Xray 安装成功${NC}"
echo -e "${GREEN}============================================================${NC}"
echo

echo "Xray 服务："
systemctl is-active xray

echo
echo "开机启动："
systemctl is-enabled xray

echo
echo "systemd User："
systemctl show xray.service --property=User --value

echo
echo "Xray 版本："
"${XRAY_BIN}" version | head -n 1

echo
echo "TCP ${PORT}："
ss -lntp | grep ":${PORT}" || true

echo
echo "配置文件："
echo "${XRAY_CONFIG}"

echo
echo "客户端配置文件："
echo "${CLIENT_FILE}"

echo
echo -e "${BLUE}============================================================${NC}"
echo "VLESS URI"
echo -e "${BLUE}============================================================${NC}"
echo
echo "${CLIENT_URI}"
echo
echo -e "${BLUE}============================================================${NC}"

echo
echo -e "${YELLOW}AWS EC2 注意：${NC}"
echo
echo "请确认 EC2 Security Group 已允许 TCP ${PORT} 入站。"
echo
echo "例如："
echo "  Protocol: TCP"
echo "  Port:     ${PORT}"
echo "  Source:   你的客户端公网 IP/32"
echo

echo "客户端配置也已保存："
echo
echo "  sudo cat ${CLIENT_FILE}"
echo

echo -e "${GREEN}全部完成。${NC}"