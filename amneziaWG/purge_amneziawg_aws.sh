#!/usr/bin/env bash

set -Eeuo pipefail

readonly WG_INTERFACE="awg0"
readonly CONFIG_DIR="/etc/amnezia/amneziawg"
readonly EXPORT_DIR="/home/ubuntu/amneziawg"
readonly ADD_CLIENT_SCRIPT="/usr/local/sbin/amneziawg-add-client"

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

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 sudo 运行"
}

confirm_delete() {
    echo
    echo "============================================================"
    echo " WARNING: AmneziaWG 清理程序"
    echo "============================================================"
    echo
    echo "此操作将删除："
    echo
    echo "  - ${WG_INTERFACE}"
    echo "  - ${CONFIG_DIR}"
    echo "  - ${EXPORT_DIR}"
    echo "  - ${ADD_CLIENT_SCRIPT}"
    echo "  - AmneziaWG DKMS"
    echo "  - awg / awg-quick"
    echo "  - Amnezia PPA"
    echo "  - AmneziaWG sysctl 配置"
    echo
    echo "请输入 DELETE 确认："
    read -r confirmation

    [[ "${confirmation}" == "DELETE" ]] \
        || die "未确认，取消清理"
}

stop_service() {
    log "停止 AmneziaWG 服务"

    systemctl stop "awg-quick@${WG_INTERFACE}" 2>/dev/null || true
    systemctl disable "awg-quick@${WG_INTERFACE}" 2>/dev/null || true
}

remove_interface() {
    log "删除 ${WG_INTERFACE}"

    if ip link show "${WG_INTERFACE}" >/dev/null 2>&1; then
        awg-quick down "${WG_INTERFACE}" 2>/dev/null || true
    fi

    ip link delete "${WG_INTERFACE}" 2>/dev/null || true
}

remove_iptables_rules() {
    log "清理 AmneziaWG iptables 规则"

    local iface=""

    if ip route show default >/dev/null 2>&1; then
        iface="$(ip route show default | awk 'NR==1 {print $5}')"
    fi

    if [[ -z "${iface}" ]]; then
        warn "无法检测默认网卡，跳过 NAT 规则清理"
        return
    fi

    iptables -D FORWARD \
        -i "${WG_INTERFACE}" \
        -j ACCEPT \
        2>/dev/null || true

    iptables -D FORWARD \
        -o "${WG_INTERFACE}" \
        -m conntrack \
        --ctstate RELATED,ESTABLISHED \
        -j ACCEPT \
        2>/dev/null || true

    iptables -t nat -D POSTROUTING \
        -s 10.66.66.0/24 \
        -o "${iface}" \
        -j MASQUERADE \
        2>/dev/null || true
}

remove_sysctl() {
    log "删除 AmneziaWG sysctl 配置"

    rm -f /etc/sysctl.d/99-amneziawg.conf

    # 重新加载 sysctl。
    sysctl --system >/dev/null 2>&1 || true
}

remove_helper() {
    log "删除客户端管理脚本"

    rm -f "${ADD_CLIENT_SCRIPT}"
}

remove_configs() {
    log "删除 AmneziaWG 配置"

    rm -rf "${CONFIG_DIR}"
    rm -rf "${EXPORT_DIR}"

    # 如果目录已经为空，也删除上一级目录。
    rmdir /etc/amnezia 2>/dev/null || true
}

remove_dkms() {
    log "删除 AmneziaWG DKMS"

    if command -v dkms >/dev/null 2>&1; then
        while read -r module version; do
            [[ -n "${module:-}" ]] || continue
            [[ -n "${version:-}" ]] || continue

            if [[ "${module}" == "amneziawg" ]]; then
                dkms remove \
                    "${module}/${version}" \
                    --all \
                    2>/dev/null || true
            fi
        done < <(
            dkms status 2>/dev/null |
            sed -n 's/^amneziawg\/\([^,]*\),.*/amneziawg \1/p' |
            sort -u
        )
    fi

    DEBIAN_FRONTEND=noninteractive apt-get remove -y \
        amneziawg-dkms \
        2>/dev/null || true
}

remove_tools() {
    log "删除 awg / awg-quick"

    rm -f /usr/bin/awg
    rm -f /usr/bin/awg-quick

    rm -f /usr/share/man/man8/awg.8*
    rm -f /usr/share/man/man8/awg-quick.8*

    rm -f /usr/share/bash-completion/completions/awg
    rm -f /usr/share/bash-completion/completions/awg-quick

    rm -f /usr/lib/systemd/system/awg-quick@.service
    rm -f /usr/lib/systemd/system/awg-quick.target

    rm -f /lib/systemd/system/awg-quick@.service
    rm -f /lib/systemd/system/awg-quick.target

    systemctl daemon-reload
}

remove_source_leftovers() {
    log "删除源码临时目录"

    rm -rf /tmp/amneziawg-tools.*
}

remove_ppa() {
    log "删除 Amnezia PPA"

    rm -f \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.sources

    add-apt-repository \
        --remove \
        -y \
        ppa:amnezia/ppa \
        2>/dev/null || true

    apt-get update
}

remove_unused_packages() {
    log "清理不再需要的软件包"

    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
}

unload_module() {
    log "卸载 amneziawg 内核模块"

    modprobe -r amneziawg 2>/dev/null || true
}

verify_cleanup() {
    echo
    echo "============================================================"
    echo " 清理检查"
    echo "============================================================"

    if ip link show "${WG_INTERFACE}" >/dev/null 2>&1; then
        warn "${WG_INTERFACE} 仍然存在"
    else
        echo "[OK] ${WG_INTERFACE} 已删除"
    fi

    if [[ -d "${CONFIG_DIR}" ]]; then
        warn "${CONFIG_DIR} 仍然存在"
    else
        echo "[OK] ${CONFIG_DIR} 已删除"
    fi

    if [[ -d "${EXPORT_DIR}" ]]; then
        warn "${EXPORT_DIR} 仍然存在"
    else
        echo "[OK] ${EXPORT_DIR} 已删除"
    fi

    if [[ -e "${ADD_CLIENT_SCRIPT}" ]]; then
        warn "${ADD_CLIENT_SCRIPT} 仍然存在"
    else
        echo "[OK] 客户端管理脚本已删除"
    fi

    if lsmod | grep -q '^amneziawg'; then
        warn "amneziawg 内核模块仍然加载"
    else
        echo "[OK] amneziawg 内核模块已卸载"
    fi

    echo
    echo "清理完成。"
}

main() {
    require_root
    confirm_delete

    stop_service
    remove_interface
    remove_iptables_rules
    remove_sysctl
    remove_helper
    remove_configs
    remove_dkms
    remove_tools
    remove_source_leftovers
    remove_ppa
    remove_unused_packages
    unload_module
    verify_cleanup
}

main "$@"