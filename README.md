# PXE Server

通用 PXE 网络安装服务器，支持上传 ISO镜像、WebUI 管理、低内存需求。

## 🎯 特性

- **🌐 WebUI 管理页面** - 上传镜像、配置 DHCP/TFTP/NFS、监控状态
- **💾 低内存需求** - 客户端只需 ~512MB RAM（使用 NFS 挂载）
- **📦 多镜像支持** - 支持 Linux ISO、Windows PE 等
- **🐳 Docker 部署** - 一键启动，简单方便
- **📊 实时监控** - 查看服务状态、日志

## 📐 架构

```
┌─────────────────────────────────────────────────────────┐
│              PXE Server (Docker)                        │
├─────────────────────────────────────────────────────────┤
│  WebUI (Flask)  │  DHCP  │  TFTP  │  NFS              │
│  TCP:8080       │  UDP:67 │  UDP:69 │  TCP:2049       │
└─────────────────────────────────────────────────────────┘
                           ↓ PXE
┌─────────────────────────────────────────────────────────┐
│                 客户端 (VM/物理机)                       │
├─────────────────────────────────────────────────────────┤
│  1. DHCP 获取 IP                                       │
│  2. TFTP 下载 boot 文件                               │
│  3. NFS 挂载 ISO 内容                                 │
│  4. 启动安装程序                                      │
└─────────────────────────────────────────────────────────┘
```

## 🚀 快速开始

### 1. 启动服务

```bash
cd F:\Programs\pxe-server
docker-compose up -d
```

### 2. 访问 WebUI

```
http://192.168.8.4:8080
```

### 3. 上传镜像

在 WebUI 中上传 ISO 文件，系统会自动提取 boot 文件。

### 4. PXE 启动客户端

1. 启动虚拟机，按 `Esc` 进入启动菜单
2. 选择 `Network Boot (PXE)`
3. 等待自动获取 IP 并启动

## 📁 目录结构

```
pxe-server/
├── Dockerfile           # Docker 镜像
├── docker-compose.yml   # Docker Compose 配置
├── webui/              # WebUI 源码
│   ├── app.py         # Flask 应用
│   ├── templates/     # HTML 模板
│   └── static/        # CSS/JS
├── config/            # 服务配置
├── scripts/           # 启动脚本
└── data/             # 数据目录
    ├── iso/          # ISO 文件
    ├── boot/         # PXE boot 文件
    └── nfs/          # NFS 共享内容
```

## 🖥️ WebUI 功能

| 功能 | 说明 |
|------|------|
| 镜像管理 | 上传、删除、查看 ISO |
| 服务控制 | 启动/停止 DHCP/TFTP/NFS |
| 配置管理 | 修改 IP、DHCP 范围等 |
| 状态监控 | 查看服务状态、客户端连接 |
| 日志查看 | 查看服务日志 |

## ⚙️ 配置说明

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SERVER_IP` | 192.168.8.4 | 服务器 IP |
| `WEBUI_PORT` | 8080 | WebUI 端口 |
| `DHCP_RANGE_START` | 192.168.8.100 | DHCP 起始 IP |
| `DHCP_RANGE_END` | 192.168.8.200 | DHCP 结束 IP |

### 端口

| 端口 | 协议 | 服务 |
|------|------|------|
| 8080 | TCP | WebUI |
| 67 | UDP | DHCP |
| 69 | UDP | TFTP |
| 2049 | TCP | NFS |

## 🐛 故障排除

### 客户端无法获取 IP
```bash
docker logs pxe-server | grep dhcp
```

### TFTP 超时
```bash
docker exec pxe-server tftp localhost get test.txt
```

### NFS 挂载失败
```bash
showmount -e 192.168.8.4
```

## 📄 License

MIT
