#!/bin/bash
# ============================================================================
# Restart PXE Services
# ============================================================================
# 根据配置重新启动 DHCP/TFTP/NFS 服务

set -e

# 确保 PATH 包含必要的二进制目录
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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

# 停止 dnsmasq
killall dnsmasq 2>/dev/null || true

# 停止 NFS
/usr/sbin/rpc.nfsd 0 2>/dev/null || true
/usr/sbin/rpc.mountd --no-notify 2>/dev/null || true

sleep 2

# ============================================================================
# 生成 dnsmasq 配置
# ============================================================================
log_info "生成 dnsmasq 配置..."

BASE_DIR=${BASE_DIR:-/app}
DNSMASQ_CONF="/etc/dnsmasq.d/pxe.conf"
mkdir -p /etc/dnsmasq.d

cat > "$DNSMASQ_CONF" << EOF
# dnsmasq PXE 配置 (自动生成)
port=0
no-resolv
no-hosts
log-dhcp
enable-tftp
tftp-root=${BASE_DIR}/data/boot
tftp-no-blocksize
EOF

if [ "$DHCP_MODE" = "proxy" ]; then
    cat >> "$DNSMASQ_CONF" << EOF
# ProxyDHCP 模式 (RFC 4578)：不分配 IP，不占用 67
dhcp-range=${SUBNET_NETWORK},proxy
pxe-service=x86PC,"PXE Boot (BIOS)",pxelinux.0
pxe-service=BC_EFI,"PXE Boot (UEFI x86)",bootx64.efi
pxe-service=X86-64_EFI,"PXE Boot (UEFI x64)",bootx64.efi
dhcp-boot=pxelinux.0,,${SERVER_IP}
EOF
    log_info "ProxyDHCP 模式：无需配置路由器 66/67"
else
    cat >> "$DNSMASQ_CONF" << EOF
# Standalone 模式：分配 IP + PXE 引导
dhcp-authoritative
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${SUBNET_MASK},12h
dhcp-option=option:router,${GATEWAY}
dhcp-option=option:dns-server,${GATEWAY}
dhcp-boot=pxelinux.0,,${SERVER_IP}
pxe-service=x86PC,"PXE Boot (BIOS)",pxelinux.0
pxe-service=BC_EFI,"PXE Boot (UEFI x86)",bootx64.efi
pxe-service=X86-64_EFI,"PXE Boot (UEFI x64)",bootx64.efi
EOF
    log_info "Standalone 模式：IP 范围 ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
fi

# ============================================================================
# 启动服务
# ============================================================================
log_info "启动服务..."

# rpcbind
/usr/sbin/rpcbind || true
sleep 1

# exportfs
/usr/sbin/exportfs -ra || true

# rpc.nfsd
/usr/sbin/rpc.nfsd 8 || true

# rpc.mountd
/usr/sbin/rpc.mountd || true

sleep 1

# dnsmasq (ProxyDHCP/DHCP + TFTP)
/usr/sbin/dnsmasq --test --conf-file="$DNSMASQ_CONF" 2>&1 || log_warn "dnsmasq 配置测试失败"
/usr/sbin/dnsmasq --conf-file="$DNSMASQ_CONF" 2>&1 | tee /tmp/dnsmasq-startup.log || log_warn "dnsmasq 启动完成(可能有警告)"

echo ""
echo "=============================================="
log_success "服务已重启!"
echo "=============================================="
echo ""
log_info "当前模式: $DHCP_MODE"
log_info "服务器 IP: $SERVER_IP"
echo ""
