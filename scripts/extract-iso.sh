#!/bin/bash
# ============================================================================
# Extract ISO Boot Files for PXE
# ============================================================================
# Extracts kernel and initramfs from ISO for PXE boot
# Extracts ISO content for NFS mount
#
# Supported ISOs:
#   - Fnos (飞牛 NAS)
#   - Ubuntu
#   - Debian
#   - Generic ISO with bootable partition
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

ISO_DIR="/iso"
TFTPBOOT="/tftpboot"
NFSROOT="/nfsroot"
WORKDIR="/tmp/iso_extract"

# ============================================================================
# 提取函数
# ============================================================================
extract_iso() {
    local iso_file="$1"
    local iso_name=$(basename "$iso_file" .iso)
    
    log_info "处理 ISO: $iso_name"
    
    # 创建临时工作目录
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"
    
    # 挂载 ISO (只读)
    log_info "挂载 ISO..."
    mkdir -p mnt
    if mount -o loop,ro "$iso_file" mnt 2>/dev/null; then
        log_success "ISO 挂载成功"
    else
        log_warn "挂载失败，尝试使用 7z 提取..."
        7z x -y "$iso_file" -o"mnt" >/dev/null 2>&1 || true
    fi
    
    # 列出 ISO 内容
    log_info "ISO 内容结构:"
    ls -la mnt/ 2>/dev/null | head -20
    
    echo ""
    
    # =========================================================================
    # 检测 ISO 类型并提取
    # =========================================================================
    
    # ---- 检测 Fnos ----
    if ls mnt/boot/vmlinuz* mnt/boot/initrd* mnt/boot/inird* 2>/dev/null | grep -qE "(vmlinuz|initrd)" || \
       ls mnt/casper/vmlinuz* mnt/casper/initrd* 2>/dev/null | grep -qE "(vmlinuz|initrd)" || \
       ls mnt/isolinux/vmlinuz* mnt/isolinux/initrd* 2>/dev/null | grep -qE "(vmlinuz|initrd)"; then
        log_info "检测到 Linux ISO，准备提取..."
        
        # 创建 ISO 专用目录
        mkdir -p "$TFTPBOOT/$iso_name"
        mkdir -p "$NFSROOT/$iso_name"
        
        # ---- 提取 boot 文件到 TFTP ----
        log_info "提取 boot 文件..."
        
        # 尝试不同的位置
        KERNEL=""
        INITRD=""
        
        # Ubuntu/Debian 风格
        if [ -f "mnt/casper/vmlinuz" ]; then
            KERNEL="mnt/casper/vmlinuz"
            INITRD=$(ls mnt/casper/initrd* 2>/dev/null | head -1)
        # CentOS/RHEL 风格
        elif [ -f "mnt/isolinux/vmlinuz" ]; then
            KERNEL="mnt/isolinux/vmlinuz"
            INITRD=$(ls mnt/isolinux/initrd* 2>/dev/null | head -1)
        # Fedora 风格
        elif [ -f "mnt/images/pxeboot/vmlinuz" ]; then
            KERNEL="mnt/images/pxeboot/vmlinuz"
            INITRD=$(ls mnt/images/pxeboot/initrd* 2>/dev/null | head -1)
        # 通用搜索
        else
            KERNEL=$(find mnt -name "vmlinuz*" -type f 2>/dev/null | head -1)
            INITRD=$(find mnt -name "initrd*" -type f 2>/dev/null | head -1)
        fi
        
        if [ -n "$KERNEL" ] && [ -f "$KERNEL" ]; then
            cp "$KERNEL" "$TFTPBOOT/$iso_name/linux"
            log_success "提取内核: linux ($(du -h "$TFTPBOOT/$iso_name/linux" | cut -f1))"
            
            # 设置环境变量供主脚本使用
            export KERNEL_FILE="$iso_name/linux"
        fi
        
        if [ -n "$INITRD" ] && [ -f "$INITRD" ]; then
            cp "$INITRD" "$TFTPBOOT/$iso_name/initrd"
            log_success "提取 initrd: initrd ($(du -h "$TFTPBOOT/$iso_name/initrd" | cut -f1))"
        fi
        
        # ---- 复制整个 ISO 内容到 NFS ----
        log_info "复制 ISO 内容到 NFS 目录..."
        cp -r mnt/* "$NFSROOT/$iso_name/" 2>/dev/null || true
        log_success "NFS 内容已准备好: /nfsroot/$iso_name"
        
        # ---- 创建 pxelinux 配置 ----
        log_info "创建 PXE 启动菜单..."
        mkdir -p "$TFTPBOOT/pxelinux.cfg"
        
        cat > "$TFTPBOOT/pxelinux.cfg/default" << EOF
DEFAULT $iso_name

LABEL $iso_name
    KERNEL $iso_name/linux
    APPEND root=/dev/ram0 ramdisk_size=1500000 ip=dhcp boot=casper netboot=nfs nfsroot=${SERVER_IP:-192.168.8.4}:/nfsroot/$iso_name quiet splash ---
INITRD $iso_name/initrd
EOF
        
        # 同时为 UEFI 创建配置
        mkdir -p "$TFTPBOOT/EFI/BOOT"
        cat > "$TFTPBOOT/EFI/BOOT/grub.cfg" << EOF
set timeout=5
set default=0

menuentry "$iso_name" {
    linuxefi /$iso_name/linux root=/dev/ram0 ramdisk_size=1500000 ip=dhcp boot=casper netboot=nfs nfsroot=${SERVER_IP:-192.168.8.4}:/nfsroot/$iso_name quiet splash
    initrdefi /$iso_name/initrd
}
EOF
        
        log_success "PXE 配置文件已创建"
        
    # ---- 检测 Windows ISO ----
    elif ls mnt/sources/install.wim 2>/dev/null || ls mnt/*.wim 2>/dev/null; then
        log_warn "检测到 Windows ISO"
        log_warn "Windows PE 启动需要特殊处理，请使用 iVentoy 或 WinPE"
        
    else
        log_error "无法识别 ISO 类型"
        log_info "请手动提取 boot 文件"
    fi
    
    # 清理
    cd /
    umount mnt 2>/dev/null || true
    rm -rf "$WORKDIR"
    
    echo ""
}

# ============================================================================
# 主逻辑
# ============================================================================
log_info "=============================================="
log_info "ISO 提取工具"
log_info "=============================================="
echo ""

# 检查 ISO 目录
if [ ! -d "$ISO_DIR" ]; then
    mkdir -p "$ISO_DIR"
    log_warn "ISO 目录已创建: $ISO_DIR"
    log_warn "请将 ISO 文件放入 $ISO_DIR"
    exit 0
fi

# 查找 ISO 文件
ISO_FILES=$(find "$ISO_DIR" -maxdepth 1 -name "*.iso" -type f 2>/dev/null)

if [ -z "$ISO_FILES" ]; then
    log_warn "未找到 ISO 文件"
    log_info "请将 ISO 文件放入 $ISO_DIR"
    exit 0
fi

# 处理每个 ISO 文件
for iso in $ISO_FILES; do
    echo ""
    extract_iso "$iso"
done

echo ""
log_success "ISO 提取完成!"
echo ""
