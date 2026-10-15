#!/usr/bin/env bash

# ============================================================
# Xray 完全卸载 / 清理脚本
#
# 目标：
#   将 Xray 从 Ubuntu Server 中彻底删除
#
# 删除：
#   - Xray systemd 服务
#   - Xray 二进制
#   - Xray 配置
#   - Xray 日志
#   - Xray GeoIP / GeoSite
#   - Xray logrotate
#   - Xray service override
#   - Xray 临时文件
#
# 注意：
#   本脚本会永久删除 Xray 配置和密钥。
# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------
# 颜色
# ------------------------------------------------------------

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
RESET='\033[0m'

red() {
    echo -e "${RED}$*${RESET}"
}

green() {
    echo -e "${GREEN}$*${RESET}"
}

yellow() {
    echo -e "${YELLOW}$*${RESET}"
}

blue() {
    echo -e "${BLUE}$*${RESET}"
}

# ------------------------------------------------------------
# root 检查
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    red "错误：必须使用 root 权限运行。"
    echo
    echo "请执行："
    echo
    echo "  sudo ./remove-xray.sh"
    echo
    exit 1
fi

# ------------------------------------------------------------
# 开始
# ------------------------------------------------------------

echo
blue "============================================================"
blue "             Xray 完全卸载 / 清理工具"
blue "============================================================"
echo

yellow "警告："
echo
echo "此操作将删除 Xray 的："
echo
echo "  - 配置文件"
echo "  - UUID"
echo "  - REALITY 私钥"
echo "  - REALITY 公钥"
echo "  - systemd 服务"
echo "  - Xray 程序"
echo "  - GeoIP / GeoSite"
echo "  - 日志"
echo "  - logrotate 配置"
echo
yellow "删除后无法恢复。"
echo

read -r -p "确定要彻底删除 Xray 吗？输入 DELETE 继续：" CONFIRM

if [[ "${CONFIRM}" != "DELETE" ]]; then
    echo
    yellow "已取消，没有进行任何删除操作。"
    exit 0
fi

echo

# ------------------------------------------------------------
# Xray 文件位置
# ------------------------------------------------------------

XRAY_BIN="/usr/local/bin/xray"

XRAY_CONFIG_DIR="/usr/local/etc/xray"

XRAY_DATA_DIR="/usr/local/share/xray"

XRAY_LOG_DIR="/var/log/xray"

XRAY_SERVICE="/etc/systemd/system/xray.service"

XRAY_TEMPLATE_SERVICE="/etc/systemd/system/xray@.service"

XRAY_SERVICE_DIR="/etc/systemd/system/xray.service.d"

XRAY_TEMPLATE_SERVICE_DIR="/etc/systemd/system/xray@.service.d"

XRAY_LOGROTATE="/etc/logrotate.d/xray"

XRAY_LOGROTATE_SERVICE="/etc/systemd/system/logrotate@.service"

XRAY_LOGROTATE_TIMER="/etc/systemd/system/logrotate@.timer"

# ------------------------------------------------------------
# 停止 Xray
# ------------------------------------------------------------

green "[1/8] 停止 Xray 服务..."

systemctl stop xray 2>/dev/null || true

systemctl stop 'xray@*' 2>/dev/null || true

# 如果 systemctl 没有找到服务，再尝试杀掉进程
if pgrep -x xray >/dev/null 2>&1; then

    yellow "发现 Xray 进程，正在停止..."

    pkill -TERM -x xray 2>/dev/null || true

    sleep 2

    if pgrep -x xray >/dev/null 2>&1; then
        yellow "Xray 仍在运行，强制终止..."
        pkill -KILL -x xray 2>/dev/null || true
    fi
fi

green "Xray 进程已停止。"

# ------------------------------------------------------------
# 禁用 systemd
# ------------------------------------------------------------

green "[2/8] 禁用 Xray systemd 服务..."

systemctl disable xray 2>/dev/null || true

systemctl disable 'xray@*' 2>/dev/null || true

# ------------------------------------------------------------
# 删除 systemd 服务
# ------------------------------------------------------------

green "[3/8] 删除 Xray systemd 服务..."

rm -f \
    "${XRAY_SERVICE}" \
    "${XRAY_TEMPLATE_SERVICE}"

rm -rf \
    "${XRAY_SERVICE_DIR}" \
    "${XRAY_TEMPLATE_SERVICE_DIR}"

# ------------------------------------------------------------
# 删除 logrotate
# ------------------------------------------------------------

green "[4/8] 删除 Xray logrotate..."

systemctl stop logrotate@xray.timer 2>/dev/null || true

systemctl disable logrotate@xray.timer 2>/dev/null || true

rm -f \
    "${XRAY_LOGROTATE}"

# 注意：
# /etc/systemd/system/logrotate@.service
# /etc/systemd/system/logrotate@.timer
# 可能是系统其他程序使用的公共服务。
#
# 因此默认不删除整个 logrotate systemd 模板。
#
# 只删除 Xray 对它产生的实例状态。

rm -f \
    /etc/systemd/system/multi-user.target.wants/logrotate@xray.timer \
    /etc/systemd/system/timers.target.wants/logrotate@xray.timer

# ------------------------------------------------------------
# 删除 Xray 程序
# ------------------------------------------------------------

green "[5/8] 删除 Xray 程序..."

rm -f \
    "${XRAY_BIN}"

# 兼容可能存在的其他 Xray 文件
rm -f \
    /usr/local/bin/xray-linux-* \
    /usr/local/bin/xray*

# ------------------------------------------------------------
# 删除配置 / 数据 / 日志
# ------------------------------------------------------------

green "[6/8] 删除 Xray 配置、数据和日志..."

rm -rf \
    "${XRAY_CONFIG_DIR}" \
    "${XRAY_DATA_DIR}" \
    "${XRAY_LOG_DIR}"

# ------------------------------------------------------------
# 删除可能存在的安装临时文件
# ------------------------------------------------------------

green "[7/8] 清理临时文件..."

rm -f \
    /tmp/xray-install-release.sh \
    /tmp/xray-install.sh \
    /tmp/xray-tls-ping.txt

# 清理可能的 Xray 临时目录
find /tmp \
    -maxdepth 1 \
    -type d \
    -iname '*xray*' \
    -exec rm -rf {} + \
    2>/dev/null || true

# ------------------------------------------------------------
# systemd 刷新
# ------------------------------------------------------------

green "[8/8] 刷新 systemd..."

systemctl daemon-reload

systemctl reset-failed xray 2>/dev/null || true

# ------------------------------------------------------------
# 清理残留检查
# ------------------------------------------------------------

echo
green "检查 Xray 残留..."
echo

FOUND=0

check_path() {

    local PATH_TO_CHECK="$1"

    if [[ -e "${PATH_TO_CHECK}" ]]; then
        red "发现残留：${PATH_TO_CHECK}"
        FOUND=1
    fi
}

check_path "/usr/local/bin/xray"
check_path "/usr/local/etc/xray"
check_path "/usr/local/share/xray"
check_path "/var/log/xray"
check_path "/etc/systemd/system/xray.service"
check_path "/etc/systemd/system/xray@.service"
check_path "/etc/systemd/system/xray.service.d"
check_path "/etc/systemd/system/xray@.service.d"
check_path "/etc/logrotate.d/xray"

# ------------------------------------------------------------
# 搜索 systemd 中的 Xray
# ------------------------------------------------------------

if systemctl list-unit-files 2>/dev/null | grep -qi '^xray'; then
    red "发现 systemd 中仍存在 Xray unit。"
    FOUND=1
fi

# ------------------------------------------------------------
# 搜索进程
# ------------------------------------------------------------

if pgrep -x xray >/dev/null 2>&1; then
    red "发现 Xray 进程仍在运行。"
    FOUND=1
fi

# ------------------------------------------------------------
# 最终结果
# ------------------------------------------------------------

echo

if [[ "${FOUND}" -eq 0 ]]; then

    green "============================================================"
    green "             Xray 已彻底清理完成"
    green "============================================================"

else

    yellow "============================================================"
    yellow "          Xray 已清理，但发现少量残留"
    yellow "============================================================"

    echo
    yellow "请检查上面的残留路径。"

fi

echo

echo "Xray 二进制："
if [[ ! -e "${XRAY_BIN}" ]]; then
    green "  已删除"
else
    red "  仍存在"
fi

echo

echo "Xray 配置："
if [[ ! -e "${XRAY_CONFIG_DIR}" ]]; then
    green "  已删除"
else
    red "  仍存在"
fi

echo

echo "Xray 数据："
if [[ ! -e "${XRAY_DATA_DIR}" ]]; then
    green "  已删除"
else
    red "  仍存在"
fi

echo

echo "Xray 日志："
if [[ ! -e "${XRAY_LOG_DIR}" ]]; then
    green "  已删除"
else
    red "  仍存在"
fi

echo

echo "systemd："
if [[ ! -e "${XRAY_SERVICE}" && ! -e "${XRAY_TEMPLATE_SERVICE}" ]]; then
    green "  已删除"
else
    red "  仍存在"
fi

echo

green "现在可以重新安装 Xray。"
echo