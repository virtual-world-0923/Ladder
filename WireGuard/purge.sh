#!/bin/bash
#
# purge-wireguard.sh
# 彻底卸载 WireGuard：停止服务、删除接口、清理配置、卸载软件包
# 目标：执行后系统如同从未安装过 WireGuard
#
# 用法：
#   sudo bash purge-wireguard.sh
#   sudo bash purge-wireguard.sh --yes   # 非交互模式，直接执行
#

set -e

# ---------- 颜色 ----------
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log()  { echo -e "${GREEN}[+] $*${NC}"; }
warn() { echo -e "${YELLOW}[!] $*${NC}"; }
err()  { echo -e "${RED}[-] $*${NC}" >&2; }

# ---------- 权限检查 ----------
if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 权限运行：sudo bash $0"
    exit 1
fi

# ---------- 确认 ----------
ASSUME_YES=0
[ "$1" = "--yes" ] && ASSUME_YES=1

if [ "$ASSUME_YES" -ne 1 ]; then
    warn "此脚本将彻底执行以下操作："
    echo "    1. 停止并禁用所有 wg-quick / WireGuard 服务"
    echo "    2. 关闭并删除所有 WireGuard 网络接口 (wg*)"
    echo "    3. 删除 /etc/wireguard/ 下所有配置"
    echo "    4. 清理 systemd 残留 unit 文件"
    echo "    5. 卸载所有 wireguard 相关软件包 (wg-tools/wireguard/wireguard-tools 等)"
    echo "    6. 删除 /etc/systemd/system/wg-quick@*.service 等残留"
    echo "    7. 移除内核模块 wireguard (若已加载)"
    echo ""
    read -r -p "确认执行？(输入 yes 继续): " CONFIRM
    [ "$CONFIRM" != "yes" ] && { warn "已取消"; exit 0; }
fi

# ---------- 1. 关闭所有 wg-quick 服务 ----------
log "停止并禁用所有 wg-quick@*.service ..."
# 列出所有已加载的 wg-quick 服务
SERVICES=$(systemctl list-units --full --all --plain --no-legend 'wg-quick@*.service' 2>/dev/null | awk '{print $1}' || true)
if [ -n "$SERVICES" ]; then
    for svc in $SERVICES; do
        log "  停止 $svc"
        systemctl stop   "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
else
    log "  未发现运行中的 wg-quick 服务"
fi

# 兜底：停止所有匹配 wg-quick 的进程
pkill -f wg-quick 2>/dev/null || true

# ---------- 2. 关闭并删除所有 WireGuard 接口 ----------
log "关闭所有 WireGuard 网络接口 (wg*) ..."
if command -v wg >/dev/null 2>&1; then
    INTERFACES=$(wg show interfaces 2>/dev/null || true)
    if [ -n "$INTERFACES" ]; then
        for iface in $INTERFACES; do
            log "  Down 接口: $iface"
            ip link delete "$iface" 2>/dev/null || \
            wg-quick down "$iface" 2>/dev/null || true
        done
    else
        log "  当前无活跃的 wg 接口"
    fi
else
    warn "wg 命令不可用，尝试通过 ip 命令清理"
fi

# 兜底：遍历 /sys/class/net 删除 wg* 接口
for iface in $(ls /sys/class/net 2>/dev/null | grep -E '^wg' || true); do
    log "  兜底删除接口: $iface"
    ip link delete "$iface" 2>/dev/null || true
done

# ---------- 3. 卸载 wireguard 内核模块 ----------
log "卸载 wireguard 内核模块 ..."
if lsmod 2>/dev/null | grep -q '^wireguard'; then
    modprobe -r wireguard 2>/dev/null || true
fi
# 防止开机自动加载
if [ -d /etc/modprobe.d ]; then
    rm -f /etc/modprobe.d/wireguard.conf
fi

# ---------- 4. 删除配置文件 ----------
log "删除 /etc/wireguard/ ..."
rm -rf /etc/wireguard

# 常见额外配置位置
rm -f /etc/wireguard.conf 2>/dev/null || true

# ---------- 5. 清理 systemd unit 残留 ----------
log "清理 systemd 残留文件 ..."
rm -f /etc/systemd/system/wg-quick@*.service
rm -f /run/systemd/system/wg-quick@*.service
rm -f /etc/systemd/system/multi-user.target.wants/wg-quick@*.service
# 重新加载 systemd
systemctl daemon-reload 2>/dev/null || true

# ---------- 6. 卸载软件包 ----------
log "检测包管理器并卸载 wireguard 相关软件包 ..."

# 收集需要卸载的包名（已安装的）
PACKAGES=""
has_pkg() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

CANDIDATES="wireguard wireguard-tools wireguard-dkms wireguard-go wireguard-tools-dbgsym resolvconf"
for pkg in $CANDIDATES; do
    if has_pkg "$pkg"; then
        PACKAGES="$PACKAGES $pkg"
    fi
done

if [ -n "$PACKAGES" ]; then
    log "  将卸载：$PACKAGES"
    # 优先 apt (Ubuntu 默认)
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y --auto-remove $PACKAGES 2>&1 | tail -n 20
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y $PACKAGES 2>&1 | tail -n 20
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y $PACKAGES 2>&1 | tail -n 20
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Rns --noconfirm $PACKAGES 2>&1 | tail -n 20
    elif command -v zypper >/dev/null 2>&1; then
        zypper remove -y $PACKAGES 2>&1 | tail -n 20
    else
        warn "未识别的包管理器，请手动卸载：$PACKAGES"
    fi
else
    log "  未发现已安装的 wireguard 软件包（可能是源码/第三方安装）"
fi

# ---------- 7. 清理残留二进制 / 文件 ----------
log "清理残留文件 ..."
# 常见二进制位置
rm -f /usr/bin/wg /usr/bin/wg-quick 2>/dev/null || true
rm -f /usr/local/bin/wg /usr/local/bin/wg-quick 2>/dev/null || true
rm -f /sbin/wg /sbin/wg-quick 2>/dev/null || true
# man / 文档
rm -rf /usr/share/doc/wireguard* 2>/dev/null || true
rm -f /usr/share/man/man8/wg*.8* 2>/dev/null || true
# 日志 / 运行时文件
rm -rf /var/log/wireguard* 2>/dev/null || true
rm -rf /run/wireguard* 2>/dev/null || true
# 用户家目录下的客户端配置（常见）
rm -f /root/*.conf 2>/dev/null || true
# 注意：不递归删除家目录，避免误删用户数据

# 清理可能加入 /etc/modules 的 wireguard 行
if [ -f /etc/modules ]; then
    sed -i '/^wireguard$/d' /etc/modules 2>/dev/null || true
fi

# 清理 networkd / netplan / interfaces 中可能残留的 wg 引用
# （仅提示，不自动修改，避免误伤）
for f in /etc/network/interfaces /etc/netplan/*.yaml /etc/systemd/network/*.network; do
    [ -e "$f" ] || continue
    if grep -qE 'wg[0-9]|wireguard' "$f" 2>/dev/null; then
        warn "检测到 $f 中可能残留 wireguard 配置，请手动检查"
    fi
done

# ---------- 8. 最终校验 ----------
log "执行完毕，最终状态校验："
echo ""
echo "  - wg 命令:        $(command -v wg || echo '未找到 (已清理)')"
echo "  - /etc/wireguard: $([ -d /etc/wireguard ] && echo '仍存在!' || echo '已删除')"
echo "  - 活跃 wg 接口:   $(ip -o link show 2>/dev/null | grep -cE ': wg[0-9]+' || echo 0) 个"
echo "  - wireguard 模块: $(lsmod 2>/dev/null | grep -q wireguard && echo '仍加载!' || echo '未加载')"
echo ""
log "✅ WireGuard 已彻底卸载清理完成，系统恢复至未安装状态。"
warn "提示：若 /etc/network、/etc/netplan 等位置有残留引用，请按上方提示手动清理。"
