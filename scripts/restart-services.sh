#!/bin/bash
# ============================================================================
# Restart PXE Services
# ============================================================================
# 根据配置重新启动 DHCP/TFTP/NFS 服务

set -e

CONFIG_FILE="/app/config/server.conf"
SERVER_IP=${SERVER_IP:-192.168.8.4}

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo ""
echo "=============================================="
echo "  Restarting PXE Services"
echo "=============================================="
echo ""

# ============================================================================
# 读取配置
# ============================================================================
if [ -f "$CONFIG_FILE" ]; then
    log_info "读取配置文件..."
    
    # 从 JSON 提取值 (使用 grep/sed)
    DHCP_MODE=$(grep -o '"dhcp_mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | sed 's/.*:.*"\([^"]*\)"/\1/')
    DHCP_RANGE_START=$(grep -o '"dhcp_range_start"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | sed 's/.*:.*"\([^"]*\)"/\1/')
    DHCP_RANGE_END=$(grep -o '"dhcp_range_end"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | sed 's/.*:.*"\([^"]*\)"/\1/')
    SUBNET_MASK=$(grep -o '"subnet_mask"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | sed 's/.*:.*"\([^"]*\)"/\1/')
    SUBNET_NETWORK=$(grep -o '"subnet_network"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | sed 's/.*:.*"\([^"]*\)"/\1/')
    GATEWAY=$(grep -o '"gateway"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | sed 's/.*:.*"\([^"]*\)"/\1/')
    BROADCAST=$(grep -o '"broadcast"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" | sed 's/.*:.*"\([^"]*\)"/\1/')
    
    # 设置默认值
    DHCP_MODE=${DHCP_MODE:-proxy}
    DHCP_RANGE_START=${DHCP_RANGE_START:-192.168.8.100}
    DHCP_RANGE_END=${DHCP_RANGE_END:-192.168.8.200}
    SUBNET_MASK=${SUBNET_MASK:-255.255.255.0}
    SUBNET_NETWORK=${SUBNET_NETWORK:-192.168.8.0}
    GATEWAY=${GATEWAY:-192.168.8.1}
    BROADCAST=${BROADCAST:-192.168.8.255}
else
    log_warn "配置文件不存在，使用默认配置"
    DHCP_MODE="proxy"
    DHCP_RANGE_START="192.168.8.100"
    DHCP_RANGE_END="192.168.8.200"
    SUBNET_MASK="255.255.255.0"
    SUBNET_NETWORK="192.168.8.0"
    GATEWAY="192.168.8.1"
    BROADCAST="192.168.8.255"
fi

log_info "DHCP 模式: $DHCP_MODE"

# ============================================================================
# 停止现有服务
# ============================================================================
log_info "停止现有服务..."

# 停止 DHCP
pkill -HUP dhcpd 2>/dev/null || true
pkill dhcpd 2>/dev/null || true

# 停止 NFS
rpc.nfsd 0 2>/dev/null || true
rpc.mountd --no-notify 2>/dev/null || true

# 停止 xinetd (TFTP)
pkill xinetd 2>/dev/null || true

sleep 2

# ============================================================================
# 生成 DHCP 配置
# ============================================================================
log_info "生成 DHCP 配置..."

DHCP_CONF="/etc/dhcp/dhcpd.conf"

if [ "$DHCP_MODE" = "proxy" ]; then
    # Proxy 模式：只响应 PXE 请求
    cat > "$DHCP_CONF" << EOF
# DHCP Proxy Configuration
# 只处理 PXE 引导请求
authoritative;
ddns-update-style none;
log-facility local7;

# Proxy 模式配置
# 注意：这个配置需要与主 DHCP 服务器配合使用
# 主 DHCP 服务器分配 IP，本服务器添加 PXE 选项
EOF
    log_info "Proxy 模式：需要主 DHCP 服务器配合"
else
    # Standalone 模式：完整的 DHCP 服务器
    cat > "$DHCP_CONF" << EOF
# DHCP Standalone Configuration
# 提供完整的 DHCP 服务
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
    option broadcast-address ${BROADCAST};
    
    # PXE Boot
    filename "pxelinux.0";
    next-server ${SERVER_IP};
}
EOF
    log_info "Standalone 模式：IP 范围 ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
fi

# ============================================================================
# 启动服务
# ============================================================================
log_info "启动服务..."

# rpcbind
rpcbind || true
sleep 1

# exportfs
exportfs -ra

# rpc.nfsd
rpc.nfsd 8

# rpc.mountd
rpc.mountd

# xinetd (TFTP)
xinetd -dontfork &

sleep 2

# DHCP
touch /var/lib/dhcp/dhcpd.leases
chmod 644 /var/lib/dhcp/dhcpd.leases 2>/dev/null || true
dhcpd -cf /etc/dhcp/dhcpd.conf 2>&1 | tee /tmp/dhcp-startup.log || log_warn "DHCP 启动完成(可能有警告)"

echo ""
echo "=============================================="
log_success "服务已重启!"
echo "=============================================="
echo ""
log_info "当前模式: $DHCP_MODE"
log_info "服务器 IP: $SERVER_IP"
echo ""
