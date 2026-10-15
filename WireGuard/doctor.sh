#!/usr/bin/env bash
# ============================================================
# wg-doctor.sh — WireGuard 全能诊断 + 自动修复脚本
# ------------------------------------------------------------
# 覆盖：服务状态 / 接口 / 握手 / 流量 / IP转发 / NAT规则 /
#       出口网卡 / 客户端连通性(内网+外网+DNS) / 防火墙 / 配置校验
#
# 用法：sudo bash wg-doctor.sh [接口名] [--fix]
#   例：sudo bash wg-doctor.sh wg0          # 只诊断，不改动系统
#       sudo bash wg-doctor.sh wg0 --fix    # 诊断 + 自动修复
#
# 设计原则：
#   - 默认只读，加了 --fix 才修改系统
#   - 每项 [CHECK] -> [OK] / [WARN] / [FAIL]
#   - 发现问题时打印明确原因和建议命令
# ============================================================

set -uo pipefail

# ---------- 参数 ----------
INTERFACE="${1:-wg0}"
FIX=0
[[ "${2:-}" == "--fix" ]] && FIX=1

# 颜色（非终端也安全）
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

LOG="/var/log/wg-doctor.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

# 统计
OK_C=0; WARN_C=0; FAIL_C=0

# ---------- 日志函数 ----------
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG" >&2; }

say() {
    local level="$1"; shift
    case "$level" in
        OK)   echo -e "  ${GREEN}[OK]${NC}   $*" >&2; OK_C=$((OK_C+1)) ;;
        WARN) echo -e "  ${YELLOW}[WARN]${NC} $*" >&2; WARN_C=$((WARN_C+1)) ;;
        FAIL) echo -e "  ${RED}[FAIL]${NC} $*" >&2; FAIL_C=$((FAIL_C+1)) ;;
        INFO) echo -e "  ${BLUE}[INFO]${NC} $*" >&2 ;;
        *)    echo "         $*" >&2 ;;
    esac
    log "$level: $*"
}

header() { echo -e "\n${BLUE}=== $* ===${NC}" >&2; }

# ---------- 权限检查 ----------
if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 执行: sudo bash $0 $*" >&2
    exit 1
fi

# ---------- 工具函数 ----------
# 从 wg 输出解析指定 peer 的字段
wg_field() { local field="$1"; sudo wg show "$INTERFACE" 2>/dev/null | awk -v f="$field" '
    /^peer:/ { in_peer=1; next }
    in_peer && tolower($1) == tolower(f)":" { sub(/^[^:]*: /,""); print; exit }
'; }

# 解析 "122 seconds ago" / "1 minute, 30 seconds ago" 为秒数
handshake_to_sec() {
    local str="$1"; local sec=0
    local h m s
    h=$(echo "$str" | grep -oE '[0-9]+ hour'   | grep -oE '[0-9]+')
    m=$(echo "$str" | grep -oE '[0-9]+ minute' | grep -oE '[0-9]+')
    s=$(echo "$str" | grep -oE '[0-9]+ second' | grep -oE '[0-9]+')
    sec=$(( ${h:-0}*3600 + ${m:-0}*60 + ${s:-0} ))
    echo "$sec"
}

fix_now() {
    # $1=描述  $2...=命令
    local desc="$1"; shift
    if [ "$FIX" -eq 1 ]; then
        say INFO "修复: $desc"
        "$@" >>"$LOG" 2>&1 && say OK "已执行: $desc" || say FAIL "执行失败: $desc (查看 $LOG)"
    else
        say WARN "可修复(加 --fix 自动执行): $desc"
    fi
}

# ============================================================
echo -e "${BLUE}" >&2
echo "  ┌──────────────────────────────────────┐" >&2
echo "  │      WireGuard Doctor v1.0          │" >&2
echo "  │  诊断 + 自动修复 (--fix 才修改系统) │" >&2
echo "  └──────────────────────────────────────┘" >&2
echo -e "${NC}" >&2
log "===== 开始诊断 接口=$INTERFACE fix=$FIX ====="

# ============================================================
# 1. 服务与进程
# ============================================================
header "1. 服务与进程"
if systemctl is-active --quiet wg-quick@"$INTERFACE"; then
    say OK "wg-quick@${INTERFACE} 服务运行中"
else
    say FAIL "wg-quick@${INTERFACE} 服务未运行"
    fix_now "启动 wg-quick@${INTERFACE}" systemctl start "wg-quick@${INTERFACE}"
fi

if command -v wg >/dev/null 2>&1; then
    say OK "wg 命令可用"
else
    say FAIL "未安装 wireguard 工具"
    fix_now "安装 wireguard" apt-get update -y && apt-get install -y wireguard
fi

# ============================================================
# 2. 接口状态
# ============================================================
header "2. 网络接口 (${INTERFACE})"
if ip link show "$INTERFACE" >/dev/null 2>&1; then
    state=$(cat "/sys/class/net/${INTERFACE}/operstate" 2>/dev/null || echo unknown)
    if [ "$state" = "up" ] || [ "$state" = "unknown" ]; then
        say OK "接口 ${INTERFACE} 存在, 状态: ${state}"
    else
        say FAIL "接口 ${INTERFACE} 状态异常: ${state}"
        fix_now "重启接口" systemctl restart "wg-quick@${INTERFACE}"
    fi
else
    say FAIL "接口 ${INTERFACE} 不存在"
    if [ -f "/etc/wireguard/${INTERFACE}.conf" ]; then
        fix_now "用配置启动接口" systemctl start "wg-quick@${INTERFACE}"
    else
        say FAIL "配置文件 /etc/wireguard/${INTERFACE}.conf 也不存在，请先部署"
    fi
fi

# ============================================================
# 3. IP 转发
# ============================================================
header "3. IPv4 转发"
FWD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
if [ "$FWD" = "1" ]; then
    say OK "net.ipv4.ip_forward = 1"
else
    say FAIL "net.ipv4.ip_forward = 0 (客户端连上也无法转发上网)"
    fix_now "开启 IP 转发(临时+持久)" \
        bash -c "sysctl -w net.ipv4.ip_forward=1; echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard.conf; sysctl --system"
fi

# ============================================================
# 4. 出口网卡探测
# ============================================================
header "4. 出口网卡"
IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
if [ -n "$IFACE" ] && ip link show "$IFACE" >/dev/null 2>&1; then
    say OK "默认出口网卡: ${IFACE}"
else
    say FAIL "无法探测出口网卡 (默认路由缺失或网卡异常)"
    IFACE="eth0"
    say INFO "将使用兜底网卡名: ${IFACE} (若不符请手动指定)"
fi

# ============================================================
# 5. NAT / MASQUERADE 规则
# ============================================================
header "5. NAT 转发规则 (POSTROUTING MASQUERADE)"
MASQ=$(sudo iptables -t nat -S POSTROUTING 2>/dev/null | grep -c MASQUERADE || true)
FORWARD_RULE=$(sudo iptables -S FORWARD 2>/dev/null | grep -c "i ${INTERFACE}" || true)
WG_NET="${WG_NET:-10.8.0.0/24}"

if [ "$MASQ" -gt 0 ]; then
    say OK "存在 ${MASQ} 条 MASQUERADE 规则"
    sudo iptables -t nat -S POSTROUTING 2>/dev/null | grep MASQUERADE | sed 's/^/         /' >&2
else
    say FAIL "无 MASQUERADE 规则 → 客户端无法以服务器IP出网"
fi

if [ "$FORWARD_RULE" -gt 0 ]; then
    say OK "FORWARD 链已放行 ${INTERFACE}"
else
    say WARN "FORWARD 链未见针对 ${INTERFACE} 的放行规则"
fi

if [ "$FIX" -eq 1 ]; then
    say INFO "修复: 补充 NAT + FORWARD 规则"
    iptables -t nat -C POSTROUTING -s "$WG_NET" -o "$IFACE" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s "$WG_NET" -o "$IFACE" -j MASQUERADE
    iptables -C FORWARD -i "$INTERFACE" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$INTERFACE" -j ACCEPT
    # 持久化
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            iptables-save > /etc/iptables.rules 2>/dev/null || true
    fi
    say OK "NAT/FORWARD 规则已补充并尝试持久化"
fi

# ============================================================
# 6. wg0.conf 配置校验
# ============================================================
header "6. 服务端配置 /etc/wireguard/${INTERFACE}.conf"
CONF="/etc/wireguard/${INTERFACE}.conf"
if [ -f "$CONF" ]; then
    say OK "配置文件存在"
    # PostUp NAT
    if grep -q "MASQUERADE" "$CONF"; then
        say OK "配置含 MASQUERADE (PostUp)"
    else
        say WARN "配置未见 MASQUERADE，重启后 NAT 规则可能丢失"
        fix_now "在配置追加 PostUp/PostDown NAT" bash -c "
            sed -i '/^ListenPort/a PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${IFACE} -j MASQUERADE\nPostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${IFACE} -j MASQUERADE' ${CONF}
        "
    fi
    # 各 Peer 的 PersistentKeepalive
    peer_count=$(grep -c "^\[Peer\]" "$CONF" || true)
    keepalive_count=$(grep -c "PersistentKeepalive" "$CONF" || true)
    if [ "$peer_count" -gt 0 ]; then
        if [ "$keepalive_count" -ge "$peer_count" ]; then
            say OK "全部 ${peer_count} 个 Peer 均已设置 PersistentKeepalive"
        else
            say WARN "${keepalive_count}/${peer_count} 个 Peer 设置了 PersistentKeepalive (建议全设，防NAT超时断连)"
        fi
    fi
else
    say FAIL "配置文件 ${CONF} 不存在"
fi

# ============================================================
# 7. 握手 & 流量
# ============================================================
header "7. Peer 握手与流量"
WG_OUT=$(sudo wg show "$INTERFACE" 2>/dev/null)
if [ -z "$WG_OUT" ]; then
    say FAIL "wg show 无输出，接口可能未就绪"
else
    PEER_LINES=$(echo "$WG_OUT" | grep -c "^peer:" || true)
    if [ "$PEER_LINES" -eq 0 ]; then
        say WARN "没有已配置的 Peer (尚无客户端)"
    else
        say INFO "共 ${PEER_LINES} 个 Peer"
        echo "$WG_OUT" | awk -v thr=180 '
            BEGIN { RS="\n\n"; }
            /^peer:/ {
                pk=$0; sub(/^peer: /,"",pk);
                ep=""; hs=""; rx="0"; tx="0";
                if(match($0,/endpoint: [^ ]+/))       ep=substr($0,RSTART+9,RLENGTH-9);
                if(match($0,/latest handshake: .*/))  {hs=substr($0,RSTART+18,RLENGTH-18); gsub(/\n/,"",hs);}
                if(match($0,/transfer: .*/))          tf=substr($0,RSTART+10,RLENGTH-10);
                # 简易打印
                printf "    peer %s\n      endpoint: %s\n      handshake: %s\n      transfer: %s\n", pk, ep, hs, tf;
            }
        '
        # 逐个 peer 判定 (用 if/elif 避免 case 模式对特殊字符的解析问题)
        cur_pk=""
        while IFS= read -r line; do
            if [ -z "$line" ]; then
                continue
            fi
            case "$line" in
                peer:*)
                    cur_pk=$(echo "$line" | sed 's/peer: //')
                    ;;
            esac
            case "$line" in
                *latest\ handshake*)
                    hs=$(echo "$line" | sed 's/.*latest handshake: //')
                    if [ -z "$hs" ] || echo "$hs" | grep -qi "never"; then
                        say WARN "Peer ${cur_pk:0:16}... 从未握手 -> 客户端未连上 / 密钥不匹配 / 端口被拦"
                    else
                        sec=$(handshake_to_sec "$hs")
                        if [ "$sec" -gt 180 ]; then
                            say WARN "Peer ${cur_pk:0:16}... 握手 ${hs} (>180s) -> 疑似僵死"
                        else
                            say OK "Peer ${cur_pk:0:16}... 握手 ${hs} (正常)"
                        fi
                    fi
                    ;;
                *transfer*)
                    tf=$(echo "$line" | sed 's/.*transfer: //')
                    rx=$(echo "$tf" | grep -oE '[0-9.]+ [KMG]?i?B received' || true)
                    if [ -z "$rx" ]; then
                        say WARN "Peer ${cur_pk:0:16}... 无接收流量 -> 隧道可能假活"
                    fi
                    ;;
            esac
        done <<< "$WG_OUT"
    fi
fi

# ============================================================
# 8. 模拟客户端连通性测试 (在服务端本机用 wg 网段探测)
# ============================================================
header "8. 连通性测试 (服务端视角)"
SRV_IP=$(grep -E "^Address" "$CONF" 2>/dev/null | head -1 | grep -oE '[0-9.]+' | head -1)
if [ -z "$SRV_IP" ]; then
    # 从 ip addr 取
    SRV_IP=$(ip addr show "$INTERFACE" 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)
fi
say INFO "服务端 VPN IP: ${SRV_IP:-未知}"

# 测试外网 (服务端自己能否出网，间接反映 NAT 目标是否可达)
if ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then
    say OK "服务端自身可访问外网 (8.8.8.8)"
else
    say WARN "服务端自身无法访问 8.8.8.8 (不影响VPN但需留意出口)"
fi

# ============================================================
# 9. 防火墙 / 安全组提示
# ============================================================
header "9. 防火墙 / 端口监听"
PORT=$(grep -E "^ListenPort" "$CONF" 2>/dev/null | grep -oE '[0-9]+' || echo 51820)
if ss -uln 2>/dev/null | grep -q ":${PORT} "; then
    say OK "UDP ${PORT} 正在监听"
else
    say FAIL "UDP ${PORT} 未监听 → 客户端根本连不进来"
fi
say INFO "若使用云服务器(AWS/阿里云)，请确认安全组入站放行 UDP:${PORT}"

# ============================================================
# 10. 客户端侧检查提示 (无法在服务端自动验证，给出命令)
# ============================================================
header "10. 请在【客户端】上执行以下命令验证上网"
cat <<EOF >&2
  ${YELLOW}# 连上VPN后依次测试：${NC}
  ping ${SRV_IP:-10.8.0.1}           # 通 → 隧道OK
  ping 8.8.8.8              # 通 → 转发/NAT OK
  nslookup google.com        # 通 → DNS OK
  ${YELLOW}# 现象对照：${NC}
  # 内网通 / 8.8.8.8不通 → 服务端 NAT/转发问题 (见第3,5项)
  # 8.8.8.8通 / 域名不通  → 客户端 DNS 问题 (conf 加 DNS=8.8.8.8)
  # 全不通              → 客户端 AllowedIPs 或路由问题
EOF

# ============================================================
# 汇总
# ============================================================
header "汇总"
echo -e "  ${GREEN}OK   : ${OK_C}${NC}" >&2
echo -e "  ${YELLOW}WARN : ${WARN_C}${NC}" >&2
echo -e "  ${RED}FAIL : ${FAIL_C}${NC}" >&2
log "===== 诊断结束 OK=$OK_C WARN=$WARN_C FAIL=$FAIL_C ====="

if [ "$FIX" -eq 1 ]; then
    say INFO "已执行自动修复，建议重新运行不带 --fix 确认: bash $0 ${INTERFACE}"
fi

# 有 FAIL 返回非0，方便脚本/定时任务判断
[ "$FAIL_C" -eq 0 ]
