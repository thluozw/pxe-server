#!/bin/bash
# ============================================================================
# Start PXE Services
# ============================================================================
# 支持 DHCP Proxy 和 Standalone 两种模式

set -e

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
# 配置 DHCP
# ============================================================================
log_info "配置 DHCP Server..."

DHCP_CONF="/etc/dhcp/dhcpd.conf"

if [ "$DHCP_MODE" = "proxy" ]; then
    # Proxy 模式：只处理 PXE 请求
    cat > "$DHCP_CONF" << EOF
# DHCP Proxy Configuration
# ========================
# 此模式只处理 PXE 引导请求
# IP 地址由主 DHCP 服务器（如路由器）分配
#
# 使用说明：
# 1. 确保路由器/主 DHCP 服务器正常运行
# 2. 在路由器上配置 DHCP 选项指向本服务器
# 3. 或者使用 Standalone 模式

authoritative;
ddns-update-style none;
log-facility local7;

# 注意：Proxy 模式下，客户端从主 DHCP 获取 IP
# 本服务器通过 DHCP 响应注入 PXE 选项
EOF
    log_warn "Proxy 模式：需要主 DHCP 服务器配合"
    log_info "  - 主 DHCP 服务器分配 IP 地址"
    log_info "  - 本服务器提供 PXE 引导选项"
    
else
    # Standalone 模式：完整的 DHCP 服务器
    cat > "$DHCP_CONF" << EOF
# DHCP Standalone Configuration
# ==============================
# 本服务器作为唯一的 DHCP 服务器
# 分配 IP 地址并提供 PXE 引导

authoritative;
ddns-update-style none;
default-lease-time 600;
max-lease-time 7200;
log-facility local7;

subnet ${SUBNET_NETWORK} netmask ${SUBNET_MASK} {
    range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
    option routers ${GATEWAY};
    option subnet-mask ${SUBNET_MASK};
    option domain-name-servers ${GATEWAY};
    option broadcast-address ${SUBNET_BROADCAST};
    
    # PXE Boot
    filename "pxelinux.0";
    next-server ${SERVER_IP};
}
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
rpcbind || true
sleep 1

# exportfs
log_info "启动 NFS (exportfs)..."
exportfs -ra

# rpc.nfsd
log_info "启动 rpc.nfsd..."
rpc.nfsd 8

# rpc.mountd
log_info "启动 rpc.mountd..."
rpc.mountd

# xinetd (TFTP)
log_info "启动 TFTP (xinetd)..."
xinetd -dontfork &

sleep 2

# DHCP
log_info "启动 DHCP Server..."
touch /var/lib/dhcp/dhcpd.leases
chmod 644 /var/lib/dhcp/dhcpd.leases 2>/dev/null || true

if [ "$DHCP_MODE" = "proxy" ]; then
    log_warn "Proxy 模式：DHCP 服务器只处理 PXE 请求"
    # Proxy 模式下，DHCP 配置可能不完整，跳过错误检查
    dhcpd -cf /etc/dhcp/dhcpd.conf 2>&1 | head -5 || true
else
    dhcpd -cf /etc/dhcp/dhcpd.conf || log_warn "DHCP 启动可能有错误，请检查配置"
fi

echo ""
echo "=============================================="
log_success "所有服务已启动!"
echo "=============================================="
echo ""
log_info "服务状态:"
echo ""
echo "  WebUI:       http://${SERVER_IP}:${WEBUI_PORT}"
echo "  DHCP:        UDP:67 (${DHCP_MODE})"
echo "  TFTP:        UDP:69"
echo "  NFS:         TCP:2049"
echo "  Mountd:      TCP:20048"
echo ""
log_info "模式说明:"
if [ "$DHCP_MODE" = "proxy" ]; then
    echo "  🔄 Proxy 模式 - 主 DHCP 服务器分配 IP，本服务器提供 PXE"
else
    echo "  🖥️ Standalone 模式 - 本服务器同时分配 IP 和提供 PXE"
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
# 保持运行
# ============================================================================
wait
