#!/usr/bin/env python3
# ============================================================================
# PXE Server WebUI - Flask Application
# ============================================================================
# Web management UI for the PXE server.
#
# Features:
#   - ISO upload and management
#   - Service status monitoring
#   - DHCP/TFTP/NFS control
#   - DHCP mode switch (Proxy / Standalone)
#   - Logs
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
# Paths / configuration
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

# Ensure directories exist
for d in [DATA_DIR, ISO_DIR, BOOT_DIR, NFS_DIR, CONFIG_DIR, TEMP_DIR]:
    os.makedirs(d, exist_ok=True)

# ============================================================================
# Config management
# ============================================================================

DEFAULT_CONFIG = {
    'server_ip': SERVER_IP,
    'webui_port': WEBUI_PORT,
    'dhcp_mode': 'proxy',  # 'proxy' or 'standalone'
    'main_dhcp_ip': '192.168.8.1',  # main DHCP IP (Proxy mode)
    'dhcp_range_start': '192.168.8.100',
    'dhcp_range_end': '192.168.8.200',
    'subnet_mask': '255.255.255.0',
    'gateway': '192.168.8.1',
    'broadcast': '192.168.8.255',
    'subnet_network': '192.168.8.0',
}

def load_config():
    """Load config from file, filling in defaults."""
    if os.path.exists(CONF_FILE):
        try:
            with open(CONF_FILE, 'r') as f:
                config = json.load(f)
                for key, value in DEFAULT_CONFIG.items():
                    if key not in config:
                        config[key] = value
                return config
        except Exception:
            pass
    return DEFAULT_CONFIG.copy()

def save_config(config):
    """Save config to file."""
    with open(CONF_FILE, 'w') as f:
        json.dump(config, f, indent=2)

# ============================================================================
# Flask app
# ============================================================================

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', 'pxe-server-secret-key-change-in-production')
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024 * 1024  # 16GB max
app.config['UPLOAD_FOLDER'] = ISO_DIR

# ============================================================================
# Helpers
# ============================================================================

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

def run_cmd(cmd, shell=True, timeout=30):
    """Run a shell command and return (returncode, stdout, stderr)."""
    try:
        result = subprocess.run(cmd, shell=shell, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return 1, "", "Command timed out"
    except Exception as e:
        return 1, "", str(e)

def restart_services():
    """Restart PXE services."""
    script = '/app/scripts/restart-services.sh'
    if os.path.exists(script):
        threading.Thread(target=lambda: run_cmd('bash ' + script, timeout=60), daemon=True).start()
        return True
    return False

def generate_dhcp_config(mode='proxy', **kwargs):
    """Generate DHCP config for the given mode."""
    server_ip = kwargs.get('server_ip', SERVER_IP)
    subnet_mask = kwargs.get('subnet_mask', '255.255.255.0')
    subnet_network = kwargs.get('subnet_network', '192.168.8.0')
    broadcast = kwargs.get('broadcast', '192.168.8.255')
    dhcp_start = kwargs.get('dhcp_range_start', '192.168.8.100')
    dhcp_end = kwargs.get('dhcp_range_end', '192.168.8.200')
    gateway = kwargs.get('gateway', '192.168.8.1')

    if mode == 'proxy':
        # Proxy mode: main router provides IP, we only provide PXE options.
        config = """# DHCP Proxy Configuration
# Main DHCP provides IP; this server only serves PXE options.
authoritative;
ddns-update-style none;

omapi_port 7911;

log-facility local7;

subnet %s netmask %s {
    # Proxy mode: no address range, PXE options only.
}
""" % (subnet_network, subnet_mask)
    else:
        # Standalone mode: this server is the only DHCP server.
        config = """# DHCP Standalone Configuration
# This server provides IP and PXE boot.
authoritative;
ddns-update-style none;
default-lease-time 600;
max-lease-time 7200;
log-facility local7;

subnet %s netmask %s {
    range %s %s;
    option routers %s;
    option subnet-mask %s;
    option domain-name-servers %s;
    option broadcast-address %s;

    # PXE Boot
    filename "pxelinux.0";
    next-server %s;
}
""" % (subnet_network, subnet_mask, dhcp_start, dhcp_end, gateway,
       subnet_mask, gateway, broadcast, server_ip)
    return config

def get_service_status():
    """Return service status by reading /proc/net directly (pure Python)."""
    def check_port_py(port, proto='udp'):
        path = '/proc/net/%s' % proto
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
        except Exception:
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
            # WebUI is obviously running if this code is executing.
            # Do NOT self-request over HTTP: get_service_status() is called
            # by the '/' and '/api/status' handlers, so an HTTP self-check
            # would recurse and create a connection storm.
            svc_status = 'running'
        else:
            svc_status = 'running' if check_port_py(svc['port'], svc['proto']) else 'stopped'

        status[key] = {
            'name': svc['name'],
            'port': svc['port'],
            'proto': svc['proto'].upper(),
            'status': svc_status
        }

    return status

def format_size(size):
    """Human-readable file size."""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size < 1024:
            return "%.1f %s" % (size, unit)
        size /= 1024
    return "%.1f PB" % size

def get_iso_list():
    """List ISO files in the ISO directory."""
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

def extract_iso(filename):
    """Extract boot files from an ISO into boot/nfs directories."""
    iso_path = os.path.join(ISO_DIR, filename)
    iso_name = filename.replace('.iso', '')
    boot_path = os.path.join(BOOT_DIR, iso_name)
    nfs_path = os.path.join(NFS_DIR, iso_name)

    os.makedirs(boot_path, exist_ok=True)
    os.makedirs(nfs_path, exist_ok=True)

    # Try extracting with 7z first.
    cmd = '7z x -y "%s" -o"%s" >/dev/null 2>&1' % (iso_path, nfs_path)
    code, out, err = run_cmd(cmd, timeout=300)

    if code != 0:
        # Fall back to loop mount.
        mount_path = os.path.join(TEMP_DIR, iso_name)
        os.makedirs(mount_path, exist_ok=True)

        cmd = 'mount -o loop,ro "%s" "%s" 2>/dev/null' % (iso_path, mount_path)
        code, out, err = run_cmd(cmd)

        if code == 0:
            run_cmd('cp -r "%s"/* "%s"/' % (mount_path, nfs_path))
            run_cmd('umount "%s"' % mount_path)

    # Copy kernel/initrd boot files.
    boot_files = []
    for root, dirs, files in os.walk(nfs_path):
        for f in files:
            if any(x in f.lower() for x in ['vmlinuz', 'linux', 'bzimage', 'kernel']):
                src = os.path.join(root, f)
                dest = os.path.join(boot_path, f)
                run_cmd('cp "%s" "%s"' % (src, dest))
                boot_files.append(f)
            elif any(x in f.lower() for x in ['initrd', 'initramfs', 'inird']):
                src = os.path.join(root, f)
                dest = os.path.join(boot_path, f)
                run_cmd('cp "%s" "%s"' % (src, dest))
                boot_files.append(f)

    return boot_files

# ============================================================================
# Routes
# ============================================================================

@app.route('/')
def index():
    """Home page - status overview."""
    config = load_config()
    status = get_service_status()
    isos = get_iso_list()

    code, uptime, _ = run_cmd("cat /proc/uptime | awk '{print $1}'")
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
    """ISO management page."""
    isos = get_iso_list()
    return render_template('isos.html', isos=isos)

@app.route('/upload', methods=['POST'])
def upload_iso():
    """Upload an ISO file."""
    if 'file' not in request.files:
        flash('No file part', 'error')
        return redirect(url_for('isos_page'))

    file = request.files['file']
    if file.filename == '':
        flash('No file selected', 'error')
        return redirect(url_for('isos_page'))

    if file and allowed_file(file.filename):
        filename = secure_filename(file.filename)
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        file.save(filepath)

        flash('Uploaded: %s' % filename, 'success')

        # Extract boot files.
        try:
            boot_files = extract_iso(filename)
            if boot_files:
                flash('Extracted %d boot files' % len(boot_files), 'info')
            else:
                flash('No boot files found', 'warning')
        except Exception as e:
            flash('Boot extraction failed: %s' % str(e), 'warning')

        return redirect(url_for('isos_page'))

    flash('Only .iso files are allowed', 'error')
    return redirect(url_for('isos_page'))

@app.route('/delete/<filename>', methods=['POST'])
def delete_iso(filename):
    """Delete an ISO file and its extracted data."""
    filename = secure_filename(filename)
    filepath = os.path.join(ISO_DIR, filename)

    if os.path.exists(filepath):
        os.remove(filepath)

        iso_name = filename.replace('.iso', '')
        boot_path = os.path.join(BOOT_DIR, iso_name)
        nfs_path = os.path.join(NFS_DIR, iso_name)

        if os.path.exists(boot_path):
            run_cmd('rm -rf "%s"' % boot_path)
        if os.path.exists(nfs_path):
            run_cmd('rm -rf "%s"' % nfs_path)

        flash('Deleted: %s' % filename, 'success')
    else:
        flash('File not found', 'error')

    return redirect(url_for('isos_page'))

@app.route('/extract/<filename>', methods=['POST'])
def extract_boot(filename):
    """Manually extract boot files from an ISO."""
    filename = secure_filename(filename)

    try:
        boot_files = extract_iso(filename)
        flash('Extracted %d boot files' % len(boot_files), 'success')
    except Exception as e:
        flash('Extraction failed: %s' % str(e), 'error')

    return redirect(url_for('isos_page'))

@app.route('/config')
def config_page():
    """Configuration page."""
    config = load_config()
    return render_template('config.html', config=config)

@app.route('/api/config/mode', methods=['POST'])
def save_mode_config():
    """Save DHCP mode config and reload DHCP."""
    config = load_config()

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

    # Generate DHCP config.
    dhcp_conf = generate_dhcp_config(mode=config['dhcp_mode'], **config)

    with open('/etc/dhcp/dhcpd.conf', 'w') as f:
        f.write(dhcp_conf)

    # Validate and reload DHCP.
    run_cmd('dhcpd -t -cf /etc/dhcp/dhcpd.conf 2>/dev/null', timeout=10)
    code, _, err = run_cmd('killall -HUP dhcpd 2>/dev/null; echo ok', timeout=10)

    mode_name = 'Proxy' if config['dhcp_mode'] == 'proxy' else 'Standalone'
    flash('Saved %s mode config' % mode_name, 'success')

    return redirect(url_for('config_page'))

@app.route('/api/status')
def api_status():
    """API: service status."""
    status = get_service_status()
    return jsonify(status)

@app.route('/api/isos')
def api_isos():
    """API: ISO list."""
    return jsonify(get_iso_list())

@app.route('/api/config')
def api_config():
    """API: config JSON."""
    config = load_config()
    return jsonify(config)

@app.route('/api/logs')
def api_logs():
    """API: logs."""
    lines = int(request.args.get('lines', 100))
    logs = []

    log_files = [
        '/var/log/syslog',
        '/var/log/messages',
        '/tmp/pxe-server.log'
    ]

    for log_file in log_files:
        if os.path.exists(log_file):
            code, out, _ = run_cmd('tail -%d "%s" 2>/dev/null | grep -E "(dhcp|tftp|nfs|pxe)" || true' % (lines, log_file))
            if out:
                logs.append({'file': log_file, 'content': out})

    return jsonify(logs)

@app.route('/api/service/<action>', methods=['POST'])
def service_control(action):
    """API: service control (start/stop/restart)."""
    try:
        if action == 'start':
            run_cmd('nohup bash /app/scripts/start-services.sh > /tmp/service-start.log 2>&1 &', timeout=5)
            return jsonify({'success': True, 'message': 'Services starting'})

        elif action == 'stop':
            run_cmd('killall dhcpd xinetd rpcbind nfsd mountd 2>/dev/null', timeout=10)
            return jsonify({'success': True, 'message': 'Services stopped'})

        elif action == 'restart':
            run_cmd('nohup bash /app/scripts/restart-services.sh > /tmp/service-restart.log 2>&1 &', timeout=5)
            return jsonify({'success': True, 'message': 'Services restarting'})

        else:
            return jsonify({'success': False, 'message': 'Unknown action: ' + action})

    except Exception as e:
        return jsonify({'success': False, 'message': 'Error: ' + str(e)})

# ============================================================================
# Main
# ============================================================================

if __name__ == '__main__':
    print("=" * 60)
    print("  PXE Server WebUI")
    print("  URL:  http://%s:%d" % (SERVER_IP, WEBUI_PORT))
    print("  Mode: %s" % load_config().get('dhcp_mode', 'proxy'))
    print("  Data: %s" % DATA_DIR)
    print("=" * 60)

    app.run(host='0.0.0.0', port=WEBUI_PORT, debug=False)
