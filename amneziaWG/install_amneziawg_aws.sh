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
# Backend (tried in this order, first success wins):
#   1) kernel module via PPA     : amneziawg-dkms (apt + DKMS)
#   2) kernel module from source : official amneziawg-linux-kernel-module repo
#   3) userspace                 : amneziawg-go (no kernel module needed)
#
# Tools (awg / awg-quick): PPA package first, then build from source.
#
# Force a backend:
#   sudo AWG_BACKEND=kernel    bash install_amneziawg_aws.sh   # 1 -> 2 only
#   sudo AWG_BACKEND=userspace bash install_amneziawg_aws.sh   # 3 only
#   (default: AWG_BACKEND=auto, i.e. 1 -> 2 -> 3)
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

# Backend selection: auto | kernel | userspace
AWG_BACKEND="${AWG_BACKEND:-auto}"

# Actually used backend (filled in by select_backend): kernel | userspace
BACKEND=""
BACKEND_DESC=""

AWG_GO_REPO="https://github.com/amnezia-vpn/amneziawg-go.git"
AWG_GO_REF="${AWG_GO_REF:-}"          # empty = default branch
AWG_GO_BIN="/usr/local/bin/amneziawg-go"
GO_FALLBACK_VERSION="go1.25.0"        # used only if go.dev version lookup fails

AWG_KMOD_REPO="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git"
AWG_KMOD_REF="${AWG_KMOD_REF:-}"      # empty = default branch

WORK_DIR=""
TEMP_SWAP=""
TOOLS_REF_USED=""

BASE_PACKAGES=(
    ca-certificates
    curl
    wget
    git
    build-essential
    dkms
    iproute2
    iptables
    qrencode
    software-properties-common
    python3-launchpadlib
)

# Dependency install summary (filled in while installing, printed at the end)
SUMMARY=()

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

summary_add() {
    SUMMARY+=("$1：$2")
}

print_install_summary() {
    local title="${1:-依赖安装总结}"

    if [[ "${#SUMMARY[@]}" -eq 0 ]]; then
        return 0
    fi

    local line

    echo
    echo "============================================================"
    echo " ${title}"
    echo "============================================================"

    for line in "${SUMMARY[@]}"; do
        echo "  - ${line}"
    done

    echo "============================================================"
}

die() {
    echo
    echo "[ERROR] $*" >&2
    print_install_summary "依赖安装状态（安装未完成）" >&2 || true
    exit 1
}

cleanup() {
    if [[ -n "${TEMP_SWAP}" && -f "${TEMP_SWAP}" ]]; then
        swapoff "${TEMP_SWAP}" >/dev/null 2>&1 || true
        rm -f "${TEMP_SWAP}" || true
    fi

    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
}

init_workdir() {
    if [[ -z "${WORK_DIR}" || ! -d "${WORK_DIR}" ]]; then
        WORK_DIR="$(mktemp -d /tmp/amneziawg-build.XXXXXX)"
    fi
}

# version_ge A B  ->  true if A >= B (dotted versions)
version_ge() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n '1p')" == "$2" ]]
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
    log "安装基础依赖"

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y "${BASE_PACKAGES[@]}"

    summary_add "基础依赖 安装方式" "apt（${BASE_PACKAGES[*]}）"
}

###############################################################################
# Backend 1/2: kernel module (1: PPA + DKMS, 2: build from source)
#
# NOTE: these functions are called inside `if`, where `set -e` is disabled,
#       so every step must explicitly `|| return 1`.
###############################################################################

cleanup_failed_kernel_install() {
    warn "清理失败的内核模块安装残留"

    local mod

    while read -r mod; do
        [[ -n "${mod}" ]] || continue
        dkms remove "${mod}" --all >/dev/null 2>&1 || true
    done < <(dkms status 2>/dev/null | sed -nE 's/^(amneziawg\/[^,:]+).*/\1/p' | sort -u)

    dpkg --remove --force-remove-reinstreq \
        amneziawg amneziawg-dkms amneziawg-tools >/dev/null 2>&1 || true

    DEBIAN_FRONTEND=noninteractive apt-get purge -y \
        amneziawg amneziawg-dkms amneziawg-tools >/dev/null 2>&1 || true

    DEBIAN_FRONTEND=noninteractive apt-get -f install -y >/dev/null 2>&1 || true

    dpkg --configure -a >/dev/null 2>&1 || true

    rmmod amneziawg 2>/dev/null || true
}

# Both kernel-module methods need the headers of the running kernel.
ensure_kernel_headers() {
    local kdir="/lib/modules/$(uname -r)/build"

    if [[ -d "${kdir}" ]]; then
        summary_add "内核 headers" "已存在，无需安装（$(uname -r)）"
        return 0
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        "linux-headers-$(uname -r)" || {
        warn "无法安装当前内核的 headers：linux-headers-$(uname -r)"
        summary_add "内核 headers" "apt 安装失败（linux-headers-$(uname -r)）"
        return 1
    }

    [[ -d "${kdir}" ]] || {
        warn "headers 已安装但找不到 ${kdir}"
        summary_add "内核 headers" "已安装但找不到 ${kdir}"
        return 1
    }

    summary_add "内核 headers 安装方式" "apt（linux-headers-$(uname -r)）"

    return 0
}

# Method 1: PPA package (amneziawg-dkms)
try_kernel_ppa() {
    log "方式 1：PPA 内核模块 (amneziawg-dkms)"

    add-apt-repository -y ppa:amnezia/ppa || {
        warn "添加 ppa:amnezia/ppa 失败"
        summary_add "Amnezia PPA" "添加失败"
        summary_add "内核模块 方式 1（PPA + DKMS）" "失败（PPA 不可用）"
        return 1
    }

    if ! apt-get update; then
        warn "apt-get update 失败（PPA 可能不支持当前 Ubuntu 版本），移除该 PPA"
        add-apt-repository -y -r ppa:amnezia/ppa >/dev/null 2>&1 || true
        summary_add "Amnezia PPA" "不支持当前系统，已移除"
        summary_add "内核模块 方式 1（PPA + DKMS）" "失败（PPA 不可用）"
        return 1
    fi

    summary_add "Amnezia PPA" "已添加（ppa:amnezia/ppa）"

    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y amneziawg-dkms; then
        warn "amneziawg-dkms 安装/编译失败（内核 $(uname -r) 可能暂不受支持）"

        local logf
        for logf in /var/lib/dkms/amneziawg/*/build/make.log; do
            if [[ -f "${logf}" ]]; then
                echo
                echo "---- ${logf}（末尾 30 行）----"
                tail -n 30 "${logf}" || true
                echo "------------------------------"
            fi
        done

        cleanup_failed_kernel_install
        summary_add "内核模块 方式 1（PPA + DKMS）" "失败（DKMS 编译错误，已清理）"
        return 1
    fi

    if ! modprobe amneziawg || [[ ! -d /sys/module/amneziawg ]]; then
        warn "amneziawg 内核模块已安装但无法加载"
        cleanup_failed_kernel_install
        summary_add "内核模块 方式 1（PPA + DKMS）" "失败（模块无法加载，已清理）"
        return 1
    fi

    summary_add "内核模块 方式 1（PPA + DKMS）" "成功（amneziawg-dkms，内核升级后自动重编译）"

    echo
    echo "DKMS:"
    dkms status || true

    echo
    echo "Module:"
    modinfo amneziawg || true

    return 0
}

# Linux 7.0 changed setup_udp_tunnel_sock() to take `struct sock *`, while the
# module's compat.h still converts the argument to `struct socket *`.
# Restrict that conversion macro to kernels older than 7.0.
patch_kmod_compat() {
    local build_dir="$1"
    local compat_h="${build_dir}/compat/compat.h"
    local pattern='^[[:space:]]*#[[:space:]]*define[[:space:]]+setup_udp_tunnel_sock\(net, sk, sock_cfg\)[[:space:]]+setup_udp_tunnel_sock\(net, sk->sk_socket, sock_cfg\)'

    [[ -f "${compat_h}" ]] || return 1

    if [[ "$(grep -cE "${pattern}" "${compat_h}" || true)" != "1" ]]; then
        warn "compat.h 中没有找到预期的 setup_udp_tunnel_sock 宏，无法自动打补丁"
        return 1
    fi

    sed -i -E "/${pattern}/{
i\\
#if LINUX_VERSION_CODE < KERNEL_VERSION(7, 0, 0)
a\\
#endif
}" "${compat_h}" || return 1

    grep -q 'KERNEL_VERSION(7, 0, 0)' "${compat_h}" || return 1

    return 0
}

# Method 2: build the module from the official repository
try_kernel_source() {
    log "方式 2：从官方仓库源码编译内核模块"

    init_workdir

    local src="${WORK_DIR}/amneziawg-kmod"
    local build_log="${WORK_DIR}/kmod-build.log"
    local clone_args=(--depth 1)

    if [[ -n "${AWG_KMOD_REF}" ]]; then
        clone_args+=(--branch "${AWG_KMOD_REF}")
    fi

    git clone "${clone_args[@]}" "${AWG_KMOD_REPO}" "${src}" || {
        warn "克隆 amneziawg-linux-kernel-module 失败"
        summary_add "内核模块 方式 2（源码编译）" "失败（克隆仓库失败）"
        return 1
    }

    local build_dir="${src}/src"

    if [[ ! -f "${build_dir}/Makefile" ]]; then
        warn "找不到 ${build_dir}/Makefile，仓库结构可能已变化"
        summary_add "内核模块 方式 2（源码编译）" "失败（仓库结构与预期不符）"
        return 1
    fi

    log "编译内核模块（针对 $(uname -r)）"

    local build_ok=0

    if make -C "${build_dir}" -j"$(nproc)" >"${build_log}" 2>&1; then
        build_ok=1
    elif grep -q 'setup_udp_tunnel_sock' "${build_log}" && \
        patch_kmod_compat "${build_dir}"; then

        warn "检测到 setup_udp_tunnel_sock 接口变化（Linux 7.0），已打兼容补丁，重新编译（未经上游验证）"
        summary_add "内核模块源码补丁" "已对 compat.h 应用 Linux 7.0 兼容补丁（未经上游验证）"

        make -C "${build_dir}" clean >/dev/null 2>&1 || true

        if make -C "${build_dir}" -j"$(nproc)" >"${build_log}" 2>&1; then
            build_ok=1
        fi
    fi

    if [[ "${build_ok}" -ne 1 ]]; then
        summary_add "内核模块 方式 2（源码编译）" "失败（编译错误，内核 $(uname -r) 可能不受支持）"
        warn "源码编译失败（内核 $(uname -r) 可能仍不受支持），日志末尾 30 行："
        echo "------------------------------"
        tail -n 30 "${build_log}" || true
        echo "------------------------------"
        return 1
    fi

    local ko
    ko="$(find "${build_dir}" -maxdepth 2 -name 'amneziawg.ko' -print -quit 2>/dev/null || true)"

    if [[ -z "${ko}" ]]; then
        warn "编译完成但没有找到 amneziawg.ko"
        summary_add "内核模块 方式 2（源码编译）" "失败（没有找到 amneziawg.ko）"
        return 1
    fi

    local dest="/lib/modules/$(uname -r)/updates/amneziawg.ko"

    install -D -m 644 "${ko}" "${dest}" || return 1
    depmod -a || true

    if ! modprobe amneziawg || [[ ! -d /sys/module/amneziawg ]]; then
        warn "源码编译的模块无法加载"
        summary_add "内核模块 方式 2（源码编译）" "失败（模块无法加载）"
        rm -f "${dest}"
        depmod -a || true
        return 1
    fi

    echo
    echo "Module:"
    modinfo amneziawg || true

    summary_add "内核模块 方式 2（源码编译）" "成功（未注册 DKMS，Linux 内核升级后需重新编译）"

    warn "此方式没有注册 DKMS：Linux 内核升级后，需要重新编译该模块"

    return 0
}

###############################################################################
# Backend 3: userspace (amneziawg-go)
###############################################################################

# ensure_go <min-version>
# Uses the system Go if new enough, otherwise downloads the official Go
# toolchain into the temporary work dir (nothing is installed system-wide).
ensure_go() {
    local required="$1"
    local have=""

    if command -v go >/dev/null 2>&1; then
        have="$(go env GOVERSION 2>/dev/null |
            sed -E 's/^go([0-9]+(\.[0-9]+)*).*/\1/' || true)"
    fi

    if [[ -n "${have}" ]] && version_ge "${have}" "${required}"; then
        echo "使用系统 Go：${have}"
        summary_add "Go 工具链" "使用系统已有 Go ${have}（未额外安装）"
        return 0
    fi

    log "系统 Go 版本不足（当前：${have:-未安装}，需要：>= ${required}），下载官方 Go"

    local arch go_ver

    case "$(uname -m)" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)
            warn "不支持的架构：$(uname -m)"
            return 1
            ;;
    esac

    go_ver="$(
        curl -fsSL --max-time 15 'https://go.dev/VERSION?m=text' 2>/dev/null |
            sed -n '1p' || true
    )"

    if [[ ! "${go_ver}" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        go_ver="${GO_FALLBACK_VERSION}"
    fi

    echo "下载 ${go_ver} (${arch})"

    curl -fL --retry 3 --connect-timeout 15 \
        -o "${WORK_DIR}/go.tar.gz" \
        "https://go.dev/dl/${go_ver}.linux-${arch}.tar.gz" || {
        warn "下载 Go 失败"
        return 1
    }

    mkdir -p "${WORK_DIR}/goroot" || return 1

    tar -C "${WORK_DIR}/goroot" -xzf "${WORK_DIR}/go.tar.gz" || {
        warn "解压 Go 失败"
        return 1
    }

    export GOROOT="${WORK_DIR}/goroot/go"
    export PATH="${GOROOT}/bin:${PATH}"

    command -v go >/dev/null 2>&1 || return 1

    echo "使用下载的 Go：$(go version)"
    summary_add "Go 工具链 安装方式" "官方压缩包下载（${go_ver}，仅临时用于编译，安装结束后删除）"
    return 0
}

# Compiling Go (especially with a freshly downloaded toolchain) can need
# well over 1 GB of RAM. On small instances the OOM killer ends the compiler
# ("compile: signal: killed"), so add a temporary swap file when memory is low.
ensure_build_memory() {
    local mem_kb swap_kb avail_kb swap_file="/var/tmp/awg-build.swap"

    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"

    echo "内存：$((mem_kb / 1024)) MB，swap：$((swap_kb / 1024)) MB"

    if (( mem_kb + swap_kb >= 2500 * 1024 )); then
        summary_add "临时 swap" "不需要（内存 $((mem_kb / 1024)) MB + swap $((swap_kb / 1024)) MB 足够）"
        return 0
    fi

    avail_kb="$(df -Pk /var/tmp | awk 'NR==2 {print $4}')"

    if (( avail_kb < 3 * 1024 * 1024 )); then
        warn "磁盘剩余空间不足 3GB，无法创建临时 swap，编译可能因内存不足失败"
        return 0
    fi

    log "内存 + swap 不足 2.5GB，临时创建 2GB swap 用于编译（安装结束后自动删除）"

    rm -f "${swap_file}"

    if { fallocate -l 2G "${swap_file}" 2>/dev/null || \
         dd if=/dev/zero of="${swap_file}" bs=1M count=2048 status=none; } && \
       chmod 600 "${swap_file}" && \
       mkswap "${swap_file}" >/dev/null && \
       swapon "${swap_file}"; then
        TEMP_SWAP="${swap_file}"
        echo "已启用临时 swap：${swap_file}"
        summary_add "临时 swap" "已创建 2GB（仅编译 amneziawg-go 用，安装结束后删除）"
    else
        warn "创建临时 swap 失败，继续尝试编译"
        summary_add "临时 swap" "创建失败（编译可能因内存不足失败）"
        rm -f "${swap_file}"
    fi

    return 0
}

try_userspace_backend() {
    log "尝试方式 B：用户态实现 (amneziawg-go)"

    init_workdir

    if [[ ! -c /dev/net/tun ]]; then
        modprobe tun 2>/dev/null || true
    fi

    if [[ ! -c /dev/net/tun ]]; then
        warn "/dev/net/tun 不存在，用户态实现无法工作"
        summary_add "amneziawg-go" "失败（缺少 /dev/net/tun）"
        return 1
    fi

    local src="${WORK_DIR}/amneziawg-go"
    local clone_args=(--depth 1)

    if [[ -n "${AWG_GO_REF}" ]]; then
        clone_args+=(--branch "${AWG_GO_REF}")
    fi

    git clone "${clone_args[@]}" "${AWG_GO_REPO}" "${src}" || {
        warn "克隆 amneziawg-go 失败"
        return 1
    }

    local need
    need="$(awk '/^go[[:space:]]+[0-9]/ {print $2; exit}' "${src}/go.mod" 2>/dev/null || true)"
    need="${need:-1.20}"

    ensure_go "${need}" || return 1

    export GOTOOLCHAIN="auto"
    export GOCACHE="${WORK_DIR}/gocache"
    export GOPATH="${WORK_DIR}/gopath"

    ensure_build_memory

    log "编译 amneziawg-go（低内存模式）"

    (
        cd "${src}" &&
        GOGC=50 CGO_ENABLED=0 \
            go build -p 1 -gcflags=all=-c=1 -trimpath -o amneziawg-go .
    ) || {
        warn "编译 amneziawg-go 失败"
        summary_add "amneziawg-go" "失败（编译错误，可能是内存不足被系统杀掉）"
        return 1
    }

    install -m 755 "${src}/amneziawg-go" "${AWG_GO_BIN}" || return 1

    local go_rev
    go_rev="$(git -C "${src}" rev-parse --short HEAD 2>/dev/null || true)"

    summary_add "amneziawg-go 安装方式" "源码编译${go_rev:+（commit ${go_rev}）} -> ${AWG_GO_BIN}"

    echo
    echo "amneziawg-go：${AWG_GO_BIN}"
    "${AWG_GO_BIN}" --version || true

    return 0
}

###############################################################################
# Backend selection
###############################################################################

select_backend() {
    case "${AWG_BACKEND}" in
        auto|kernel|userspace) ;;
        *) die "AWG_BACKEND 只能是 auto / kernel / userspace，当前：${AWG_BACKEND}" ;;
    esac

    log "后端选择模式：${AWG_BACKEND}（顺序：PPA 内核模块 -> 源码内核模块 -> amneziawg-go）"

    init_workdir

    summary_add "后端选择模式" "${AWG_BACKEND}"

    if [[ "${AWG_BACKEND}" == "userspace" ]]; then
        summary_add "内核模块 方式 1 / 2" "已跳过（AWG_BACKEND=userspace）"
    fi

    if [[ "${AWG_BACKEND}" != "userspace" ]]; then
        if ensure_kernel_headers; then
            if try_kernel_ppa; then
                BACKEND="kernel"
                BACKEND_DESC="内核模块（方式 1：PPA / amneziawg-dkms）"
            elif try_kernel_source; then
                BACKEND="kernel"
                BACKEND_DESC="内核模块（方式 2：官方仓库源码编译）"
            fi
        else
            warn "没有可用的内核 headers，跳过内核模块方式"
            summary_add "内核模块 方式 1 / 2" "未尝试（缺少内核 headers）"
        fi

        if [[ -z "${BACKEND}" ]]; then
            if [[ "${AWG_BACKEND}" == "kernel" ]]; then
                die "已指定 AWG_BACKEND=kernel，但两种内核模块方式都失败"
            fi

            warn "内核模块方式都不可用，自动切换到 amneziawg-go"
        fi
    fi

    if [[ -z "${BACKEND}" ]]; then
        if try_userspace_backend; then
            BACKEND="userspace"
            BACKEND_DESC="用户态（方式 3：amneziawg-go）"
        else
            die "三种方式都失败，请查看上方日志"
        fi
    fi

    summary_add "AmneziaWG 实现方式" "${BACKEND_DESC}"

    echo
    echo "############################################################"
    echo "#"
    echo "#  AmneziaWG 实现方式：${BACKEND_DESC}"
    echo "#  Linux 内核版本：$(uname -r)"
    echo "#"
    echo "############################################################"
}

###############################################################################
# AmneziaWG userspace tools (awg / awg-quick)
###############################################################################

build_tools_from_source() {
    init_workdir

    local src="${WORK_DIR}/tools"

    log "方式 2：源码编译 amneziawg-tools（${TOOLS_VERSION}）"

    if git clone --depth 1 --branch "${TOOLS_VERSION}" \
        "${TOOLS_REPO}" "${src}" 2>/dev/null; then

        TOOLS_REF_USED="${TOOLS_VERSION}"
    else
        warn "无法克隆标签 ${TOOLS_VERSION}，改用默认分支"
        rm -rf "${src}"

        git clone --depth 1 "${TOOLS_REPO}" "${src}" || return 1

        TOOLS_REF_USED="默认分支"
    fi

    [[ -f "${src}/src/Makefile" ]] || {
        warn "找不到 ${src}/src/Makefile"
        return 1
    }

    log "编译 amneziawg-tools"
    make -C "${src}/src" || return 1

    log "安装 amneziawg-tools"
    make -C "${src}/src" WITH_SYSTEMDUNITS=yes install || return 1

    return 0
}

install_tools_from_ppa() {
    log "方式 1：PPA 安装 amneziawg-tools"

    add-apt-repository -y ppa:amnezia/ppa || return 1

    if ! apt-get update; then
        warn "apt-get update 失败（PPA 可能不支持当前 Ubuntu 版本），移除该 PPA"
        add-apt-repository -y -r ppa:amnezia/ppa >/dev/null 2>&1 || true
        return 1
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y amneziawg-tools || return 1

    return 0
}

install_tools() {
    local tools_method=""

    log "安装 amneziawg-tools（优先 PPA，失败则源码编译）"

    if install_tools_from_ppa; then
        tools_method="PPA（apt）"
    else
        warn "PPA 方式安装 amneziawg-tools 失败，改为源码编译"
        summary_add "amneziawg-tools 方式 1（PPA）" "失败"

        if build_tools_from_source; then
            tools_method="源码编译（${TOOLS_REF_USED}）"
        else
            summary_add "amneziawg-tools 方式 2（源码编译）" "失败"
            die "amneziawg-tools 安装失败（PPA 和源码编译都失败）"
        fi
    fi

    local tools_ver
    tools_ver="$(awg --version 2>/dev/null | sed -n '1p' || true)"

    summary_add "amneziawg-tools 安装方式" "${tools_method}${tools_ver:+，${tools_ver}}"

    command -v awg >/dev/null 2>&1 || \
        die "安装完成后找不到 awg"

    command -v awg-quick >/dev/null 2>&1 || \
        die "安装完成后找不到 awg-quick"

    echo
    echo "amneziawg-tools 安装方式：${tools_method}"

    echo
    echo "awg:"
    command -v awg
    awg --version || true

    echo
    echo "awg-quick:"
    command -v awg-quick
}

###############################################################################
# systemd unit + backend specific service configuration
###############################################################################

ensure_systemd_unit() {
    if systemctl cat "awg-quick@${WG_INTERFACE}.service" >/dev/null 2>&1; then
        summary_add "awg-quick systemd 服务" "由 amneziawg-tools 自带"
        return 0
    fi

    warn "未找到 awg-quick@.service，手动创建"

    local awg_bin awg_quick_bin

    awg_bin="$(command -v awg)"
    awg_quick_bin="$(command -v awg-quick)"

    cat > /etc/systemd/system/awg-quick@.service <<EOF
[Unit]
Description=AmneziaWG via awg-quick(8) for %I
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target
Documentation=man:awg-quick(8)
Documentation=man:awg(8)

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${awg_quick_bin} up %i
ExecStop=${awg_quick_bin} down %i
ExecReload=/bin/bash -c 'exec ${awg_bin} syncconf %i <(exec ${awg_quick_bin} strip %i)'
Environment=WG_ENDPOINT_RESOLUTION_RETRIES=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    systemctl cat "awg-quick@${WG_INTERFACE}.service" >/dev/null 2>&1 || \
        die "无法创建 awg-quick systemd 服务"

    summary_add "awg-quick systemd 服务" "工具包未自带，已手动创建 /etc/systemd/system/awg-quick@.service"
}

configure_backend_service() {
    local dropin_dir="/etc/systemd/system/awg-quick@.service.d"
    local dropin="${dropin_dir}/10-amneziawg-backend.conf"

    if [[ "${BACKEND}" == "userspace" ]]; then
        log "配置 awg-quick 使用 amneziawg-go"

        mkdir -p "${dropin_dir}"

        cat > "${dropin}" <<EOF
[Service]
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=${AWG_GO_BIN}
EOF

        summary_add "服务后端配置" "systemd drop-in 指向 ${AWG_GO_BIN}"
    else
        rm -f "${dropin}"
        rmdir "${dropin_dir}" 2>/dev/null || true

        summary_add "服务后端配置" "使用内核模块（无需额外配置）"
    fi

    systemctl daemon-reload
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

    echo
    echo "实现方式：${BACKEND_DESC}"

    if [[ "${BACKEND}" == "kernel" ]]; then
        [[ -d /sys/module/amneziawg ]] || \
            die "amneziawg 内核模块没有加载"
    else
        pgrep -x amneziawg-go >/dev/null 2>&1 || \
            die "amneziawg-go 进程没有运行"
    fi

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

    select_backend

    install_tools

    ensure_systemd_unit

    configure_backend_service

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
    echo "实现方式："
    echo "${BACKEND_DESC}"
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

    print_install_summary
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