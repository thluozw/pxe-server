# ============================================================================
# PXE Server Docker Image
# ============================================================================
# 通用 PXE 网络安装服务器，带 WebUI 管理界面
#
# 功能：
#   - WebUI: 镜像上传、服务配置、状态监控
#   - dnsmasq: ProxyDHCP (RFC 4578, 端口 4011) 或 Standalone DHCP + TFTP
#   - NFS Server: 提供 ISO 内容挂载
#
# 优势：
#   - 客户端只需 ~512MB RAM (vs iVentoy 需要 >3GB)
#   - 支持大 ISO (如 Fnos 3.3GB)
#   - WebUI 管理，简单易用
# ============================================================================

FROM debian:bookworm-slim

LABEL maintainer="thluozw"
LABEL description="General PXE Server with WebUI"

# 避免交互式提示
ENV DEBIAN_FRONTEND=noninteractive
ENV BASE_DIR=/app
ENV SERVER_IP=192.168.8.4
ENV WEBUI_PORT=8080

# ============================================================================
# 安装依赖
# ============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Python3 + Flask (WebUI)
    python3 \
    python3-flask \
    python3-werkzeug \
    \
    # 网络服务：dnsmasq 一体化提供 ProxyDHCP/DHCP + TFTP
    dnsmasq \
    nfs-kernel-server \
    iproute2 \
    \
    # PXE 引导器：BIOS (pxelinux/syslinux) + UEFI (grub-efi)
    pxelinux \
    syslinux-common \
    grub-efi-amd64-bin \
    grub-common \
    \
    # ISO 处理
    p7zip-full \
    squashfs-tools \
    genisoimage \
    \
    # 工具
    curl \
    wget \
    unzip \
    \
    # 清理
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ============================================================================
# 目录结构
# ============================================================================
RUN mkdir -p ${BASE_DIR}/{webui/templates,webui/static/css,webui/static/js,data/{iso,boot,nfs,temp},config,scripts}

# ============================================================================
# 复制 WebUI
# ============================================================================
COPY --chown=root:root webui/app.py ${BASE_DIR}/webui/
COPY --chown=root:root webui/templates/ ${BASE_DIR}/webui/templates/
COPY --chown=root:root webui/static/ ${BASE_DIR}/webui/static/

# ============================================================================
# 复制配置文件
# ============================================================================
COPY --chown=root:root config/exports /etc/exports

# ============================================================================
# 复制脚本
# ============================================================================
COPY --chown=root:root scripts/*.sh ${BASE_DIR}/scripts/
RUN chmod +x ${BASE_DIR}/scripts/*.sh

# ============================================================================
# 软链接 TFTP
# ============================================================================
RUN ln -sf ${BASE_DIR}/data/boot /tftpboot && \
    mkdir -p /var/tftpboot

# ============================================================================
# 预置 PXE 引导器静态文件到 /app/pxe-assets（不被 data 卷覆盖）
# 启动时由 start-services.sh 复制到 TFTP 根目录
# ============================================================================
RUN mkdir -p ${BASE_DIR}/pxe-assets/pxelinux.cfg && \
    # BIOS: pxelinux.0 + 必需的 c32 模块
    cp /usr/lib/PXELINUX/pxelinux.0 ${BASE_DIR}/pxe-assets/ && \
    cp /usr/lib/syslinux/modules/bios/ldlinux.c32 ${BASE_DIR}/pxe-assets/ && \
    cp /usr/lib/syslinux/modules/bios/libcom32.c32 ${BASE_DIR}/pxe-assets/ && \
    cp /usr/lib/syslinux/modules/bios/libutil.c32 ${BASE_DIR}/pxe-assets/ && \
    cp /usr/lib/syslinux/modules/bios/vesamenu.c32 ${BASE_DIR}/pxe-assets/ && \
    cp /usr/lib/syslinux/modules/bios/menu.c32 ${BASE_DIR}/pxe-assets/ && \
    # UEFI: 用 grub-mkimage 生成 bootx64.efi（含 netboot 模块）
    grub-mkimage -O x86_64-efi -o ${BASE_DIR}/pxe-assets/bootx64.efi -p /grub \
        tftp efinet net normal linux configfile echo ls cat boot \
        part_gpt part_msdos fat ext2 iso9660 search search_label search_fs_uuid \
        gfxterm all_video test true loadenv reboot halt 2>/dev/null && \
    echo "PXE assets prepared"

# ============================================================================
# 健康检查
# ============================================================================
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:${WEBUI_PORT}/ || exit 1

# ============================================================================
# 入口点
# ============================================================================
WORKDIR ${BASE_DIR}

# 启动顺序：先后台启动网络服务，再前台运行 WebUI
CMD /app/scripts/start-services.sh & \
    python3 /app/webui/app.py

# 暴露端口
EXPOSE 8080 67/udp 69/udp 4011/udp 2049/tcp 20048/tcp

# 卷
VOLUME ["${BASE_DIR}/data"]
