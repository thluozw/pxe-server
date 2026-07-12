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
from werkzeug.utils import secure_filename

# ============================================================================
# 配置
# ============================================================================

BASE_DIR = os.environ.get('BASE_DIR', '/app')
DATA_DIR = os.path.join(BASE_DIR, 'data')
ISO_DIR = os.path.join(DATA_DIR, 'iso')
BOOT_DIR = os.path.join(DATA_DIR, 'boot')
NFS_DIR = os.path.join(DATA_DIR, 'nfs')
CONFIG_DIR = os.path.join(BASE_DIR, 'config')
TEMP_DIR = os.path.join(DATA_DIR, 'temp')

SERVER_IP = os.environ.get('SERVER_IP', '192.168.8.4')
WEBUI_PORT = int(os.environ.get('WEBUI_PORT', '8080'))

ALLOWED_EXTENSIONS = {'iso'}

# 确保目录存在
for d in [DATA_DIR, ISO_DIR, BOOT_DIR, NFS_DIR, CONFIG_DIR, TEMP_DIR]:
    os.makedirs(d, exist_ok=True)

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

def run_cmd(cmd, shell=True):
    """执行命令并返回输出"""
    try:
        result = subprocess.run(cmd, shell=shell, capture_output=True, text=True, timeout=30)
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return 1, "", "Command timed out"
    except Exception as e:
        return 1, "", str(e)

def get_service_status():
    """获取服务状态"""
    services = {
        'dhcp': {'name': 'DHCP Server', 'port': 67, 'proto': 'udp'},
        'tftp': {'name': 'TFTP Server', 'port': 69, 'proto': 'udp'},
        'nfs': {'name': 'NFS Server', 'port': 2049, 'proto': 'tcp'},
        'mountd': {'name': 'Mountd', 'port': 20048, 'proto': 'tcp'},
    }
    
    status = {}
    for key, svc in services.items():
        code, out, _ = run_cmd(f"netstat -tuln 2>/dev/null | grep -q ':{svc[\"port\"]} ' && echo 'running' || echo 'stopped'")
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
                isos.append({
                    'name': f,
                    'size': size,
                    'size_str': format_size(size),
                    'mtime': mtime.strftime('%Y-%m-%d %H:%M:%S'),
                    'has_boot': os.path.exists(os.path.join(BOOT_DIR, f.replace('.iso', '')))
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
    code, out, err = run_cmd(cmd)
    
    if code != 0:
        # 尝试使用 mount
        mount_path = os.path.join(TEMP_DIR, iso_name)
        os.makedirs(mount_path, exist_ok=True)
        
        cmd = f'mount -o loop,ro "{iso_path}" "{mount_path}" 2>/dev/null'
        code, out, err = run_cmd(cmd)
        
        if code == 0:
            # 复制内容
            run_cmd(f'cp -r "{mount_path}"/* "{nfs_path}"/')
            run_cmd(f'umount "{mount_path}"')
    
    # 查找 boot 文件
    boot_files = []
    for root, dirs, files in os.walk(nfs_path):
        for f in files:
            if 'vmlinuz' in f or 'linux' in f or 'bzImage' in f:
                boot_files.append(os.path.join(root, f))
            if 'initrd' in f or 'initramfs' in f:
                boot_files.append(os.path.join(root, f))
    
    # 复制 boot 文件
    for src in boot_files:
        fname = os.path.basename(src)
        dest = os.path.join(boot_path, fname)
        run_cmd(f'cp "{src}" "{dest}"')
    
    return boot_files

# ============================================================================
# 路由
# ============================================================================

@app.route('/')
def index():
    """主页 - 服务状态"""
    status = get_service_status()
    isos = get_iso_list()
    
    # 获取系统信息
    code, uptime, _ = run_cmd('cat /proc/uptime | awk \'{print $1}\'')
    code, load, _ = run_cmd('cat /proc/loadavg')
    
    return render_template('index.html', 
                           status=status,
                           isos=isos,
                           server_ip=SERVER_IP,
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
    # 读取当前配置
    config = {
        'server_ip': SERVER_IP,
        'dhcp_range_start': os.environ.get('DHCP_RANGE_START', '192.168.8.100'),
        'dhcp_range_end': os.environ.get('DHCP_RANGE_END', '192.168.8.200'),
        'subnet_mask': os.environ.get('SUBNET_MASK', '255.255.255.0'),
    }
    
    # 读取 exports
    exports_path = os.path.join(CONFIG_DIR, 'exports')
    if os.path.exists(exports_path):
        with open(exports_path, 'r') as f:
            config['exports'] = f.read()
    
    return render_template('config.html', config=config)

@app.route('/api/status')
def api_status():
    """API: 获取服务状态"""
    return jsonify(get_service_status())

@app.route('/api/isos')
def api_isos():
    """API: 获取 ISO 列表"""
    return jsonify(get_iso_list())

@app.route('/api/logs')
def api_logs():
    """API: 获取日志"""
    lines = int(request.args.get('lines', 100))
    log_files = [
        '/var/log/syslog',
        '/var/log/messages',
        '/tmp/pxe-server.log'
    ]
    
    logs = []
    for log_file in log_files:
        if os.path.exists(log_file):
            code, out, _ = run_cmd(f'tail -{lines} "{log_file}" 2>/dev/null | grep -E "(dhcp|tftp|nfs|pxe)" || true')
            if out:
                logs.append({'file': log_file, 'content': out})
    
    return jsonify(logs)

# ============================================================================
# 启动
# ============================================================================

if __name__ == '__main__':
    print(f"""
╔══════════════════════════════════════════════════════════════╗
║                    PXE Server WebUI                         ║
╠══════════════════════════════════════════════════════════════╣
║  URL:      http://{SERVER_IP}:{WEBUI_PORT}                         
║  Data:     {DATA_DIR}                     
║  ISOs:     {ISO_DIR}                     
║  Booting:  {BOOT_DIR}                     
╚══════════════════════════════════════════════════════════════╝
    """)
    
    app.run(host='0.0.0.0', port=WEBUI_PORT, debug=False)
