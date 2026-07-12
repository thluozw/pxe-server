#!/bin/bash
# ============================================================================
# Start PXE Services
# ============================================================================
# 支持 DHCP Proxy 和 Standalone 两种模式

set -e

# 确保 PATH 包含必要的二进制目录
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

CONFIG_FILE="/app/config/server.conf"
BASE_DIR=${BASE_DIR:-/app}

# 默认配置
SERVER_IP=${SERVER_IP:-192.168.8.4}
WEBUI_PORT=${WEBUI_PORT:-8080}
DHCP_MODE=${DHCP_MODE:-proxy}
DHCP_RANGE_START=${DHCP_RANGE_START:-192.168.8.100}
DHCP_RANGE_END=${DHCP_RANGE_END:-192.168.8.200}
SUBNET_MASK=${SUBNET_MASK:-255.255.255.0}
SUBNET_NETWORK=${SUBNET_NETWORK:-192.168.8.0}
SUBNET_BROADCAST=${SUBNET_BROADCAST:-192.168.8.255}
GATEWAY=${GATEWAY:-192.168.8.1}

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ============================================================================
# 读取配置
# ============================================================================
if [ -f "$CONFIG_FILE" ]; then
    log_info "读取配置文件: $CONFIG_FILE"
    
    # 从 JSON 提取值
    _val=$(grep -o '"dhcp_mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*:.*"\([^"]*\)"/\1/')
    [ -n "$_val" ] && DHCP_MODE="$_val"
    
    _val=$(grep -o '"server_ip"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*:.*"\([^"]*\)"/\1/')
    [ -n "$_val" ] && SERVER_IP="$_val"
    
    _val=$(grep -o '"dhcp_range_start"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*:.*"\([^"]*\)"/\1/')
    [ -n "$_val" ] && DHCP_RANGE_START="$_val"
    
    _val=$(grep -o '"dhcp_range_end"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*:.*"\([^"]*\)"/\1/')
    [ -n "$_val" ] && DHCP_RANGE_END="$_val"
    
    _val=$(grep -o '"subnet_mask"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*:.*"\([^"]*\)"/\1/')
    [ -n "$_val" ] && SUBNET_MASK="$_val"
    
    _val=$(grep -o '"subnet_network"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*:.*"\([^"]*\)"/\1/')
    [ -n "$_val" ] && SUBNET_NETWORK="$_val"
    
    _val=$(grep -o '"broadcast"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*:.*"\([^"]*\)"/\1/')
    [ -n "$_val" ] && SUBNET_BROADCAST="$_val"
    
    _val=$(grep -o '"gateway"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*:.*"\([^"]*\)"/\1/')
    [ -n "$_val" ] && GATEWAY="$_val"
fi

echo ""
echo "=============================================="
echo "  PXE Services Startup"
echo "=============================================="
echo ""
log_info "服务器 IP: $SERVER_IP"
log_info "WebUI 端口: $WEBUI_PORT"
log_info "DHCP 模式: $DHCP_MODE"

# ============================================================================
# 创建目录
# ============================================================================
log_info "创建目录..."
mkdir -p ${BASE_DIR}/data/iso
mkdir -p ${BASE_DIR}/data/boot
mkdir -p ${BASE_DIR}/data/nfs
mkdir -p ${BASE_DIR}/data/temp
mkdir -p ${BASE_DIR}/config

# ============================================================================
# 配置 dnsmasq (ProxyDHCP / Standalone DHCP + TFTP)
# ============================================================================
log_info "配置 dnsmasq..."

DNSMASQ_CONF="/etc/dnsmasq.d/pxe.conf"
mkdir -p /etc/dnsmasq.d

# 公共部分：关闭 DNS（port=0），只做 DHCP/TFTP；启用内置 TFTP
cat > "$DNSMASQ_CONF" << EOF
# ============================================================
# dnsmasq PXE 配置 (自动生成，勿手动编辑)
# ============================================================

# 关闭 DNS 服务，只作为 DHCP/TFTP 服务器
port=0

# 不读取 /etc/resolv.conf 和 /etc/hosts
no-resolv
no-hosts

# 日志
log-dhcp

# 内置 TFTP 服务
enable-tftp
tftp-root=${BASE_DIR}/data/boot
tftp-no-blocksize

EOF

if [ "$DHCP_MODE" = "proxy" ]; then
    # ------------------------------------------------------------------
    # ProxyDHCP 模式 (RFC 4578) - 真正的 iVentoy 式 Proxy
    #   - 监听 UDP 4011，不占用 67，不分配 IP
    #   - 主 DHCP（路由器）给 IP，本服务器只补充 PXE 引导信息
    #   - 无需在路由器配置 Option 66/67
    # ------------------------------------------------------------------
    cat >> "$DNSMASQ_CONF" << EOF
# ProxyDHCP 模式：只提供 PXE 引导，不分配 IP
dhcp-range=${SUBNET_NETWORK},proxy

# PXE 引导服务（BIOS / Legacy x86）
pxe-service=x86PC,"PXE Boot (BIOS)",pxelinux.0
pxe-service=BC_EFI,"PXE Boot (UEFI x86)",bootx64.efi
pxe-service=X86-64_EFI,"PXE Boot (UEFI x64)",bootx64.efi

# TFTP 服务器地址
dhcp-boot=pxelinux.0,,${SERVER_IP}
EOF
    log_success "ProxyDHCP 模式已配置 (RFC 4578, 端口 4011)"
    log_info "  - 无需在路由器配置 Option 66/67"
    log_info "  - 主 DHCP 服务器分配 IP，本服务器提供 PXE 引导"

else
    # ------------------------------------------------------------------
    # Standalone 模式：本服务器作为唯一 DHCP，分配 IP + PXE 引导
    # ------------------------------------------------------------------
    cat >> "$DNSMASQ_CONF" << EOF
# Standalone 模式：分配 IP + PXE 引导
dhcp-authoritative
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${SUBNET_MASK},12h
dhcp-option=option:router,${GATEWAY}
dhcp-option=option:dns-server,${GATEWAY}

# PXE 引导
dhcp-boot=pxelinux.0,,${SERVER_IP}
pxe-service=x86PC,"PXE Boot (BIOS)",pxelinux.0
pxe-service=BC_EFI,"PXE Boot (UEFI x86)",bootx64.efi
pxe-service=X86-64_EFI,"PXE Boot (UEFI x64)",bootx64.efi
EOF
    log_success "Standalone 模式已配置"
    log_info "  - IP 范围: ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
    log_info "  - 网关: ${GATEWAY}"
fi

# ============================================================================
# 配置 NFS
# ============================================================================
log_info "配置 NFS..."

cat > /etc/exports << EOF
${BASE_DIR}/data/nfs    *(ro,sync,no_subtree_check,no_root_squash,async,insecure)
EOF

# ============================================================================
# 启动服务
# ============================================================================
log_info "启动服务..."

# rpcbind
log_info "启动 rpcbind..."
/usr/sbin/rpcbind || true
sleep 1

# exportfs
log_info "启动 NFS (exportfs)..."
/usr/sbin/exportfs -ra || true

# rpc.nfsd
log_info "启动 rpc.nfsd..."
/usr/sbin/rpc.nfsd 8 || true

# rpc.mountd
log_info "启动 rpc.mountd..."
/usr/sbin/rpc.mountd || true

sleep 1

# dnsmasq (ProxyDHCP/DHCP + TFTP)
log_info "启动 dnsmasq (DHCP + TFTP)..."

# 清理可能残留的进程
killall dnsmasq 2>/dev/null || true
sleep 1

# 测试配置
/usr/sbin/dnsmasq --test --conf-file="$DNSMASQ_CONF" 2>&1 || log_warn "dnsmasq 配置测试失败"

# 启动（直接指定我们的配置文件，避免依赖默认 conf-dir）
/usr/sbin/dnsmasq --conf-file="$DNSMASQ_CONF" 2>&1 || log_warn "dnsmasq 启动失败，请检查日志"

sleep 1

echo ""
echo "=============================================="
log_success "所有服务已启动!"
echo "=============================================="
echo ""
log_info "服务状态:"
echo ""
echo "  WebUI:       http://${SERVER_IP}:${WEBUI_PORT}"
if [ "$DHCP_MODE" = "proxy" ]; then
    echo "  ProxyDHCP:   UDP:4011 (不占用 67)"
else
    echo "  DHCP:        UDP:67"
fi
echo "  TFTP:        UDP:69"
echo "  NFS:         TCP:2049"
echo ""
log_info "模式说明:"
if [ "$DHCP_MODE" = "proxy" ]; then
    echo "  ProxyDHCP 模式 - 主 DHCP 分配 IP，本服务器提供 PXE（无需配置路由器 66/67）"
else
    echo "  Standalone 模式 - 本服务器同时分配 IP 和提供 PXE"
fi
echo ""
log_info "日志目录:"
echo "  ISOs:        ${BASE_DIR}/data/iso"
echo "  Boot files:  ${BASE_DIR}/data/boot"
echo "  NFS root:    ${BASE_DIR}/data/nfs"
echo ""
log_info "客户端可以开始 PXE 启动了!"
echo ""

# ============================================================================
# 服务已在后台启动，脚本退出（容器由 app.py 保持运行）
# ============================================================================
