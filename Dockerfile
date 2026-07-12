# ============================================================================
# Fnos PXE Server Docker Image
# ============================================================================
# 基于 Debian Bookworm，为 Fnos (飞牛 NAS) 提供 PXE 网络安装服务
# 
# 架构：
#   - ISC DHCP Server: 提供 IP + PXE boot 选项
#   - TFTP Server: 提供 boot 文件 (kernel + initramfs)
#   - NFS Server: 提供 ISO 内容 (避免下载到客户端 RAM)
#
# 优势：
#   - 客户端只需 ~512MB RAM (vs iVentoy 需要 >3.3GB)
#   - 支持大 ISO (如 Fnos 3.3GB)
# ============================================================================

FROM debian:bookworm-slim

LABEL maintainer="thluozw"
LABEL description="PXE Server for Fnos installation via NFS"

# 避免交互式提示
ENV DEBIAN_FRONTEND=noninteractive

# ============================================================================
# 安装依赖
# ============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    # 网络服务
    isc-dhcp-server \
    tftpd-hpa \
    nfs-kernel-server \
    xinetd \
    \
    # 工具
    curl \
    wget \
    unzip \
    p7zip-full \
    squashfs-tools \
    genisoimage \
    \
    # 清理
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ============================================================================
# 目录结构
# ============================================================================
# /tftpboot      - TFTP 目录，存放 PXE boot 文件
# /nfsroot       - NFS 共享目录，存放 ISO 内容
# /iso           - ISO 文件存放目录
# /scripts       - 启动脚本

RUN mkdir -p /tftpboot /nfsroot /iso /scripts

# ============================================================================
# 配置 DHCP (ISC DHCP Server)
# ============================================================================
# DHCP 配置文件会在启动时由 start.sh 生成

# ============================================================================
# 配置 TFTP
# ============================================================================
# TFTP 使用 xinetd 模式，配置文件在 /etc/xinetd.d/tftp

RUN mkdir -p /var/tftpboot
RUN ln -sf /tftpboot /var/tftpboot

COPY config/xinetd-tftp /etc/xinetd.d/tftp
RUN chmod 644 /etc/xinetd.d/tftp

# ============================================================================
# 配置 NFS
# ============================================================================
COPY config/exports /etc/exports

# ============================================================================
# 复制脚本
# ============================================================================
COPY scripts/*.sh /scripts/
RUN chmod +x /scripts/*.sh

# ============================================================================
# 健康检查
# ============================================================================
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /scripts/healthcheck.sh || exit 1

# ============================================================================
# 端口
# ============================================================================
# DHCP: 67/udp
# TFTP: 69/udp
# NFS: 2049/tcp
# Mountd: 20048/tcp (rpcbind)

# ============================================================================
# 卷挂载点
# ============================================================================
# /iso      - 存放 ISO 文件 (如 fnos_xxx.iso)
# /tftpboot - 可选，覆盖默认 boot 文件
# /nfsroot  - 可选，存放 NFS 共享内容

VOLUME ["/iso", "/tftpboot", "/nfsroot"]

# ============================================================================
# 启动命令
# ============================================================================
ENTRYPOINT ["/scripts/entrypoint.sh"]
CMD []
