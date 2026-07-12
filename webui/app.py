#!/usr/bin/env python3
# ============================================================================
# PXE Server WebUI - Flask Application
# ============================================================================
# æä¾› Web ç•Œé¢ç®¡ç† PXE æœåŠ¡å™?
# 
# åŠŸèƒ½ï¼?
#   - é•œåƒä¸Šä¼ å’Œç®¡ç?
#   - æœåŠ¡çŠ¶æ€ç›‘æŽ?
#   - DHCP/TFTP/NFS é…ç½®
#   - DHCP æ¨¡å¼åˆ‡æ¢ (Proxy / Standalone)
#   - æ—¥å¿—æŸ¥çœ‹
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
# é…ç½®
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

# ç¡®ä¿ç›®å½•å­˜åœ¨
for d in [DATA_DIR, ISO_DIR, BOOT_DIR, NFS_DIR, CONFIG_DIR, TEMP_DIR]:
    os.makedirs(d, exist_ok=True)

# ============================================================================
# é…ç½®ç®¡ç†
# ============================================================================

DEFAULT_CONFIG = {
    'server_ip': SERVER_IP,
    'webui_port': WEBUI_PORT,
    'dhcp_mode': 'proxy',  # 'proxy' æˆ?'standalone'
    'main_dhcp_ip': '192.168.8.1',  # è·¯ç”±å™?IP (Proxy æ¨¡å¼)
    'dhcp_range_start': '192.168.8.100',
    'dhcp_range_end': '192.168.8.200',
    'subnet_mask': '255.255.255.0',
    'gateway': '192.168.8.1',
    'broadcast': '192.168.8.255',
    'subnet_network': '192.168.8.0',
}

def load_config():
    """åŠ è½½é…ç½®æ–‡ä»¶"""
    if os.path.exists(CONF_FILE):
        try:
            with open(CONF_FILE, 'r') as f:
                config = json.load(f)
                # åˆå¹¶é»˜è®¤é…ç½®
                for key, value in DEFAULT_CONFIG.items():
                    if key not in config:
                        config[key] = value
                return config
        except:
            pass
    return DEFAULT_CONFIG.copy()

def save_config(config):
    """ä¿å­˜é…ç½®æ–‡ä»¶"""
    with open(CONF_FILE, 'w') as f:
        json.dump(config, f, indent=2)

# ============================================================================
# Flask åº”ç”¨
# ============================================================================

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', 'pxe-server-secret-key-change-in-production')
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024 * 1024  # 16GB max
app.config['UPLOAD_FOLDER'] = ISO_DIR

# ============================================================================
# è¾…åŠ©å‡½æ•°
# ============================================================================

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

def run_cmd(cmd, shell=True, timeout=30):
    """æ‰§è¡Œå‘½ä»¤å¹¶è¿”å›žè¾“å‡?""
    try:
        result = subprocess.run(cmd, shell=shell, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return 1, "", "Command timed out"
    except Exception as e:
        return 1, "", str(e)

def restart_services():
    """é‡å¯ PXE æœåŠ¡"""
    script = '/scripts/restart-services.sh'
    if os.path.exists(script):
        # åœ¨åŽå°è¿è¡?
        threading.Thread(target=lambda: run_cmd(f'bash {script}', timeout=60), daemon=True).start()
        return True
    return False

def generate_dhcp_config(mode='proxy', **kwargs):
    """ç”Ÿæˆ DHCP é…ç½®æ–‡ä»¶"""
    server_ip = kwargs.get('server_ip', SERVER_IP)
    subnet_mask = kwargs.get('subnet_mask', '255.255.255.0')
    subnet_network = kwargs.get('subnet_network', '192.168.8.0')
    broadcast = kwargs.get('broadcast', '192.168.8.255')
    dhcp_start = kwargs.get('dhcp_range_start', '192.168.8.100')
    dhcp_end = kwargs.get('dhcp_range_end', '192.168.8.200')
    gateway = kwargs.get('gateway', '192.168.8.1')
    
    if mode == 'proxy':
        # Proxy æ¨¡å¼ï¼šåªæä¾› PXE é€‰é¡¹ï¼Œä¸åˆ†é… IP
        # éœ€è¦ä¸Žä¸?DHCP æœåŠ¡å™¨é…å?
        config = f"""# DHCP Proxy Configuration
# åªå¤„ç?PXE å¼•å¯¼è¯·æ±‚ï¼Œä¸åˆ†é… IP åœ°å€
authoritative;
ddns-update-style none;

# Proxy æ¨¡å¼ï¼šç›‘å¬æ‰€æœ?DHCP è¯·æ±‚
# ä½†åªå“åº” PXE å®¢æˆ·ç«?
omapi_port 7911;

# è®°å½•æ—¥å¿—
log-facility local7;
"""
    else:
        # Standalone æ¨¡å¼ï¼šå®Œæ•´çš„ DHCP æœåŠ¡å™?
        config = f"""# DHCP Standalone Configuration
# æä¾› IP åœ°å€åˆ†é…å’?PXE å¼•å¯¼
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
    """èŽ·å–æœåŠ¡çŠ¶æ€?- ä½¿ç”¨ Python ç›´æŽ¥è¯»å– /proc/net"""
    def check_port_py(port, proto='udp'):
        """ç›´æŽ¥ç”?Python è¯»å– /proc/net æ£€æµ‹ç«¯å?""
        path = f'/proc/net/{proto}'
        try:
            with open(path) as f:
                lines = f.readlines()
            port_hex = format(port, '04X').upper()
            for line in lines[1:]:  # skip header
                parts = line.split()
                if len(parts) > 1:
                    local_addr = parts[1]
                    if ':' in local_addr:
                        addr_port = local_addr.split(':')[-1].strip().upper()
                        if addr_port == port_hex:
                            return True
            return False
        except:
            return False
    
    services = {
        'dhcp': {'name': 'DHCP Server', 'port': 67, 'proto': 'udp'},
        'tftp': {'name': 'TFTP Server', 'port': 69, 'proto': 'udp'},
        'nfs': {'name': 'NFS Server', 'port': 2049, 'proto': 'tcp'},
        'mountd': {'name': 'Mountd', 'port': 20048, 'proto': 'tcp'},
        'webui': {'name': 'WebUI', 'port': WEBUI_PORT, 'proto': 'tcp'},
    }
    
    status = {}
    for key, svc in services.items():
        if key == 'webui':
            # WebUI ä½¿ç”¨æœ¬åœ° HTTP æ£€æµ?
            try:
                import urllib.request
                urllib.request.urlopen(f'http://localhost:{svc["port"]}/', timeout=2)
                svc_status = 'running'
            except:
                svc_status = 'stopped'
        else:
            svc_status = 'running' if check_port_py(svc['port'], svc['proto']) else 'stopped'
        
        status[key] = {
            'name': svc['name'],
            'port': svc['port'],
            'proto': svc['proto'].upper(),
            'status': svc_status
        }
    
    return status

def get_iso_list():
    """èŽ·å– ISO æ–‡ä»¶åˆ—è¡¨"""
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
    """æ ¼å¼åŒ–æ–‡ä»¶å¤§å°?""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} PB"

def extract_iso(filename):
    """æå– ISO boot æ–‡ä»¶"""
    iso_path = os.path.join(ISO_DIR, filename)
    iso_name = filename.replace('.iso', '')
    boot_path = os.path.join(BOOT_DIR, iso_name)
    nfs_path = os.path.join(NFS_DIR, iso_name)
    
    os.makedirs(boot_path, exist_ok=True)
    os.makedirs(nfs_path, exist_ok=True)
    
    # ä½¿ç”¨ 7z æå–
    cmd = f'7z x -y "{iso_path}" -o"{nfs_path}" >/dev/null 2>&1'
    code, out, err = run_cmd(cmd, timeout=300)
    
    if code != 0:
        # å°è¯•ä½¿ç”¨ mount
        mount_path = os.path.join(TEMP_DIR, iso_name)
        os.makedirs(mount_path, exist_ok=True)
        
        cmd = f'mount -o loop,ro "{iso_path}" "{mount_path}" 2>/dev/null'
        code, out, err = run_cmd(cmd)
        
        if code == 0:
            run_cmd(f'cp -r "{mount_path}"/* "{nfs_path}"/')
            run_cmd(f'umount "{mount_path}"')
    
    # æŸ¥æ‰¾å¹¶å¤åˆ?boot æ–‡ä»¶
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
# è·¯ç”±
# ============================================================================

@app.route('/')
def index():
    """ä¸»é¡µ - æœåŠ¡çŠ¶æ€?""
    
    # åŠ è½½é…ç½®
    config = load_config()
    
    # èŽ·å–æœåŠ¡çŠ¶æ€?
    status = get_service_status()
    
    # èŽ·å– ISO åˆ—è¡¨
    isos = get_iso_list()
    
    # èŽ·å–ç³»ç»Ÿä¿¡æ¯
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
    """é•œåƒç®¡ç†é¡µé¢"""
    isos = get_iso_list()
    return render_template('isos.html', isos=isos)

@app.route('/upload', methods=['POST'])
def upload_iso():
    """ä¸Šä¼  ISO æ–‡ä»¶"""
    if 'file' not in request.files:
        flash('æ²¡æœ‰é€‰æ‹©æ–‡ä»¶', 'error')
        return redirect(url_for('isos_page'))
    
    file = request.files['file']
    if file.filename == '':
        flash('æ²¡æœ‰é€‰æ‹©æ–‡ä»¶', 'error')
        return redirect(url_for('isos_page'))
    
    if file and allowed_file(file.filename):
        filename = secure_filename(file.filename)
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        file.save(filepath)
        
        flash(f'æˆåŠŸä¸Šä¼ : {filename}', 'success')
        
        # è‡ªåŠ¨æå– boot æ–‡ä»¶
        try:
            boot_files = extract_iso(filename)
            if boot_files:
                flash(f'è‡ªåŠ¨æå–äº?{len(boot_files)} ä¸?boot æ–‡ä»¶', 'info')
            else:
                flash('æœªèƒ½æå– boot æ–‡ä»¶ï¼Œè¯·æ‰‹åŠ¨å¤„ç†', 'warning')
        except Exception as e:
            flash(f'æå– boot æ–‡ä»¶å¤±è´¥: {str(e)}', 'warning')
        
        return redirect(url_for('isos_page'))
    
    flash('ä¸æ”¯æŒçš„æ–‡ä»¶ç±»åž‹ï¼Œä»…æ”¯æŒ .iso', 'error')
    return redirect(url_for('isos_page'))

@app.route('/delete/<filename>', methods=['POST'])
def delete_iso(filename):
    """åˆ é™¤ ISO æ–‡ä»¶"""
    filename = secure_filename(filename)
    filepath = os.path.join(ISO_DIR, filename)
    
    if os.path.exists(filepath):
        os.remove(filepath)
        
        # åŒæ—¶åˆ é™¤ boot å’?nfs ç›®å½•
        iso_name = filename.replace('.iso', '')
        boot_path = os.path.join(BOOT_DIR, iso_name)
        nfs_path = os.path.join(NFS_DIR, iso_name)
        
        if os.path.exists(boot_path):
            run_cmd(f'rm -rf "{boot_path}"')
        if os.path.exists(nfs_path):
            run_cmd(f'rm -rf "{nfs_path}"')
        
        flash(f'å·²åˆ é™? {filename}', 'success')
    else:
        flash('æ–‡ä»¶ä¸å­˜åœ?, 'error')
    
    return redirect(url_for('isos_page'))

@app.route('/extract/<filename>', methods=['POST'])
def extract_boot(filename):
    """æ‰‹åŠ¨æå– boot æ–‡ä»¶"""
    filename = secure_filename(filename)
    
    try:
        boot_files = extract_iso(filename)
        flash(f'æˆåŠŸæå– {len(boot_files)} ä¸?boot æ–‡ä»¶', 'success')
    except Exception as e:
        flash(f'æå–å¤±è´¥: {str(e)}', 'error')
    
    return redirect(url_for('isos_page'))

@app.route('/config')
def config_page():
    """é…ç½®é¡µé¢"""
    config = load_config()
    return render_template('config.html', config=config)

@app.route('/api/config/mode', methods=['POST'])
def save_mode_config():
    """ä¿å­˜æ¨¡å¼é…ç½®"""
    config = load_config()
    
    # æ›´æ–°é…ç½®
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
    
    # ç”Ÿæˆæ–°çš„ DHCP é…ç½®
    dhcp_conf = generate_dhcp_config(
        mode=config['dhcp_mode'],
        **config
    )
    
    # ä¿å­˜ DHCP é…ç½®
    with open('/etc/dhcp/dhcpd.conf', 'w') as f:
        f.write(dhcp_conf)
    
    # é‡æ–°åŠ è½½ DHCP æœåŠ¡
    run_cmd('dhcpd -t -cf /etc/dhcp/dhcpd.conf 2>/dev/null', timeout=10)
    code, _, err = run_cmd('killall -HUP dhcpd 2>/dev/null; echo ok', timeout=10)
    
    mode_name = 'Proxy æ¨¡å¼' if config['dhcp_mode'] == 'proxy' else 'Standalone æ¨¡å¼'
    flash(f'å·²åˆ‡æ¢åˆ° {mode_name}ï¼Œé…ç½®å·²ä¿å­˜', 'success')
    
    return redirect(url_for('config_page'))

@app.route('/api/status')
def api_status():
    """API: èŽ·å–æœåŠ¡çŠ¶æ€?""
    status = get_service_status()
    return jsonify(status)

@app.route('/api/isos')
def api_isos():
    """API: èŽ·å– ISO åˆ—è¡¨"""
    return jsonify(get_iso_list())

@app.route('/api/config')
def api_config():
    """API: èŽ·å–é…ç½®"""
    config = load_config()
    return jsonify(config)

@app.route('/api/logs')
def api_logs():
    """API: èŽ·å–æ—¥å¿—"""
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
    """API: æœåŠ¡æŽ§åˆ¶ (start/stop/restart)"""
    try:
        if action == 'start':
            # åŽå°å¯åŠ¨æ‰€æœ?PXE æœåŠ¡
            run_cmd('nohup bash /app/scripts/start-services.sh > /tmp/service-start.log 2>&1 &', timeout=5)
            return jsonify({'success': True, 'message': 'æœåŠ¡å¯åŠ¨å‘½ä»¤å·²å‘é€?})
        
        elif action == 'stop':
            # åœæ­¢æ‰€æœ?PXE æœåŠ¡
            run_cmd('killall dhcpd xinetd rpcbind nfsd mountd 2>/dev/null', timeout=10)
            return jsonify({'success': True, 'message': 'æ‰€æœ‰æœåŠ¡å·²åœæ­¢'})
        
        elif action == 'restart':
            # åŽå°é‡å¯æ‰€æœ?PXE æœåŠ¡
            run_cmd('nohup bash /app/scripts/restart-services.sh > /tmp/service-restart.log 2>&1 &', timeout=5)
            return jsonify({'success': True, 'message': 'æœåŠ¡é‡å¯å‘½ä»¤å·²å‘é€?})
        
        else:
            return jsonify({'success': False, 'message': 'æœªçŸ¥æ“ä½œ: ' + action})
    
    except Exception as e:
        return jsonify({'success': False, 'message': 'æ“ä½œå¤±è´¥: ' + str(e)})

# ============================================================================
# å¯åŠ¨
# ============================================================================

if __name__ == '__main__':
    print(f"""
â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—
â•?                   PXE Server WebUI                         â•?
â• â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•£
â•? URL:      http://{SERVER_IP}:{WEBUI_PORT}                         
â•? Mode:     {load_config().get('dhcp_mode', 'proxy'):12}                           
â•? Data:     {DATA_DIR}                     
â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    """)
    
    app.run(host='0.0.0.0', port=WEBUI_PORT, debug=False)
