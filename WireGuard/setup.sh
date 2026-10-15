#!/usr/bin/env bash
# ============================================================
# WireGuard 一键部署脚本（Ubuntu / Debian / 适配 AWS EC2）
# ------------------------------------------------------------
# 功能：自动安装 WireGuard，生成服务端密钥，默认创建 2 个客户端
#       （client1 / client2），写配置文件，启动隧道，
#       并把所有配置文件 + 每个客户端的二维码图片(PNG)
#       统一导出到 /home/ubuntu/wireguard 目录。
#       （终端不再打印二维码，手机直接扫描 PNG 图片即可导入）
#
# 用法：
#   【首次部署 / 完整部署】  sudo bash wg-quick-setup.sh
#                          （默认自动创建 client1、client2）
#   【新增一个客户端】      sudo ADD_CLIENT=2 bash wg-quick-setup.sh
#                          sudo ADD_CLIENT=3 bash wg-quick-setup.sh
#                          （数字 = 客户端编号，自动分配 10.8.0.<编号+1>）
#
# 幂等说明：服务端密钥、客户端密钥【已存在则不再重新生成】，
#           重复执行不会破坏已有客户端。新增客户端时只追加，
#           不会覆盖 wg0.conf 里已有的 Peer。
# ============================================================

# set -e：任何一条命令返回非 0 就立即退出，防止半截状态继续往下跑
set -e

# ============================================================
# 第一步：安装依赖软件
# ============================================================
echo "==> 更新软件包索引..."
apt-get update -y

echo "==> 安装 wireguard、qrencode、curl..."
# wireguard : WireGuard 主程序（含 wg / wg-quick）
# qrencode  : 把客户端配置生成二维码，方便手机扫码导入
# curl      : 用来探测公网 IP（访问 metadata / ifconfig.me）
apt-get install -y wireguard qrencode curl

# ============================================================
# 第二步：收集可交互参数（全部有默认值，直接回车即可）
#   注意：新增客户端模式（ADD_CLIENT）下这些不再询问，直接用默认值
# ============================================================
WG_NET="10.8.0.0/24"
WG_SRV="10.8.0.1"
WG_PORT="51820"

# 只有【完整部署 + 标准输入是终端】时才交互询问；
# 非交互（管道/ADD_CLIENT 模式）直接取默认值，避免 read 被输入流干扰
if [ -z "${ADD_CLIENT:-}" ] && [ -t 0 ]; then
    read -r -p "隧道子网 [默认: ${WG_NET}]: " INPUT
    WG_NET="${INPUT:-${WG_NET}}"
    read -r -p "服务端内网 IP [默认: ${WG_SRV}]: " INPUT
    WG_SRV="${INPUT:-${WG_SRV}}"
    read -r -p "监听端口 [默认: ${WG_PORT}]: " INPUT
    WG_PORT="${INPUT:-${WG_PORT}}"
fi

# ============================================================
# 第三步：探测服务端公网 IP（作为客户端 Endpoint）
#   优先用 AWS 元数据服务 169.254.169.254（内网拿，最可靠）
#   失败则回退到外部服务 ifconfig.me
# ============================================================
echo "==> 探测公网 IP..."
PUB_IP=""
# 先试 AWS metadata，超时 3 秒
if curl -s --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 >/dev/null; then
    PUB_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
fi
# 若 metadata 拿不到（非 AWS 环境），再用 ifconfig.me
if [ -z "$PUB_IP" ]; then
    PUB_IP=$(curl -s --max-time 5 https://ifconfig.me || true)
fi
# 仅在完整部署 + tty 时让用户确认/修改探测结果；其余情况直接用探测值
if [ -z "${ADD_CLIENT:-}" ] && [ -t 0 ]; then
    read -r -p "服务端公网 IP (Endpoint) [探测到: $PUB_IP]: " INPUT_IP
    PUB_IP="${INPUT_IP:-$PUB_IP}"
fi

# ============================================================
# 第四步：探测出口网卡（做 NAT 伪装时需要指定"从哪个网卡出去"）
#   例如默认路由走 eth0，则 MASQUERADE 就作用在 eth0 上
# ============================================================
echo "==> 探测出口网卡..."
IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
IFACE="${IFACE:-eth0}"   # 探测为空时兜底用 eth0，避免生成无效规则
if [ -z "${ADD_CLIENT:-}" ] && [ -t 0 ]; then
    read -r -p "出口网卡 [探测到: $IFACE]: " INPUT_IFACE
    IFACE="${INPUT_IFACE:-$IFACE}"
fi

# ============================================================
# 第五步：开启 IPv4 转发
#   允许 Linux 把从一个网卡收到的包转发到另一个网卡，
#   没有这步，客户端连上后只能跟服务端通信，上不了外网。
# ============================================================
echo "==> 开启 IPv4 转发..."
cat > /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward = 1
EOF
# sysctl --system：加载上面配置文件，立即生效（重启也保留）
sysctl --system >/dev/null

# ============================================================
# 第六步：生成 / 复用密钥对
#   WireGuard 基于 Curve25519 密钥对认证：
#   - server.key（合并文件）     : 服务端密钥对，含私钥 + 公钥
#   - clientN.key（合并文件）    : 客户端密钥对，含私钥 + 公钥
#   每个文件用"标签: 值"的形式同时存放私钥和公钥，一目了然：
#       PrivateKey: xxxx
#       PublicKey:  xxxx
#   umask 077：保证生成的密钥文件只有 root 可读，权限安全
# ============================================================
mkdir -p /etc/wireguard
cd /etc/wireguard
umask 077

# ===== 关键：若服务端密钥已存在，则【不再重新生成】 =====
#   原因：重复生成会换掉公钥，导致已有客户端全部失效、握手失败。
#   只有首次部署（server.key 不存在）时才生成。
if [ -f /etc/wireguard/server.key ]; then
    echo "==> 检测到已存在服务端密钥 server.key，跳过重新生成（保留原有密钥）"
else
    echo "==> 生成服务端密钥..."
    # 写入 server.key（合并文件：私钥+公钥）
    {
        PRIV=$(wg genkey)
        PUB=$(echo "${PRIV}" | wg pubkey)
        echo "PrivateKey: ${PRIV}"
        echo "PublicKey:  ${PUB}"
    } > server.key
fi
SRV_PRIV=$(grep '^PrivateKey:' server.key | cut -d: -f2- | tr -d ' ')
SRV_PUB=$(grep  '^PublicKey:'  server.key | cut -d: -f2- | tr -d ' ')

# ============================================================
# 通用函数：新增一个客户端
#   用法 : add_client <编号> <VPN内网IP>
#   例如 : add_client 1 10.8.0.2
#          add_client 2 10.8.0.3
#   功能 : 1) 密钥已存在则跳过（幂等，不破坏已有客户端）
#          2) 向 wg0.conf 追加 [Peer] 段（按公钥去重，不重复追加）
#          3) 生成对应的 clientN.conf
#   密钥文件 : clientN.key（合并文件，含 PrivateKey + PublicKey）
# ============================================================
add_client() {
    local NUM="$1"          # 客户端编号，如 1、2
    local CLI_IP="$2"       # 分配的 VPN 内网 IP，如 10.8.0.2
    local KEY="client${NUM}.key"   # 合并文件：私钥+公钥
    local CONF="client${NUM}.conf"

    # ---- 1. 密钥对：存在则跳过（幂等，不破坏已有客户端）----
    #   clientN.key 同时存放 PrivateKey 和 PublicKey 两行
    if [ -f "/etc/wireguard/${KEY}" ]; then
        echo "==> 检测到已存在 ${KEY}，跳过重新生成（保留原有密钥）"
    else
        echo "==> 生成客户端${NUM}密钥..."
        # 写入合并文件：私钥 + 公钥
        {
            PRIV=$(wg genkey)
            PUB=$(echo "${PRIV}" | wg pubkey)
            echo "PrivateKey: ${PRIV}"
            echo "PublicKey:  ${PUB}"
        } > "/etc/wireguard/${KEY}"
    fi
    local CLI_PRIV CLI_PUB
    CLI_PRIV=$(grep '^PrivateKey:' "/etc/wireguard/${KEY}" | cut -d: -f2- | tr -d ' ')
    CLI_PUB=$(grep  '^PublicKey:'  "/etc/wireguard/${KEY}" | cut -d: -f2- | tr -d ' ')

    # ---- 2. 若 wg0.conf 中还没有该客户端的 Peer 段，则追加 ----
    #    用公钥作为唯一标识：同一客户端重复调用不会重复添加
    if grep -q "${CLI_PUB}" /etc/wireguard/wg0.conf; then
        echo "==> wg0.conf 中已存在客户端${NUM}的 Peer，跳过追加"
    else
        echo "==> 向 wg0.conf 追加客户端${NUM}的 Peer (${CLI_IP}/32)..."
        cat >> /etc/wireguard/wg0.conf <<EOF

# 客户端${NUM}
[Peer]
PublicKey = ${CLI_PUB}
AllowedIPs = ${CLI_IP}/32
# 服务端对每个 Peer 主动保活，防客户端侧 NAT 超时导致"长时间不连就连不上"
PersistentKeepalive = 25
EOF
    fi

    # ---- 3. 生成该客户端的 clientN.conf（存在则覆盖更新 Peer 信息）----
    #    注意：客户端的 [Interface] 私钥保持不变（上面已保证不重新生成）
    cat > "/etc/wireguard/${CONF}" <<EOF
[Interface]
Address = ${CLI_IP}/24          # 客户端在 VPN 里的 IP，须与服务端 Peer 的 AllowedIPs 对应
PrivateKey = ${CLI_PRIV}       # 客户端自己的私钥
DNS = 8.8.8.8                  # 使用公共 DNS，避免 AWS 内网 DNS 在客户端侧不可达
MTU = 1280                     # 保守 MTU，解决部分网络大包被丢导致的"很慢"问题

[Peer]
PublicKey = ${SRV_PUB}         # 服务端的公钥（告诉客户端"连谁"）
Endpoint = ${PUB_IP}:${WG_PORT}  # 服务端公网 IP + 端口，客户端靠这个找到服务器
AllowedIPs = 0.0.0.0/0, ::/0   # 全局模式：所有 IPv4/IPv6 流量走隧道；仅内网可改 10.8.0.0/24
PersistentKeepalive = 25        # 每 25 秒保活，防家庭宽带/手机 NAT 超时断连
EOF
    echo "==> 已生成 /etc/wireguard/${CONF}"
}

# ============================================================
# 给【服务端 wg0.conf】里所有 [Peer] 补齐 PersistentKeepalive
#   （PersistentKeepalive 是 [Peer] 段参数，必须写在这里而非 [Interface]）
#   对已有部署（早期 Peer 缺保活）也做兜底补齐
# ============================================================
ensure_server_keepalive() {
    local CONF="/etc/wireguard/wg0.conf"
    [ -f "${CONF}" ] || return 0

    echo "==> 检查服务端 ${CONF} 各 Peer 的 PersistentKeepalive ..."

    # 对每个 [Peer] 段保证恰好一行 "PersistentKeepalive = 25"：
    #   - 删除该段内原有的保活行（无论是否已有）
    #   - 在 AllowedIPs 行之后统一重新插入一行
    # 这样天然幂等：有则归一到标准格式，无则补齐；重复调用绝不会累加。
    local TMP
    TMP=$(mktemp)
    awk '
        /^\[Peer\]/ {
            # 上一个 [Peer] 段若没有保活行，在此处（段首后）补 —— 见下方 PublicKey 分支
            in_peer=1; printed=0
            print
            next
        }
        /^PublicKey = / && in_peer {
            print
            # 标记：该段需要保活行，紧跟在 PublicKey 之后由 AllowedIPs 分支插入
            need=1
            next
        }
        /^AllowedIPs/ && in_peer && need && !printed {
            print
            print "PersistentKeepalive = 25"
            printed=1; need=0
            next
        }
        /^PersistentKeepalive/ {
            # 丢弃所有原有保活行，由上面统一再生
            next
        }
        { print }
        END {
            # 若最后一个 [Peer] 段只有 PublicKey 没有 AllowedIPs，在此兜底补一行
            if (in_peer && need && !printed) print "PersistentKeepalive = 25"
        }
    ' "${CONF}" > "${TMP}"
    mv "${TMP}" "${CONF}"

    echo "==> 服务端 Peer 保活检查完成"
}

# ============================================================
# 把已有客户端配置(.conf)也补齐 PersistentKeepalive 的兜底函数
#   会对所有 client*.conf 检查：缺则追加，确保一致
# ============================================================
ensure_client_keepalive() {
    local CONF
    for CONF in /etc/wireguard/client*.conf; do
        [ -f "${CONF}" ] || continue
        # [Peer] 段里没有 PersistentKeepalive 才追加
        if ! grep -q '^PersistentKeepalive' "${CONF}"; then
            echo "==> 为 ${CONF} 补齐 PersistentKeepalive = 25"
            # 在 [Peer] 段后追加一行（若文件末尾无空行也兼容）
            printf '\n# 保活：防 NAT 超时（自动补齐）\nPersistentKeepalive = 25\n' >> "${CONF}"
        fi
    done
}

# ============================================================
# 把 /etc/wireguard 导出到 /home/ubuntu 的收尾函数
#   （无论哪种运行模式，最后都执行这几行，方便拉取配置）
# ============================================================
export_wireguard_config() {
    local EXPORT_DIR="/home/ubuntu/wireguard"

    echo "==> 导出配置文件到 ${EXPORT_DIR} ..."
    rm -rf "${EXPORT_DIR}"
    cp -R /etc/wireguard "${EXPORT_DIR}"

    # ---- 为每个客户端配置生成二维码图片（PNG），与配置文件放在同一目录 ----
    #   生成二维码前先去掉 conf 里的 # 注释和空行：
    #   1) 注释对 WireGuard 无意义，去掉后二维码更小、更容易扫描
    #   2) 避免中文注释带来的编码问题
    #   参数：-t PNG 输出 PNG；-s 8 每个模块 8 像素（图片清晰）；-m 2 留白 2 格
    local CONF NAME
    for CONF in /etc/wireguard/client*.conf; do
        [ -f "${CONF}" ] || continue
        NAME=$(basename "${CONF}" .conf)
        sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${CONF}" \
            | qrencode -t PNG -s 8 -m 2 -o "${EXPORT_DIR}/${NAME}.png"
        echo "==> 已生成二维码图片 ${EXPORT_DIR}/${NAME}.png"
    done

    chown -R ubuntu:ubuntu "${EXPORT_DIR}"
    chmod -R 600 "${EXPORT_DIR}"
    chmod -R +X "${EXPORT_DIR}"
}

# ============================================================
# 第七步：写服务端 wg0.conf 的 [Interface] 段（固定，仅首次写）
#   说明：为避免覆盖已有的 [Peer]，只有文件不存在时才写 Interface 框架；
#         Peer 全部由 add_client 追加。
# ============================================================
if [ -f /etc/wireguard/wg0.conf ] && grep -q "\[Interface\]" /etc/wireguard/wg0.conf; then
    echo "==> 检测到已有 wg0.conf 的 [Interface] 段，保留不覆盖"
else
    echo "==> 写服务端配置 /etc/wireguard/wg0.conf ..."
    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_SRV}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SRV_PRIV}

# PostUp  : 启动隧道时自动执行 —— 允许转发 + 做 NAT 伪装（让客户端以服务器 IP 出网）
# PostDown: 关闭隧道时自动清理上述规则，避免残留
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${IFACE} -j MASQUERADE
EOF
fi

# 无论 wg0.conf 是新建还是已存在，都确保其中所有 Peer 有 PersistentKeepalive
ensure_server_keepalive

# ============================================================
# 第八步：根据模式处理客户端
#   - 完整部署 (ADD_CLIENT 为空) : 确保客户端1就绪（已存在则跳过，幂等）
#   - 新增客户端 (ADD_CLIENT=N)  : 新增第 N 个客户端
# ============================================================
if [ -n "${ADD_CLIENT:-}" ]; then
    # 新增客户端模式：如 ADD_CLIENT=2 → 编号2，IP 10.8.0.3
    CLI_NUM="${ADD_CLIENT}"
    CLI_IP="10.8.0.$(( CLI_NUM + 1 ))"
    echo "==> [新增客户端模式] 添加客户端 ${CLI_NUM} (${CLI_IP}/32)..."
    add_client "${CLI_NUM}" "${CLI_IP}"
    # 让新 Peer 生效（重载配置，不断已有连接）
    systemctl reload wg-quick@wg0 2>/dev/null || systemctl restart wg-quick@wg0

    # 兜底：确保所有客户端配置都有保活参数
    ensure_client_keepalive
    # 导出配置到 /home/ubuntu，方便拉取
    export_wireguard_config

    echo ""
    echo "============================================================"
    echo " 客户端 ${CLI_NUM} 添加完成！"
    echo "============================================================"
    echo "--------------- /etc/wireguard/client${CLI_NUM}.conf ---------------"
    cat "/etc/wireguard/client${CLI_NUM}.conf"
    echo "--------------------------------------------------------------"
    echo ""
    echo "==> 导入方式："
    echo "  - 二维码图片：/home/ubuntu/wireguard/client${CLI_NUM}.png（手机 WireGuard App 直接扫图片）"
    echo "  - 或传回 Windows / 手机导入 /home/ubuntu/wireguard/client${CLI_NUM}.conf"
    echo "  - 同时在线：每个客户端独立编号、独立 IP 即可"
    echo "  - 换着用（不同时在线）：同一份 conf 拷多台设备即可"
    echo "============================================================"
    exit 0
fi

# ===== 完整部署模式：默认创建 2 个客户端（client1 → 10.8.0.2，client2 → 10.8.0.3）=====
#   每个客户端若已存在则跳过，避免重复创建；
#   需要更多客户端请用：sudo ADD_CLIENT=3 bash setup.sh
DEFAULT_CLIENTS="1 2"
for N in ${DEFAULT_CLIENTS}; do
    if [ -f "/etc/wireguard/client${N}.key" ]; then
        echo "==> 检测到客户端${N} 已存在，跳过创建（如需重建请先清理 client${N}.key / wg0.conf 中对应 Peer）"
    else
        add_client "${N}" "10.8.0.$(( N + 1 ))"
    fi
done

# ============================================================
# 第九步：打印密钥存放地址 + 密钥内容
#   方便记录备份，以及排查"客户端连不上"这类问题
# ============================================================
echo ""
echo "============================================================"
echo " 密钥存放地址与内容（每个实体一个合并文件，含私钥+公钥）"
echo "============================================================"
echo " 存放目录 : /etc/wireguard/"
echo ""
echo " [服务端]"
echo "   密钥文件 : /etc/wireguard/server.key （含 PrivateKey + PublicKey）"
echo "   server.key 内容（私钥仅服务端持有，绝不可外泄）:"
echo "----------------------------------------"
cat /etc/wireguard/server.key
echo "----------------------------------------"
echo ""
for N in ${DEFAULT_CLIENTS}; do
    echo " [客户端 client${N}]"
    echo "   密钥文件 : /etc/wireguard/client${N}.key （含 PrivateKey + PublicKey）"
    echo "   client${N}.key 内容（私钥填入客户端 [Interface]，公钥填入服务端 [Peer]）:"
    echo "----------------------------------------"
    cat "/etc/wireguard/client${N}.key"
    echo "----------------------------------------"
    echo ""
done
echo "============================================================"
echo ""

# ============================================================
# 第十步：启动并设置开机自启
#   enable  : 开机自动启动（重启服务器后无需手动操作）
#   restart : 立即启动 / 重载配置
# ============================================================
echo "==> 设置开机自启..."
if systemctl enable wg-quick@wg0; then
    echo "开机自启已设置"
else
    echo "⚠️ enable 失败，请检查 systemd"
fi
systemctl restart wg-quick@wg0

# ============================================================
# 第十一步：输出结果 + 客户端配置 + 二维码
# ============================================================
echo ""
echo "============================================================"
echo " WireGuard 部署完成！"
echo "============================================================"
echo " 服务端状态："
wg show
for N in ${DEFAULT_CLIENTS}; do
    echo ""
    echo "--------------- 客户端配置 client${N}.conf ---------------"
    cat "/etc/wireguard/client${N}.conf"
    echo "--------------------------------------------------------"
done

# ============================================================
# 收尾：兜底所有客户端保活 + 服务端保活 + 导出配置到 /home/ubuntu
#   同时在 /home/ubuntu/wireguard 生成每个客户端的二维码图片(PNG)
#   （必须放在最终提示之前，这样提示里列出的文件一定已存在）
# ============================================================
ensure_server_keepalive
ensure_client_keepalive
export_wireguard_config

echo ""
echo "==> 所有配置文件及二维码图片已保存到 /home/ubuntu/wireguard ："
ls -l /home/ubuntu/wireguard
echo ""
echo "==> 下一步："
echo "  1) AWS 安全组放行 UDP ${WG_PORT}"
echo "  2) 手机：把 /home/ubuntu/wireguard/client1.png、client2.png 下载到本地，"
echo "     打开 WireGuard App →「添加隧道」→「扫描二维码」，扫描图片即可导入"
echo "  3) 电脑：下载 client1.conf / client2.conf，在 WireGuard 客户端 Import 即可"
echo "     scp ubuntu@${PUB_IP}:/home/ubuntu/wireguard/client*.{conf,png} ./"
echo "  4) 新增客户端：sudo ADD_CLIENT=3 bash setup.sh（同样会生成对应 PNG）"
echo "============================================================"
