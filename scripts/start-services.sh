#!/bin/bash
# ============================================================================
# Start PXE Services
# ============================================================================

set -e

# 配置
SERVER_IP=${SERVER_IP:-192.168.8.4}
SUBNET_MASK=${SUBNET_MASK:-255.255.255.0}
SUBNET_NETWORK=${SUBNET_NETWORK:-192.168.8.0}
SUBNET_BROADCAST=${SUBNET_BROADCAST:-192.168.8.255}
DHCP_RANGE_START=${DHCP_RANGE_START:-192.168.8.100}
DHCP_RANGE_END=${DHCP_RANGE_END:-192.168.8.200}
BASE_DIR=${BASE_DIR:-/app}

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "=============================================="
echo "  PXE Services Startup"
echo "=============================================="
echo ""

# ============================================================================
# 1. 配置 DHCP
# ============================================================================
log_info "配置 DHCP Server..."

DHCP_CONF="/etc/dhcp/dhcpd.conf"
cat > "$DHCP_CONF" << EOF
authoritative;
ddns-update-style none;
default-lease-time 600;
max-lease-time 7200;
log-facility local7;

subnet ${SUBNET_NETWORK} netmask ${SUBNET_MASK} {
    range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
    option routers ${SERVER_IP};
    option subnet-mask ${SUBNET_MASK};
    option domain-name-servers ${SERVER_IP};
    option broadcast-address ${SUBNET_BROADCAST};
    
    # PXE Boot
    filename "pxelinux.0";
    next-server ${SERVER_IP};
}
EOF

log_success "DHCP 配置完成"

# ============================================================================
# 2. 配置 NFS
# ============================================================================
log_info "配置 NFS..."

cat > /etc/exports << EOF
${BASE_DIR}/data/nfs    *(ro,sync,no_subtree_check,no_root_squash,async,insecure)
EOF

log_success "NFS 配置完成"

# ============================================================================
# 3. 创建目录
# ============================================================================
log_info "创建目录..."

mkdir -p ${BASE_DIR}/data/iso
mkdir -p ${BASE_DIR}/data/boot
mkdir -p ${BASE_DIR}/data/nfs
mkdir -p ${BASE_DIR}/data/temp

# ============================================================================
# 4. 启动服务
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
dhcpd -cf /etc/dhcp/dhcpd.conf || log_warn "DHCP 启动可能有错误"

echo ""
echo "=============================================="
log_success "所有服务已启动!"
echo "=============================================="
echo ""
log_info "服务状态:"
echo ""
echo "  WebUI:       http://${SERVER_IP}:${WEBUI_PORT:-8080}"
echo "  DHCP:        UDP:67"
echo "  TFTP:        UDP:69"
echo "  NFS:         TCP:2049"
echo "  Mountd:      TCP:20048"
echo ""
log_info "日志目录:"
echo "  ISOs:        ${BASE_DIR}/data/iso"
echo "  Boot files:  ${BASE_DIR}/data/boot"
echo "  NFS root:    ${BASE_DIR}/data/nfs"
echo ""
echo "客户端可以开始 PXE 启动了!"
echo ""

# ============================================================================
# 保持运行
# ============================================================================
# 等待信号
wait
