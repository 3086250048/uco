#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import time
import subprocess
import logging
import re
import os

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BIN_DIR = os.path.join(ROOT_DIR, "bin")
LOG_FILE = os.environ.get("SAMBA_TRIGGER_LOG", "/var/log/samba-trigger-monitor.log")
AUDIT_LOG = os.environ.get("SAMBA_AUDIT_LOG", "/var/log/samba/audit.log")

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)

def monitor_samba_audit(log_file_path, watched_path_map, cooldown_seconds=60):
    if not os.path.exists(log_file_path):
        logging.error(f"日志文件 {log_file_path} 不存在，请确保 rsyslog 已正确配置")
        return

    # 记录每个 (username, watch_path) 的最后触发时间
    last_trigger = {}
    active_processes = []
    max_active = int(os.environ.get("SAMBA_TRIGGER_MAX_ACTIVE", "1"))
    find_cooldown_seconds = int(os.environ.get("SAMBA_FIND_TRIGGER_COOLDOWN", "10"))
    ip_txt_re = re.compile(r'^/srv/smb/find/\d{1,3}(?:\.\d{1,3}){3}\.txt$')

    def reap_children():
        active_processes[:] = [proc for proc in active_processes if proc.poll() is None]

    try:
        with open(log_file_path, 'r', encoding='utf-8', errors='replace') as file:
            file.seek(0, 2)
            while True:
                line = file.readline()
                if not line:
                    time.sleep(0.1)
                    continue

                # 提取 smbd_audit: 部分
                line = line.strip()
                audit_pos = line.find('smbd_audit:')
                if audit_pos == -1:
                    continue
                line = line[audit_pos:]

                # 解析：兼容 6 或 7 个字段
                match_7 = re.search(r'smbd_audit:\s*(.*?)\|(.*?)\|(.*?)\|(.*?)\|(.*?)\|(.*?)\|(.*)', line)
                if match_7:
                    username, client_ip, share_name, operation, status, flag, file_path = match_7.groups()
                else:
                    match_6 = re.search(r'smbd_audit:\s*(.*?)\|(.*?)\|(.*?)\|(.*?)\|(.*?)\|(.*)', line)
                    if not match_6:
                        continue
                    username, client_ip, share_name, operation, status, file_path = match_6.groups()

                if operation == 'openat' and (status == 'ok' or file_path.startswith('/srv/smb/users/')):
                    # 查找匹配的监控路径
                    for watch_path, script_cmd in watched_path_map.items():
                        if file_path.startswith(watch_path):
                            if watch_path == '/srv/smb/find/' and not ip_txt_re.match(file_path):
                                break
                            if watch_path == '/srv/smb/users/' and not file_path.endswith('.txt'):
                                break
                            # find 目录按具体 IP 文件去重；刷新入口按用户+根路径去重。
                            trigger_key = (username, watch_path, file_path) if watch_path == '/srv/smb/find/' else (username, watch_path)
                            trigger_cooldown = find_cooldown_seconds if watch_path == '/srv/smb/find/' else cooldown_seconds
                            now = time.time()
                            if trigger_key in last_trigger:
                                if now - last_trigger[trigger_key] < trigger_cooldown:
                                    logging.info(f"[冷却跳过] {username} 访问 {file_path}，距上次触发 {now - last_trigger[trigger_key]:.1f} 秒，小于 {trigger_cooldown} 秒")
                                    break  # 跳过本次触发

                            command = [
                                arg.format(path=file_path, client_ip=client_ip, smb_user=username)
                                for arg in script_cmd
                            ]
                            logging.info(f"检测到访问: {username} from {client_ip} accessed {file_path}. Triggering: {' '.join(command)}")
                            try:
                                reap_children()
                                if len(active_processes) >= max_active:
                                    logging.warning(f"当前已有 {len(active_processes)} 个触发任务在执行，跳过本次触发但不进入冷却: {file_path}")
                                    break
                                active_processes.append(subprocess.Popen(command))
                                last_trigger[trigger_key] = now
                            except Exception as e:
                                logging.error(f"执行命令 {' '.join(command)} 时出错: {e}")
                            break  # 匹配到一个监控路径后就退出循环，避免重复触发
                    else:
                        # 没有匹配任何 watch_path
                        logging.debug(f"路径 {file_path} 未触发任何动作。")
    except Exception as e:
        logging.error(f"发生未知错误: {e}")

if __name__ == "__main__":
    refresh_cmd = os.path.join(BIN_DIR, 'refresh.sh')
    icg_lookup_cmd = os.path.join(BIN_DIR, 'icg_lookup_for_ip.py')
    watched_paths = {
        r'/srv/smb/100M_port/刷新.txt': [refresh_cmd, '100m-port'],
        r'/srv/smb/mac_table/刷新.txt': [refresh_cmd, 'mac-arp'],
        r'/srv/smb/PVID/刷新.txt': [refresh_cmd, 'access-vlan'],
        r'/srv/smb/time/刷新.txt': [refresh_cmd, 'switch-time'],
        r'/srv/smb/find/刷新.txt': [refresh_cmd, 'find-index'],
        r'/srv/smb/find/': [icg_lookup_cmd, '{path}'],
        r'/srv/smb/Wireless_user/刷新.txt': [refresh_cmd, 'wireless'],
    }
    os.makedirs('/var/log/samba', exist_ok=True)
    logging.info("启动 Samba 审计日志监控守护进程（冷却时间 10 秒，基于用户+根路径去重）...")
    monitor_samba_audit(AUDIT_LOG, watched_paths, cooldown_seconds=300)
