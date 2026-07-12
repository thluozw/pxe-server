# Fnos PXE Server Docker

在 Armbian 上运行的 PXE 网络安装服务器，专门为 Fnos (飞牛 NAS) 设计。

## 🎯 解决的问题

iVentoy 的问题：需要把整个 ISO 下载到客户端内存 (tmpfs)

```
iVentoy: 客户端 RAM ≥ ISO 大小 (如 Fnos 3.3GB)
PXE+NFS: 客户端 RAM 只需 ~512MB
```

## 📐 架构

```
┌─────────────────────────────────────────────────────────┐
│              Fnos PXE Server (Docker)                   │
├─────────────────────────────────────────────────────────┤
│  ISC DHCP Server  │  TFTP Server  │  NFS Server        │
│  UDP:67           │  UDP:69       │  TCP:2049          │
└─────────────────────────────────────────────────────────┘
                           ↓ PXE
┌─────────────────────────────────────────────────────────┐
│                   客户端 (VM/物理机)                     │
├─────────────────────────────────────────────────────────┤
│  1. DHCP 获取 IP                                       │
│  2. TFTP 下载 boot 文件 (~15MB)                        │
│  3. NFS 挂载 ISO 内容                                  │
│  4. 启动 Fnos 安装程序                                 │
└─────────────────────────────────────────────────────────┘
```

## 📁 目录结构

```
fnos-pxe-server/
├── Dockerfile           # Docker 镜像定义
├── docker-compose.yml   # Docker Compose 配置
├── README.md            # 本文档
├── config/
│   ├── xinetd-tftp     # TFTP 服务器配置
│   └── exports         # NFS 导出配置
├── data/
│   ├── iso/            # 放入 ISO 文件
│   ├── boot/           # 自定义 boot 文件
│   └── nfs/            # NFS 共享内容
└── scripts/
    ├── entrypoint.sh   # 容器启动脚本
    ├── extract-iso.sh  # ISO 提取脚本
    └── healthcheck.sh  # 健康检查脚本
```

## 🚀 快速开始

### 1. 构建镜像

```bash
# 在 Armbian 主机上
cd /DATA/AppData/fnos-pxe-server
docker build -t fnos-pxe-server:latest .
```

### 2. 放入 ISO 文件

```bash
# 复制 Fnos ISO 到 data/iso 目录
cp /path/to/fnos_xxx.iso ./data/iso/
```

### 3. 修改配置

编辑 `docker-compose.yml`，修改服务器 IP：

```yaml
environment:
  SERVER_IP: "192.168.8.4"    # 修改为你的 Armbian IP
```

### 4. 启动服务

```bash
# 启动
docker-compose up -d

# 查看日志
docker-compose logs -f
```

### 5. PXE 启动客户端

1. 在 VMware 中启动虚拟机
2. 按 `Esc` 进入启动菜单
3. 选择 `Network Boot (PXE)`
4. 等待自动获取 IP 并启动

## ⚙️ 配置说明

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SERVER_IP` | 192.168.8.4 | 服务器 IP |
| `SUBNET_MASK` | 255.255.255.0 | 子网掩码 |
| `SUBNET_NETWORK` | 192.168.8.0 | 子网网络 |
| `SUBNET_BROADCAST` | 192.168.8.255 | 广播地址 |
| `DHCP_RANGE_START` | 192.168.8.100 | DHCP 起始 IP |
| `DHCP_RANGE_END` | 192.168.8.200 | DHCP 结束 IP |
| `BOOT_FILE` | (自动) | PXE 启动文件名 |

### 端口需求

| 端口 | 协议 | 服务 | 必须 |
|------|------|------|------|
| 67 | UDP | DHCP | ✅ |
| 69 | UDP | TFTP | ✅ |
| 2049 | TCP | NFS | ✅ |
| 20048 | TCP | mountd | ✅ |

## 🔧 高级配置

### 使用现有 iVentoy + NFS

如果你已经有 iVentoy 容器，可以复用其 NFS 功能：

```bash
# 让 NFS 从 iVentoy 的 ISO 目录导出
docker run -d \
  --name fnos-nfs \
  --network host \
  --privileged \
  -v /DATA/AppData/iventoy/iso:/nfsroot:ro \
  -e SERVER_IP=192.168.8.4 \
  fnos-pxe-server:latest
```

### 自定义 boot 文件

如果自动提取失败，可以手动放置 boot 文件：

```bash
# 放入自定义 boot 文件
cp vmlinuz ./data/boot/fnos/linux
cp initrd.img ./data/boot/fnos/initrd
```

## 🐛 故障排除

### 客户端无法获取 IP

```bash
# 检查 DHCP 日志
docker-compose logs | grep dhcp

# 检查端口 67 是否监听
netstat -ulnp | grep :67
```

### TFTP 超时

```bash
# 检查 TFTP 服务
docker exec fnos-pxe-server xinetd-lookup tftp

# 检查防火墙
ufw allow 69/udp
```

### NFS 挂载失败

```bash
# 检查 NFS 导出
showmount -e localhost

# 检查 mountd 端口
netstat -tlnp | grep 20048
```

### ISO 提取失败

```bash
# 手动提取 ISO
docker exec fnos-pxe-server /scripts/extract-iso.sh

# 查看详细日志
docker-compose logs --tail=100
```

## 📝 与 iVentoy 的对比

| 特性 | iVentoy | PXE+NFS |
|------|---------|---------|
| 客户端 RAM | ≥ ISO 大小 | ~512MB |
| 服务复杂度 | 简单 | 较复杂 |
| 支持 Windows | ✅ | ❌ (需 WinPE) |
| 支持 Linux | ✅ | ✅ |
| 多系统选择 | ✅ | ⚠️ (需配置) |
| 维护更新 | 活跃 | 需手动 |

## 🧹 清理

```bash
# 停止并删除容器
docker-compose down

# 删除镜像
docker rmi fnos-pxe-server:latest

# 清理数据
rm -rf ./data/boot/*
rm -rf ./data/nfs/*
```

## 📄 License

MIT License
