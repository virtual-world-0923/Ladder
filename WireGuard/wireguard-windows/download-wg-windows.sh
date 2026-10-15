#!/usr/bin/env bash
# ============================================================
# 在 Ubuntu 上下载 Windows 版 WireGuard 完整客户端文件
# 场景：Windows 本机无外网，只能由 Ubuntu 下载后传回
# 用法：bash download-wg-windows.sh
# 产物：~/wireguard-windows/ 目录，整体拷回 Windows 即可
# ============================================================
set -e

OUT_DIR="$HOME/wireguard-windows"
mkdir -p "$OUT_DIR"

echo "==> 安装下载工具（wget/curl）..."
sudo apt-get update -y >/dev/null 2>&1 || true
sudo apt-get install -y wget curl >/dev/null 2>&1 || true

# ---------- 1) 官方独立安装包（.exe 引导安装器） ----------
# 说明：这是官方完整客户端 exe，双击即可在 Windows 上安装，非源码、非绿色版
echo "==> 下载官方 WireGuard 完整客户端 (Windows, .exe)..."
wget -q --show-progress \
    -O "$OUT_DIR/wireguard-installer.exe" \
    https://download.wireguard.com/windows-client/wireguard-installer.exe

# ---------- 2) 备用：Standalone MSI（官方，可离线静默安装） ----------
echo "==> 下载备用 Standalone MSI (amd64, 离线安装包)..."
wget -q --show-progress \
    -O "$OUT_DIR/wireguard-amd64-latest.msi" \
    https://download.wireguard.com/windows-client/wireguard-amd64-latest.msi || true

# ---------- 3) 校验（可选，打印大小 + SHA256） ----------
echo ""
echo "==> 下载完成，文件清单："
ls -lh "$OUT_DIR"
cd "$OUT_DIR"
echo ""
echo "SHA256 校验值（传回 Windows 后可对比，确保传输未损坏）："
sha256sum *.exe *.msi 2>/dev/null || true

cat > "$OUT_DIR/使用说明.txt" <<'EOF'
============================================================
WireGuard Windows 客户端 —— 使用说明（Ubuntu 下载，传回 Windows）
============================================================

【本目录文件】
1. wireguard-installer.exe       官方 .exe 完整客户端（双击安装，推荐）
2. wireguard-amd64-latest.msi    备用 MSI 离线安装包（可静默安装）
3. client1.conf                  客户端配置（服务端脚本生成，若已存在）
4. 使用说明.txt                  本文件

【在 Windows 上安装】
方式一（推荐）：双击 wireguard-installer.exe，按提示下一步即可。
方式二（静默/批量）：管理员身份打开 CMD，执行
    msiexec /i wireguard-amd64-latest.msi /qn DO_NOT_LAUNCH=1

【导入配置】
打开 WireGuard → Add Tunnel → Import tunnel(s) from file → 选 client1.conf
若没有 client1.conf，见下方"手动填写"或从服务端扫码生成。

【手动填写配置示例】
------------------------------------------------------------
[Interface]
Address = 10.8.0.2/24
PrivateKey = <客户端私钥>
DNS = 1.1.1.1

[Peer]
PublicKey = <服务端公钥>
Endpoint = <服务端公网IP>:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
------------------------------------------------------------

【验证】
状态变为 Active、有收发字节；浏览器访问 ifconfig.me 显示服务端公网 IP 即成功。

【注意事项】
- 官方没有"单文件免安装绿色版 exe"，installer.exe / MSI 均需安装一次。
- 安装后真正运行的程序在 C:\Program Files\WireGuard\wireguard.exe
- 若 Windows 无外网，首次安装务必用本目录离线包，之后无需再联网。
============================================================
EOF

echo ""
echo "============================================================"
echo " 全部完成！请把整个目录传回 Windows："
echo "   $OUT_DIR"
echo ""
echo " 推荐方式（Windows PowerShell，需 OpenSSH）："
echo "   scp ubuntu@<EC2公网IP>:wireguard-windows/*  C:\\Users\\你\\Desktop\\wg\\"
echo ""
echo " 或先在 Ubuntu 打包："
echo "   cd ~ && zip -r wireguard-windows.zip wireguard-windows/"
echo "   scp ubuntu@<EC2公网IP>:wireguard-windows.zip  C:\\Users\\你\\Desktop\\"
echo "============================================================"
