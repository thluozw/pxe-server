#!/bin/bash
# ============================================================================
# gen-menu.sh - 布置 PXE 引导器 + 生成引导菜单
# ============================================================================
# 1. 把 /app/pxe-assets 里的引导器静态文件复制到 TFTP 根 (data/boot)
# 2. 扫描 data/boot/<iso_name>/ 子目录，为每个 ISO 生成菜单项
# 3. 生成 BIOS (pxelinux.cfg/default) 和 UEFI (grub/grub.cfg) 两套菜单
#
# 可在启动时调用，也可在 WebUI 提取 ISO 后调用
# ============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

BASE_DIR=${BASE_DIR:-/app}
BOOT_DIR="${BASE_DIR}/data/boot"
NFS_DIR="${BASE_DIR}/data/nfs"
ASSETS_DIR="${BASE_DIR}/pxe-assets"
SERVER_IP=${SERVER_IP:-192.168.8.4}

mkdir -p "$BOOT_DIR" "$BOOT_DIR/pxelinux.cfg" "$BOOT_DIR/grub"

# ----------------------------------------------------------------------------
# 1. 布置引导器静态文件到 TFTP 根
# ----------------------------------------------------------------------------
if [ -d "$ASSETS_DIR" ]; then
    # BIOS: pxelinux.0 + c32 模块
    cp -f "$ASSETS_DIR"/*.c32 "$BOOT_DIR/" 2>/dev/null || true
    cp -f "$ASSETS_DIR/pxelinux.0" "$BOOT_DIR/" 2>/dev/null || true
    # UEFI: bootx64.efi (grub)
    cp -f "$ASSETS_DIR/bootx64.efi" "$BOOT_DIR/" 2>/dev/null || true
fi

# ----------------------------------------------------------------------------
# 2. 扫描 boot 子目录，为每个 ISO 生成 kernel/initrd 引导项
# ----------------------------------------------------------------------------
BIOS_MENU="$BOOT_DIR/pxelinux.cfg/default"
GRUB_MENU="$BOOT_DIR/grub/grub.cfg"

# BIOS 菜单头
cat > "$BIOS_MENU" << EOF
# 自动生成的 PXE 引导菜单 (BIOS/Legacy)
UI vesamenu.c32
PROMPT 0
TIMEOUT 300
MENU TITLE PXE Boot Menu (NFS)

EOF

# UEFI 菜单头
cat > "$GRUB_MENU" << EOF
# 自动生成的 PXE 引导菜单 (UEFI)
set timeout=30
set default=0
menuentry "Boot from local disk" {
    exit 1
}
EOF

count=0
for dir in "$BOOT_DIR"/*/; do
    [ -d "$dir" ] || continue
    iso_name=$(basename "$dir")
    # 跳过引导器自身目录
    case "$iso_name" in
        pxelinux.cfg|grub|EFI) continue ;;
    esac

    # 查找 kernel 和 initrd
    kernel=$(find "$dir" -maxdepth 1 -type f \( -iname 'vmlinuz*' -o -iname 'linux' -o -iname 'bzImage' -o -iname 'kernel' \) 2>/dev/null | head -1)
    initrd=$(find "$dir" -maxdepth 1 -type f \( -iname 'initrd*' -o -iname 'initramfs*' -o -iname 'inird*' \) 2>/dev/null | head -1)

    if [ -z "$kernel" ] || [ -z "$initrd" ]; then
        echo "[WARN] $iso_name: 缺少 kernel 或 initrd，跳过 (kernel=$kernel initrd=$initrd)"
        continue
    fi

    kernel_rel="$iso_name/$(basename "$kernel")"
    initrd_rel="$iso_name/$(basename "$initrd")"
    nfs_root="${SERVER_IP}:${NFS_DIR}/${iso_name}"

    # 探测发行版类型，选择合适的 boot 参数
    if [ -d "${NFS_DIR}/${iso_name}/casper" ]; then
        # Ubuntu / casper
        append="boot=casper netboot=nfs nfsroot=${nfs_root} ip=dhcp ---"
    elif [ -d "${NFS_DIR}/${iso_name}/live" ]; then
        # Debian live
        append="boot=live netboot=nfs nfsroot=${nfs_root} ip=dhcp fetch=none ---"
    else
        # 通用 / Debian-installer 风格
        append="root=/dev/nfs nfsroot=${nfs_root} ip=dhcp rw ---"
    fi

    # BIOS 菜单项
    cat >> "$BIOS_MENU" << EOF
LABEL $iso_name
    MENU LABEL $iso_name (NFS)
    KERNEL $kernel_rel
    APPEND initrd=$initrd_rel $append

EOF

    # UEFI 菜单项
    cat >> "$GRUB_MENU" << EOF
menuentry "$iso_name (NFS)" {
    linux /$kernel_rel $append
    initrd /$initrd_rel
}
EOF

    count=$((count + 1))
    echo "[OK] 生成引导项: $iso_name (kernel=$(basename "$kernel"), initrd=$(basename "$initrd"))"
done

echo "[INFO] 共生成 $count 个引导项"
echo "[INFO] BIOS 菜单: $BIOS_MENU"
echo "[INFO] UEFI 菜单: $GRUB_MENU"
