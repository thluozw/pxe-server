#!/bin/bash
# ============================================================================
# Health Check Script
# ============================================================================
# 检查所有 PXE 服务是否正常运行

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# 检查进程
check_process() {
    local name="$1"
    local cmd="$2"
    if pgrep -f "$cmd" > /dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC} $name 运行中"
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $name 未运行"
        return 1
    fi
}

# 检查端口
check_port() {
    local port="$1"
    local proto="$2"
    if netstat -tuln 2>/dev/null | grep -q ":$port "; then
        echo -e "${GREEN}[OK]${NC} 端口 $port ($proto) 监听中"
        return 0
    else
        echo -e "${RED}[FAIL]${NC} 端口 $port ($proto) 未监听"
        return 1
    fi
}

echo "=== PXE 服务健康检查 ==="
echo ""

# 检查进程
check_process "rpcbind" "rpcbind"
check_process "NFS nfsd" "rpc.nfsd"
check_process "NFS mountd" "rpc.mountd"
check_process "TFTP xinetd" "xinetd"
check_process "DHCP dhcpd" "dhcpd"

echo ""

# 检查端口
check_port 67 udp  # DHCP
check_port 69 udp  # TFTP
check_port 2049 tcp # NFS
check_port 20048 tcp # mountd

echo ""

# 检查 TFTP 目录
if [ -d "/tftpboot" ] && [ "$(ls -A /tftpboot 2>/dev/null)" ]; then
    echo -e "${GREEN}[OK]${NC} TFTP 目录有内容"
else
    echo -e "${RED}[FAIL]${NC} TFTP 目录为空"
fi

# 检查 NFS 目录
if [ -d "/nfsroot" ]; then
    echo -e "${GREEN}[OK]${NC} NFS 目录存在"
else
    echo -e "${RED}[FAIL]${NC} NFS 目录不存在"
fi

echo ""
echo "=== 检查完成 ==="
