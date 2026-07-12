# ============================================================================
# PXE Server Docker Image
# ============================================================================
# 通用 PXE 网络安装服务器，带 WebUI 管理界面
#
# 功能：
#   - WebUI: 镜像上传、服务配置、状态监控
#   - ISC DHCP Server: 提供 IP + PXE boot 选项
#   - TFTP Server: 提供 boot 文件
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
    # 网络服务
    isc-dhcp-server \
    tftpd-hpa \
    nfs-kernel-server \
    xinetd \
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
COPY --chown=root:root config/xinetd-tftp /etc/xinetd.d/tftp
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
# 健康检查
# ============================================================================
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:${WEBUI_PORT}/ || exit 1

# ============================================================================
# 入口点
# ============================================================================
WORKDIR ${BASE_DIR}

# 启动顺序：先启动 WebUI，后台启动网络服务
CMD python3 webui/app.py & \
    /scripts/start-services.sh & \
    tail -f /dev/null

# 暴露端口
EXPOSE 8080 67/udp 69/udp 2049/tcp 20048/tcp

# 卷
VOLUME ["${BASE_DIR}/data"]
