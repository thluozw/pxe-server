#!/usr/bin/env python3
# ============================================================================
# PXE Server WebUI - Flask Application
# ============================================================================
# 提供 Web 界面管理 PXE 服务器
# 
# 功能：
#   - 镜像上传和管理
#   - 服务状态监控
#   - DHCP/TFTP/NFS 配置
#   - DHCP 模式切换 (Proxy / Standalone)
#   - 日志查看
# ============================================================================

import os
import sys
import json
import subprocess
import threading
from datetime import datetime
from functools import wraps

from flask import Flask, render_template, request, redirect, url_for, flash, jsonify, send_file

# ============================================================================
# 配置
# ============================================================================

BASE_DIR = os.environ.get('BASE_DIR', '/app')
DATA_DIR = os.path.join(BASE_DIR, 'data')
ISO_DIR = os.path.join(DATA_DIR, 'iso')
BOOT_DIR = os.path.join(BASE_DIR, 'data', 'boot')
NFS_DIR = os.path.join(BASE_DIR, 'data', 'nfs')
CONFIG_DIR = os.path.join(BASE_DIR, 'config')
TEMP_DIR = os.path.join(DATA_DIR, 'temp')
CONF_FILE = os.path.join(CONFIG_DIR, 'server.conf')

SERVER_IP = os.environ.get('SERVER_IP', '192.168.8.4')
WEBUI_PORT = int(os.environ.get('WEBUI_PORT', '8080'))

ALLOWED_EXTENSIONS = {'iso'}

# 确保目录存在
for d in [DATA_DIR, ISO_DIR, BOOT_DIR, NFS_DIR, CONFIG_DIR, TEMP_DIR]:
    os.makedirs(d, exist_ok=True)

# ============================================================================
# 配置管理
# ============================================================================

DEFAULT_CONFIG = {
    'server_ip': SERVER_IP,
    'webui_port': WEBUI_PORT,
    'dhcp_mode': 'proxy',  # 'proxy' 或 'standalone'
    'main_dhcp_ip': '192.168.8.1',  # 路由器 IP (Proxy 模式)
    'dhcp_range_start': '192.168.8.100',
    'dhcp_range_end': '192.168.8.200',
    'subnet_mask': '255.255.255.0',
    'gateway': '192.168.8.1',
    'broadcast': '192.168.8.255',
    'subnet_network': '192.168.8.0',
}

def load_config():
    """加载配置文件"""
    if os.path.exists(CONF_FILE):
        try:
            with open(CONF_FILE, 'r') as f:
                config = json.load(f)
                # 合并默认配置
                for key, value in DEFAULT_CONFIG.items():
                    if key not in config:
                        config[key] = value
                return config
        except:
            pass
    return DEFAULT_CONFIG.copy()

def save_config(config):
    """保存配置文件"""
    with open(CONF_FILE, 'w') as f:
        json.dump(config, f, indent=2)

# ============================================================================
# Flask 应用
# ============================================================================

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', 'pxe-server-secret-key-change-in-production')
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024 * 1024  # 16GB max
app.config['UPLOAD_FOLDER'] = ISO_DIR

# ============================================================================
# 辅助函数
# ============================================================================

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

def run_cmd(cmd, shell=True, timeout=30):
    """执行命令并返回输出"""
    try:
        result = subprocess.run(cmd, shell=shell, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return 1, "", "Command timed out"
    except Exception as e:
        return 1, "", str(e)

def restart_services():
    """重启 PXE 服务"""
    script = '/scripts/restart-services.sh'
    if os.path.exists(script):
        # 在后台运行
        threading.Thread(target=lambda: run_cmd(f'bash {script}', timeout=60), daemon=True).start()
        return True
    return False

def generate_dhcp_config(mode='proxy', **kwargs):
    """生成 DHCP 配置文件"""
    server_ip = kwargs.get('server_ip', SERVER_IP)
    subnet_mask = kwargs.get('subnet_mask', '255.255.255.0')
    subnet_network = kwargs.get('subnet_network', '192.168.8.0')
    broadcast = kwargs.get('broadcast', '192.168.8.255')
    dhcp_start = kwargs.get('dhcp_range_start', '192.168.8.100')
    dhcp_end = kwargs.get('dhcp_range_end', '192.168.8.200')
    gateway = kwargs.get('gateway', '192.168.8.1')
    
    if mode == 'proxy':
        # Proxy 模式：只提供 PXE 选项，不分配 IP
        # 需要与主 DHCP 服务器配合
        config = f"""# DHCP Proxy Configuration
# 只处理 PXE 引导请求，不分配 IP 地址
authoritative;
ddns-update-style none;

# Proxy 模式：监听所有 DHCP 请求
# 但只响应 PXE 客户端
omapi_port 7911;

# 记录日志
log-facility local7;
"""
    else:
        # Standalone 模式：完整的 DHCP 服务器
        config = f"""# DHCP Standalone Configuration
# 提供 IP 地址分配和 PXE 引导
authoritative;
ddns-update-style none;
default-lease-time 600;
max-lease-time 7200;
log-facility local7;

subnet {subnet_network} netmask {subnet_mask} {{
    range {dhcp_start} {dhcp_end};
    option routers {gateway};
    option subnet-mask {subnet_mask};
    option domain-name-servers {gateway};
    option broadcast-address {broadcast};
    
    # PXE Boot
    filename "pxelinux.0";
    next-server {server_ip};
}}
"""
    return config

def get_service_status():
    """获取服务状态"""
    services = {
        'dhcp': {'name': 'DHCP Server', 'port': 67, 'proto': 'UDP'},
        'tftp': {'name': 'TFTP Server', 'port': 69, 'proto': 'UDP'},
        'nfs': {'name': 'NFS Server', 'port': 2049, 'proto': 'TCP'},
        'mountd': {'name': 'Mountd', 'port': 20048, 'proto': 'TCP'},
        'webui': {'name': 'WebUI', 'port': WEBUI_PORT, 'proto': 'TCP'},
    }
    
    status = {}
    for key, svc in services.items():
        if key == 'webui':
            # WebUI 使用 curl 检测
            code, out, err = run_cmd('curl -s http://localhost:' + str(WEBUI_PORT) + ' > /dev/null 2>&1 && echo running || echo stopped')
        else:
            # 使用 /proc/net/* 检测端口
            if svc['proto'] == 'UDP':
                code, out, err = run_cmd('cat /proc/net/udp 2>/dev/null | awk "{print $2}" | cut -d: -f2 | grep -qi ' + format(svc['port'], '04x') + ' && echo running || echo stopped')
            else:
                code, out, err = run_cmd('cat /proc/net/tcp 2>/dev/null | awk "{print $2}" | cut -d: -f2 | grep -qi ' + format(svc['port'], '04x') + ' && echo running || echo stopped')
        status[key] = {
            'name': svc['name'],
            'port': svc['port'],
            'proto': svc['proto'],
            'status': 'running' if 'running' in out else 'stopped'
        }
    
    return status

def get_iso_list():
    """获取 ISO 文件列表"""
    isos = []
    if os.path.exists(ISO_DIR):
        for f in os.listdir(ISO_DIR):
            if f.endswith('.iso'):
                path = os.path.join(ISO_DIR, f)
                size = os.path.getsize(path)
                mtime = datetime.fromtimestamp(os.path.getmtime(path))
                iso_name = f.replace('.iso', '')
                has_boot = os.path.exists(os.path.join(BOOT_DIR, iso_name))
                isos.append({
                    'name': f,
                    'size': size,
                    'size_str': format_size(size),
                    'mtime': mtime.strftime('%Y-%m-%d %H:%M:%S'),
                    'has_boot': has_boot
                })
    return sorted(isos, key=lambda x: x['mtime'], reverse=True)

def format_size(size):
    """格式化文件大小"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} PB"

def extract_iso(filename):
    """提取 ISO boot 文件"""
    iso_path = os.path.join(ISO_DIR, filename)
    iso_name = filename.replace('.iso', '')
    boot_path = os.path.join(BOOT_DIR, iso_name)
    nfs_path = os.path.join(NFS_DIR, iso_name)
    
    os.makedirs(boot_path, exist_ok=True)
    os.makedirs(nfs_path, exist_ok=True)
    
    # 使用 7z 提取
    cmd = f'7z x -y "{iso_path}" -o"{nfs_path}" >/dev/null 2>&1'
    code, out, err = run_cmd(cmd, timeout=300)
    
    if code != 0:
        # 尝试使用 mount
        mount_path = os.path.join(TEMP_DIR, iso_name)
        os.makedirs(mount_path, exist_ok=True)
        
        cmd = f'mount -o loop,ro "{iso_path}" "{mount_path}" 2>/dev/null'
        code, out, err = run_cmd(cmd)
        
        if code == 0:
            run_cmd(f'cp -r "{mount_path}"/* "{nfs_path}"/')
            run_cmd(f'umount "{mount_path}"')
    
    # 查找并复制 boot 文件
    boot_files = []
    for root, dirs, files in os.walk(nfs_path):
        for f in files:
            if any(x in f.lower() for x in ['vmlinuz', 'linux', 'bzimage', 'kernel']):
                src = os.path.join(root, f)
                dest = os.path.join(boot_path, f)
                run_cmd(f'cp "{src}" "{dest}"')
                boot_files.append(f)
            elif any(x in f.lower() for x in ['initrd', 'initramfs', 'inird']):
                src = os.path.join(root, f)
                dest = os.path.join(boot_path, f)
                run_cmd(f'cp "{src}" "{dest}"')
                boot_files.append(f)
    
    return boot_files

# ============================================================================
# 路由
# ============================================================================

@app.route('/')
def index():
    """主页 - 服务状态"""
    print("[DEBUG index] Loading page at", datetime.now())
    
    # 加载配置
    config = load_config()
    print("[DEBUG index] Loaded config:", json.dumps(config))
    
    # 获取服务状态
    status = get_service_status()
    print("[DEBUG index] Got status:", status)
    
    # 获取 ISO 列表
    isos = get_iso_list()
    
    # 获取系统信息
    code, uptime, _ = run_cmd('cat /proc/uptime | awk \'{print $1}\'')
    code, load, _ = run_cmd('cat /proc/loadavg')
    
    return render_template('index.html', 
                           status=status,
                           isos=isos,
                           config=config,
                           server_ip=config.get('server_ip', SERVER_IP),
                           uptime=uptime.strip() if uptime else 'N/A',
                           load=load.strip() if load else 'N/A')

@app.route('/isos')
def isos_page():
    """镜像管理页面"""
    isos = get_iso_list()
    return render_template('isos.html', isos=isos)

@app.route('/upload', methods=['POST'])
def upload_iso():
    """上传 ISO 文件"""
    if 'file' not in request.files:
        flash('没有选择文件', 'error')
        return redirect(url_for('isos_page'))
    
    file = request.files['file']
    if file.filename == '':
        flash('没有选择文件', 'error')
        return redirect(url_for('isos_page'))
    
    if file and allowed_file(file.filename):
        filename = secure_filename(file.filename)
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        file.save(filepath)
        
        flash(f'成功上传: {filename}', 'success')
        
        # 自动提取 boot 文件
        try:
            boot_files = extract_iso(filename)
            if boot_files:
                flash(f'自动提取了 {len(boot_files)} 个 boot 文件', 'info')
            else:
                flash('未能提取 boot 文件，请手动处理', 'warning')
        except Exception as e:
            flash(f'提取 boot 文件失败: {str(e)}', 'warning')
        
        return redirect(url_for('isos_page'))
    
    flash('不支持的文件类型，仅支持 .iso', 'error')
    return redirect(url_for('isos_page'))

@app.route('/delete/<filename>', methods=['POST'])
def delete_iso(filename):
    """删除 ISO 文件"""
    filename = secure_filename(filename)
    filepath = os.path.join(ISO_DIR, filename)
    
    if os.path.exists(filepath):
        os.remove(filepath)
        
        # 同时删除 boot 和 nfs 目录
        iso_name = filename.replace('.iso', '')
        boot_path = os.path.join(BOOT_DIR, iso_name)
        nfs_path = os.path.join(NFS_DIR, iso_name)
        
        if os.path.exists(boot_path):
            run_cmd(f'rm -rf "{boot_path}"')
        if os.path.exists(nfs_path):
            run_cmd(f'rm -rf "{nfs_path}"')
        
        flash(f'已删除: {filename}', 'success')
    else:
        flash('文件不存在', 'error')
    
    return redirect(url_for('isos_page'))

@app.route('/extract/<filename>', methods=['POST'])
def extract_boot(filename):
    """手动提取 boot 文件"""
    filename = secure_filename(filename)
    
    try:
        boot_files = extract_iso(filename)
        flash(f'成功提取 {len(boot_files)} 个 boot 文件', 'success')
    except Exception as e:
        flash(f'提取失败: {str(e)}', 'error')
    
    return redirect(url_for('isos_page'))

@app.route('/config')
def config_page():
    """配置页面"""
    config = load_config()
    return render_template('config.html', config=config)

@app.route('/api/config/mode', methods=['POST'])
def save_mode_config():
    """保存模式配置"""
    config = load_config()
    
    # 更新配置
    config['dhcp_mode'] = request.form.get('mode', 'proxy')
    config['server_ip'] = request.form.get('server_ip', SERVER_IP)
    
    if config['dhcp_mode'] == 'proxy':
        config['main_dhcp_ip'] = request.form.get('main_dhcp_ip', '192.168.8.1')
    else:
        config['dhcp_range_start'] = request.form.get('dhcp_range_start', '192.168.8.100')
        config['dhcp_range_end'] = request.form.get('dhcp_range_end', '192.168.8.200')
        config['subnet_mask'] = request.form.get('subnet_mask', '255.255.255.0')
        config['gateway'] = request.form.get('gateway', '192.168.8.1')
    
    save_config(config)
    
    # 生成新的 DHCP 配置
    dhcp_conf = generate_dhcp_config(
        mode=config['dhcp_mode'],
        **config
    )
    
    # 保存 DHCP 配置
    with open('/etc/dhcp/dhcpd.conf', 'w') as f:
        f.write(dhcp_conf)
    
    # 重新加载 DHCP 服务
    run_cmd('dhcpd -t -cf /etc/dhcp/dhcpd.conf 2>/dev/null', timeout=10)
    code, _, err = run_cmd('killall -HUP dhcpd 2>/dev/null; echo ok', timeout=10)
    
    mode_name = 'Proxy 模式' if config['dhcp_mode'] == 'proxy' else 'Standalone 模式'
    flash(f'已切换到 {mode_name}，配置已保存', 'success')
    
    return redirect(url_for('config_page'))

@app.route('/api/status')
def api_status():
    """API: 获取服务状态"""
    print("[DEBUG api_status] Request received at", datetime.now())
    status = get_service_status()
    print("[DEBUG api_status] Returning:", status)
    return jsonify(status)

@app.route('/api/isos')
def api_isos():
    """API: 获取 ISO 列表"""
    return jsonify(get_iso_list())

@app.route('/api/config')
def api_config():
    """API: 获取配置"""
    print("[DEBUG api_config] Request received at", datetime.now())
    config = load_config()
    print("[DEBUG api_config] Returning:", config)
    return jsonify(config)

@app.route('/api/logs')
def api_logs():
    """API: 获取日志"""
    lines = int(request.args.get('lines', 100))
    logs = []
    
    log_files = [
        '/var/log/syslog',
        '/var/log/messages',
        '/tmp/pxe-server.log'
    ]
    
    for log_file in log_files:
        if os.path.exists(log_file):
            code, out, _ = run_cmd(f'tail -{lines} "{log_file}" 2>/dev/null | grep -E "(dhcp|tftp|nfs|pxe)" || true')
            if out:
                logs.append({'file': log_file, 'content': out})
    
    return jsonify(logs)

@app.route('/api/service/<action>', methods=['POST'])
def service_control(action):
    """API: 服务控制 (start/stop/restart)"""
    try:
        if action == 'start':
            # 后台启动所有 PXE 服务
            run_cmd('nohup bash /app/scripts/start-services.sh > /tmp/service-start.log 2>&1 &', timeout=5)
            return jsonify({'success': True, 'message': '服务启动命令已发送'})
        
        elif action == 'stop':
            # 停止所有 PXE 服务
            run_cmd('killall dhcpd xinetd rpcbind nfsd mountd 2>/dev/null', timeout=10)
            return jsonify({'success': True, 'message': '所有服务已停止'})
        
        elif action == 'restart':
            # 后台重启所有 PXE 服务
            run_cmd('nohup bash /app/scripts/restart-services.sh > /tmp/service-restart.log 2>&1 &', timeout=5)
            return jsonify({'success': True, 'message': '服务重启命令已发送'})
        
        else:
            return jsonify({'success': False, 'message': '未知操作: ' + action})
    
    except Exception as e:
        return jsonify({'success': False, 'message': '操作失败: ' + str(e)})

# ============================================================================
# 启动
# ============================================================================

if __name__ == '__main__':
    print(f"""
╔══════════════════════════════════════════════════════════════╗
║                    PXE Server WebUI                         ║
╠══════════════════════════════════════════════════════════════╣
║  URL:      http://{SERVER_IP}:{WEBUI_PORT}                         
║  Mode:     {load_config().get('dhcp_mode', 'proxy'):12}                           
║  Data:     {DATA_DIR}                     
╚══════════════════════════════════════════════════════════════╝
    """)
    
    app.run(host='0.0.0.0', port=WEBUI_PORT, debug=False)
