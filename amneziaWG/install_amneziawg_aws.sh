#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# AmneziaWG AWS Installer
#
# Target:
#   Ubuntu 26.04
#   AWS EC2
#   amd64
#
# Components:
#   amneziawg-dkms
#   amneziawg-tools
#
# Network:
#   Interface: awg0
#   UDP port: 445
#   VPN subnet: 10.66.66.0/24
#
# Config:
#   /etc/amnezia/amneziawg/
#
# Export:
#   /home/ubuntu/amneziawg/
#
# Client helper:
#   /usr/local/sbin/amneziawg-add-client
#
###############################################################################

WG_INTERFACE="awg0"
WG_PORT="445"

CONFIG_DIR="/etc/amnezia/amneziawg"
CLIENT_DIR="${CONFIG_DIR}/clients"
EXPORT_DIR="/home/ubuntu/amneziawg"

SERVER_CONF="${CONFIG_DIR}/${WG_INTERFACE}.conf"
SERVER_PRIVATE_KEY="${CONFIG_DIR}/server_private.key"
SERVER_PUBLIC_KEY="${CONFIG_DIR}/server_public.key"

ADD_CLIENT_SCRIPT="/usr/local/sbin/amneziawg-add-client"

TOOLS_VERSION="v3.1.20260812"
TOOLS_REPO="https://github.com/amnezia-vpn/amneziawg-tools.git"

WG_NETWORK="10.66.66.0/24"
SERVER_IP="10.66.66.1/24"

# AmneziaWG parameters
JC="7"
JMIN="40"
JMAX="80"
S1="50"
S2="100"
H1="39317681"
H2="377281354"
H3="1565363863"
H4="244732598"

BUILD_DIR=""

###############################################################################
# Common functions
###############################################################################

log() {
    echo
    echo "[INFO] $*"
}

warn() {
    echo
    echo "[WARN] $*" >&2
}

die() {
    echo
    echo "[ERROR] $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${BUILD_DIR}" && -d "${BUILD_DIR}" ]]; then
        rm -rf "${BUILD_DIR}"
    fi
}

trap cleanup EXIT

###############################################################################
# Root
###############################################################################

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请使用 sudo 运行此脚本"
    fi
}

###############################################################################
# OS
###############################################################################

check_os() {
    [[ -f /etc/os-release ]] || die "找不到 /etc/os-release"

    # shellcheck disable=SC1091
    source /etc/os-release

    echo "============================================================"
    echo " AmneziaWG AWS Installer"
    echo "============================================================"
    echo
    echo "OS:     ${PRETTY_NAME}"
    echo "Kernel: $(uname -r)"
    echo "Arch:   $(uname -m)"
    echo

    [[ "${ID}" == "ubuntu" ]] || die "此脚本仅针对 Ubuntu"

    if [[ "${VERSION_ID}" != "26.04" ]]; then
        warn "当前 Ubuntu 版本为 ${VERSION_ID}，此脚本主要针对 Ubuntu 26.04"
    fi

    if [[ "$(uname -m)" != "x86_64" ]]; then
        warn "当前架构不是 x86_64：$(uname -m)"
    fi
}

###############################################################################
# Dependencies
###############################################################################

install_dependencies() {
    log "安装依赖"

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates \
        curl \
        wget \
        git \
        build-essential \
        dkms \
        iproute2 \
        iptables \
        qrencode \
        software-properties-common \
        python3-launchpadlib \
        "linux-headers-$(uname -r)"
}

###############################################################################
# AmneziaWG kernel module
###############################################################################

install_dkms() {
    log "安装 AmneziaWG DKMS"

    add-apt-repository -y ppa:amnezia/ppa

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        amneziawg-dkms

    log "加载 amneziawg 内核模块"

    modprobe amneziawg

    if ! lsmod | grep -q '^amneziawg'; then
        die "amneziawg 内核模块加载失败"
    fi

    echo
    echo "DKMS:"
    dkms status || true

    echo
    echo "Module:"
    modinfo amneziawg || true
}

###############################################################################
# AmneziaWG userspace tools
###############################################################################

install_tools() {
    log "下载 amneziawg-tools ${TOOLS_VERSION}"

    BUILD_DIR="$(mktemp -d /tmp/amneziawg-tools.XXXXXX)"

    git clone \
        --depth 1 \
        --branch "${TOOLS_VERSION}" \
        "${TOOLS_REPO}" \
        "${BUILD_DIR}"

    [[ -d "${BUILD_DIR}/src" ]] || \
        die "找不到源码目录：${BUILD_DIR}/src"

    [[ -f "${BUILD_DIR}/src/Makefile" ]] || {
        echo
        echo "源码目录内容："
        find "${BUILD_DIR}" -maxdepth 2 -type f | sort || true
        die "找不到 ${BUILD_DIR}/src/Makefile"
    }

    log "编译 amneziawg-tools"

    make -C "${BUILD_DIR}/src"

    log "安装 amneziawg-tools"

    make -C "${BUILD_DIR}/src" install

    command -v awg >/dev/null 2>&1 || \
        die "安装完成后找不到 awg"

    command -v awg-quick >/dev/null 2>&1 || \
        die "安装完成后找不到 awg-quick"

    echo
    echo "awg:"
    command -v awg
    awg --version

    echo
    echo "awg-quick:"
    command -v awg-quick
}

###############################################################################
# Network detection
###############################################################################

detect_network() {
    DEFAULT_INTERFACE="$(
        ip route show default |
        awk 'NR==1 {print $5}'
    )"

    [[ -n "${DEFAULT_INTERFACE}" ]] || \
        die "无法检测默认网络接口"

    log "默认网络接口：${DEFAULT_INTERFACE}"
}

###############################################################################
# Public IPv4
###############################################################################

get_public_ip() {
    local token=""
    local ip=""

    # AWS IMDSv2
    token="$(
        curl \
            --silent \
            --show-error \
            --fail \
            --max-time 3 \
            -X PUT \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
            http://169.254.169.254/latest/api/token \
            2>/dev/null || true
    )"

    if [[ -n "${token}" ]]; then
        ip="$(
            curl \
                --silent \
                --show-error \
                --fail \
                --max-time 3 \
                -H "X-aws-ec2-metadata-token: ${token}" \
                http://169.254.169.254/latest/meta-data/public-ipv4 \
                2>/dev/null || true
        )"
    fi

    # Fallback
    if [[ -z "${ip}" ]]; then
        ip="$(
            curl \
                --silent \
                --show-error \
                --fail \
                --max-time 5 \
                https://api.ipify.org \
                2>/dev/null || true
        )"
    fi

    [[ -n "${ip}" ]] || die "无法获取公网 IPv4"

    echo "${ip}"
}

###############################################################################
# Sysctl
###############################################################################

configure_sysctl() {
    log "开启 IPv4 forwarding"

    cat > /etc/sysctl.d/99-amneziawg.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF

    sysctl --system >/dev/null

    [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || \
        die "IPv4 forwarding 开启失败"
}

###############################################################################
# Directories
###############################################################################

create_directories() {
    log "创建配置目录"

    mkdir -p \
        "${CONFIG_DIR}" \
        "${CLIENT_DIR}" \
        "${EXPORT_DIR}"

    chmod 700 "${CONFIG_DIR}"
    chmod 700 "${CLIENT_DIR}"
    chmod 700 "${EXPORT_DIR}"
}

###############################################################################
# Server keys
###############################################################################

generate_server_keys() {
    log "生成服务器密钥"

    umask 077

    awg genkey > "${SERVER_PRIVATE_KEY}"

    awg pubkey < "${SERVER_PRIVATE_KEY}" > "${SERVER_PUBLIC_KEY}"

    chmod 600 \
        "${SERVER_PRIVATE_KEY}" \
        "${SERVER_PUBLIC_KEY}"

    SERVER_PRIVATE="$(cat "${SERVER_PRIVATE_KEY}")"
    SERVER_PUBLIC="$(cat "${SERVER_PUBLIC_KEY}")"

    [[ -n "${SERVER_PRIVATE}" ]] || \
        die "服务器私钥为空"

    [[ -n "${SERVER_PUBLIC}" ]] || \
        die "服务器公钥为空"
}

###############################################################################
# Server configuration
###############################################################################

create_server_config() {
    log "创建服务器配置"

    cat > "${SERVER_CONF}" <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE}
Address = ${SERVER_IP}
ListenPort = ${WG_PORT}

Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -i %i -j ACCEPT; iptables -C FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -C POSTROUTING -s ${WG_NETWORK} -o ${DEFAULT_INTERFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${WG_NETWORK} -o ${DEFAULT_INTERFACE} -j MASQUERADE

PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true; iptables -t nat -D POSTROUTING -s ${WG_NETWORK} -o ${DEFAULT_INTERFACE} -j MASQUERADE 2>/dev/null || true
EOF

    chmod 600 "${SERVER_CONF}"
}

###############################################################################
# Client configuration generator
###############################################################################

create_client_files() {
    local client_name="$1"
    local client_ip="$2"
    local server_public="$3"
    local public_ip="$4"

    local client_private
    local client_public
    local client_conf
    local client_qr

    client_conf="${CLIENT_DIR}/${client_name}.conf"
    client_qr="${CLIENT_DIR}/${client_name}.png"

    client_private="$(awg genkey)"

    client_public="$(
        printf '%s\n' "${client_private}" |
        awg pubkey
    )"

    cat > "${client_conf}" <<EOF
[Interface]
PrivateKey = ${client_private}
Address = ${client_ip}/32
DNS = 1.1.1.1

Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = ${server_public}
AllowedIPs = 0.0.0.0/0
Endpoint = ${public_ip}:${WG_PORT}
PersistentKeepalive = 25
EOF

    chmod 600 "${client_conf}"

    qrencode \
        -o "${client_qr}" \
        < "${client_conf}"

    chmod 600 "${client_qr}"

    echo "${client_public}"
}

###############################################################################
# Client 1
###############################################################################

create_client1() {
    log "创建 client1"

    local client_name="client1"
    local client_ip="10.66.66.2"
    local client_public

    client_public="$(
        create_client_files \
            "${client_name}" \
            "${client_ip}" \
            "${SERVER_PUBLIC}" \
            "${PUBLIC_IP}"
    )"

    cat >> "${SERVER_CONF}" <<EOF

# Client: ${client_name}
[Peer]
PublicKey = ${client_public}
AllowedIPs = ${client_ip}/32
EOF

    chmod 600 "${SERVER_CONF}"
}

###############################################################################
# Client IP allocation
###############################################################################

find_next_client_ip() {
    local n
    local ip

    for n in $(seq 2 254); do
        ip="10.66.66.${n}"

        if ! grep -qE \
            "^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*${ip}/32[[:space:]]*$" \
            "${SERVER_CONF}"; then

            echo "${ip}"
            return 0
        fi
    done

    die "10.66.66.0/24 地址池已经用尽"
}

###############################################################################
# Validate client name
###############################################################################

validate_client_name() {
    local name="$1"

    [[ "${name}" =~ ^[a-zA-Z0-9_-]+$ ]] || \
        die "客户端名称只能包含字母、数字、下划线和短横线"

    [[ "${name}" != "awg0" ]] || \
        die "非法客户端名称"

    [[ "${name}" != "server" ]] || \
        die "非法客户端名称"
}

###############################################################################
# Sync export
###############################################################################

sync_export() {
    log "同步配置到 ${EXPORT_DIR}"

    mkdir -p "${EXPORT_DIR}"

    rm -rf "${EXPORT_DIR:?}/"*

    cp -a "${CONFIG_DIR}/." "${EXPORT_DIR}/"

    if id ubuntu >/dev/null 2>&1; then
        chown -R ubuntu:ubuntu "${EXPORT_DIR}"
    fi

    chmod 700 "${EXPORT_DIR}"

    find "${EXPORT_DIR}" \
        -type f \
        -exec chmod 600 {} \;
}

###############################################################################
# Install helper
#
# The installer copies THIS SAME SCRIPT to /usr/local/sbin.
# The dispatcher at the bottom detects the filename and enters client mode.
###############################################################################

install_client_helper() {
    log "安装客户端管理命令"

    install \
        -m 755 \
        "$0" \
        "${ADD_CLIENT_SCRIPT}"

    echo
    echo "客户端命令："
    echo "  sudo ${ADD_CLIENT_SCRIPT} client2"
}

###############################################################################
# Add client
###############################################################################

add_client() {
    require_root

    [[ $# -eq 1 ]] || \
        die "用法：sudo ${ADD_CLIENT_SCRIPT} client2"

    local client_name="$1"

    validate_client_name "${client_name}"

    [[ -f "${SERVER_CONF}" ]] || \
        die "服务器配置不存在：${SERVER_CONF}"

    [[ -f "${SERVER_PUBLIC_KEY}" ]] || \
        die "服务器公钥不存在：${SERVER_PUBLIC_KEY}"

    [[ -d "${CLIENT_DIR}" ]] || \
        die "客户端目录不存在：${CLIENT_DIR}"

    [[ ! -e "${CLIENT_DIR}/${client_name}.conf" ]] || \
        die "客户端 ${client_name} 已经存在"

    systemctl is-active --quiet \
        "awg-quick@${WG_INTERFACE}" || \
        die "${WG_INTERFACE} 当前没有运行"

    local client_ip
    local client_public
    local server_public
    local public_ip

    local client_conf
    local client_qr
    local backup_conf

    client_ip="$(find_next_client_ip)"

    log "分配 IP：${client_ip}"

    server_public="$(cat "${SERVER_PUBLIC_KEY}")"

    public_ip="$(get_public_ip)"

    client_conf="${CLIENT_DIR}/${client_name}.conf"
    client_qr="${CLIENT_DIR}/${client_name}.png"

    # Create client configuration.
    client_public="$(
        create_client_files \
            "${client_name}" \
            "${client_ip}" \
            "${server_public}" \
            "${public_ip}"
    )"

    # Backup server configuration before modification.
    backup_conf="$(mktemp)"

    cp -a \
        "${SERVER_CONF}" \
        "${backup_conf}"

    # Add peer.
    cat >> "${SERVER_CONF}" <<EOF

# Client: ${client_name}
[Peer]
PublicKey = ${client_public}
AllowedIPs = ${client_ip}/32
EOF

    chmod 600 "${SERVER_CONF}"

    log "热加载 ${WG_INTERFACE}"

    if ! systemctl reload "awg-quick@${WG_INTERFACE}"; then

        echo
        echo "[ERROR] awg0 热加载失败，正在恢复服务器配置"

        cp -a \
            "${backup_conf}" \
            "${SERVER_CONF}"

        rm -f \
            "${backup_conf}" \
            "${client_conf}" \
            "${client_qr}"

        systemctl reload "awg-quick@${WG_INTERFACE}" || true

        die "客户端 ${client_name} 添加失败"
    fi

    rm -f "${backup_conf}"

    # Verify peer has actually been loaded.
    if ! awg show "${WG_INTERFACE}" |
        grep -Fq "${client_public}"; then

        echo
        echo "[ERROR] 客户端已经写入配置文件，但没有加载到运行中的 awg0"

        die "客户端 ${client_name} 添加失败"
    fi

    # Copy entire config directory to export directory.
    sync_export

    echo
    echo "============================================================"
    echo " 客户端添加成功"
    echo "============================================================"
    echo
    echo "名称：     ${client_name}"
    echo "IP：       ${client_ip}/32"
    echo "服务器：   ${public_ip}:${WG_PORT}/UDP"
    echo
    echo "配置文件："
    echo "${client_conf}"
    echo
    echo "二维码："
    echo "${client_qr}"
    echo
    echo "导出目录："
    echo "${EXPORT_DIR}"
    echo
    echo "============================================================"
}

###############################################################################
# Start service
###############################################################################

start_service() {
    log "启动 ${WG_INTERFACE}"

    systemctl daemon-reload

    systemctl enable \
        "awg-quick@${WG_INTERFACE}"

    systemctl start \
        "awg-quick@${WG_INTERFACE}"

    if ! systemctl is-active --quiet \
        "awg-quick@${WG_INTERFACE}"; then

        echo
        echo "================ systemctl status ================"

        systemctl status \
            "awg-quick@${WG_INTERFACE}" \
            --no-pager \
            --full || true

        echo "=================================================="

        die "${WG_INTERFACE} 启动失败"
    fi
}

###############################################################################
# Verification
###############################################################################

verify_installation() {
    log "验证安装"

    command -v awg >/dev/null 2>&1 || \
        die "找不到 awg"

    command -v awg-quick >/dev/null 2>&1 || \
        die "找不到 awg-quick"

    lsmod | grep -q '^amneziawg' || \
        die "amneziawg 内核模块没有加载"

    ip link show "${WG_INTERFACE}" >/dev/null 2>&1 || \
        die "${WG_INTERFACE} 不存在"

    awg show "${WG_INTERFACE}" >/dev/null 2>&1 || \
        die "awg show ${WG_INTERFACE} 失败"

    grep -q \
        "^ListenPort = ${WG_PORT}$" \
        "${SERVER_CONF}" || \
        die "服务器监听端口不是 ${WG_PORT}"

    [[ -f "${CLIENT_DIR}/client1.conf" ]] || \
        die "client1.conf 不存在"

    [[ -f "${CLIENT_DIR}/client1.png" ]] || \
        die "client1.png 不存在"

    [[ -f "${EXPORT_DIR}/awg0.conf" ]] || \
        die "导出目录中没有 awg0.conf"

    [[ -f "${EXPORT_DIR}/clients/client1.conf" ]] || \
        die "导出目录中没有 client1.conf"

    echo
    echo "================ AWG STATUS ================"
    awg show "${WG_INTERFACE}"
    echo "============================================="
}

###############################################################################
# Installer main
###############################################################################

install_main() {
    require_root

    check_os

    install_dependencies

    install_dkms

    install_tools

    detect_network

    PUBLIC_IP="$(get_public_ip)"

    log "公网 IP：${PUBLIC_IP}"

    configure_sysctl

    create_directories

    generate_server_keys

    create_server_config

    create_client1

    install_client_helper

    start_service

    sync_export

    verify_installation

    echo
    echo "============================================================"
    echo " AmneziaWG 安装成功"
    echo "============================================================"
    echo
    echo "服务器："
    echo "${PUBLIC_IP}:${WG_PORT}/UDP"
    echo
    echo "接口："
    echo "${WG_INTERFACE}"
    echo
    echo "服务器配置："
    echo "${SERVER_CONF}"
    echo
    echo "client1："
    echo "${CLIENT_DIR}/client1.conf"
    echo
    echo "client1 QR："
    echo "${CLIENT_DIR}/client1.png"
    echo
    echo "导出目录："
    echo "${EXPORT_DIR}"
    echo
    echo "添加客户端："
    echo "sudo ${ADD_CLIENT_SCRIPT} client2"
    echo
    echo "例如："
    echo "sudo ${ADD_CLIENT_SCRIPT} client2"
    echo "sudo ${ADD_CLIENT_SCRIPT} client3"
    echo
    echo "============================================================"
    echo
    echo "[IMPORTANT] 请确认 AWS Security Group 已放行：UDP ${WG_PORT}"
    echo
	
	add_client client2
	echo "已添加客户端2"
}

###############################################################################
# Dispatcher
###############################################################################

case "$(basename "$0")" in

    amneziawg-add-client)
        add_client "$@"
        ;;

    *)
        install_main "$@"
        ;;

esac