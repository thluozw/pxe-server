#!/bin/bash
# ============================================================================
# gen-menu.sh - 布置 PXE 引导器 + 生成引导菜单
# ============================================================================
# 1. 把 /app/pxe-assets 里的引导器静态文件复制到 TFTP 根 (data/boot)
#    - BIOS:  pxelinux.0 + *.c32  (根目录)
#    - UEFI:  efi64/bootx64.efi (syslinux.efi) + efi64/*.c32/.e64
# 2. 扫描 data/boot/<iso_name>/ 子目录，为每个 ISO 生成菜单项
# 3. BIOS 和 UEFI 都用 syslinux 格式的 pxelinux.cfg/default
#    - BIOS  读: <root>/pxelinux.cfg/default
#    - UEFI  读: <root>/efi64/pxelinux.cfg/default
#
# 可在启动时调用，也可在 WebUI 提取 ISO 后调用
# ============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

BASE_DIR=${BASE_DIR:-/app}
BOOT_DIR="${BASE_DIR}/data/boot"
NFS_DIR="${BASE_DIR}/data/nfs"
ASSETS_DIR="${BASE_DIR}/pxe-assets"
SERVER_IP=${SERVER_IP:-192.168.8.4}

mkdir -p "$BOOT_DIR" "$BOOT_DIR/pxelinux.cfg" "$BOOT_DIR/efi64/pxelinux.cfg"

# ----------------------------------------------------------------------------
# 1. 布置引导器静态文件到 TFTP 根
# ----------------------------------------------------------------------------
if [ -d "$ASSETS_DIR" ]; then
    # BIOS: pxelinux.0 + c32 模块 (根目录，排除 efi64 子目录)
    for f in "$ASSETS_DIR"/*.c32 "$ASSETS_DIR"/pxelinux.0; do
        [ -f "$f" ] && cp -f "$f" "$BOOT_DIR/"
    done
    # UEFI: efi64 目录 (bootx64.efi + 模块)
    if [ -d "$ASSETS_DIR/efi64" ]; then
        cp -f "$ASSETS_DIR/efi64"/* "$BOOT_DIR/efi64/" 2>/dev/null || true
    fi
fi

# ----------------------------------------------------------------------------
# 2. 生成 syslinux 菜单 (BIOS 和 UEFI 共用同样内容)
# ----------------------------------------------------------------------------
MENU_BODY=$(mktemp)

count=0
for dir in "$BOOT_DIR"/*/; do
    [ -d "$dir" ] || continue
    iso_name=$(basename "$dir")
    # 跳过引导器自身目录
    case "$iso_name" in
        pxelinux.cfg|grub|EFI|efi64) continue ;;
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
        append="boot=casper netboot=nfs nfsroot=${nfs_root} ip=dhcp ---"
    elif [ -d "${NFS_DIR}/${iso_name}/live" ]; then
        append="boot=live netboot=nfs nfsroot=${nfs_root} ip=dhcp fetch=none ---"
    else
        append="root=/dev/nfs nfsroot=${nfs_root} ip=dhcp rw ---"
    fi

    cat >> "$MENU_BODY" << EOF
LABEL $iso_name
    MENU LABEL $iso_name (NFS)
    KERNEL $kernel_rel
    APPEND $append
    INITRD $initrd_rel

EOF

    count=$((count + 1))
    echo "[OK] 生成引导项: $iso_name (kernel=$(basename "$kernel"), initrd=$(basename "$initrd"))"
done

# 组装完整菜单 (菜单头 + 菜单项)
write_menu() {
    local target="$1"
    cat > "$target" << 'HDR'
# 自动生成的 PXE 引导菜单
UI vesamenu.c32
PROMPT 0
TIMEOUT 300
MENU TITLE PXE Boot Menu (NFS)

HDR
    cat "$MENU_BODY" >> "$target"
}

write_menu "$BOOT_DIR/pxelinux.cfg/default"
write_menu "$BOOT_DIR/efi64/pxelinux.cfg/default"

rm -f "$MENU_BODY"

echo "[INFO] 共生成 $count 个引导项"
echo "[INFO] BIOS 菜单: $BOOT_DIR/pxelinux.cfg/default"
echo "[INFO] UEFI 菜单: $BOOT_DIR/efi64/pxelinux.cfg/default"
