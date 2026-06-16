# 刷新逻辑说明

更新时间：2026-06-16

## 1. 总体入口

统一刷新入口：

```bash
/root/work/bin/refresh.sh <任务名>
```

支持的任务：

| 任务名 | 作用 |
| --- | --- |
| `mac-arp` | 刷新 MAC/ARP 表 |
| `100m-port` | 刷新低速率端口 |
| `access-vlan` | 刷新 PVID |
| `switch-time` | 刷新交换机时间 |
| `wireless` | 刷新无线用户表 |
| `icg-users` | 全量 ICG 用户策略信息，保留入口，不做定时执行 |
| `find-index` | 生成按 IP 查询索引 |
| `all` | 依次执行 `mac-arp`、`wireless`、`find-index` |

`all` 不包含 `icg-users`，避免全量扫描 AD/ICG 导致等待过久。

## 2. 定时刷新

当前 root crontab 中的刷新任务：

| 时间 | 命令 | 说明 |
| --- | --- | --- |
| 每小时 00 分 | `/root/work/bin/refresh.sh mac-arp` | 刷新 MAC/ARP 表 |
| 每天 00:00 | `/root/work/bin/refresh.sh 100m-port` | 刷新低速率端口 |
| 每小时 00 分 | `/root/work/bin/refresh.sh wireless` | 刷新无线用户表 |
| 每天 15:05 | `/root/work/bin/refresh.sh find-index` | 重建 `/srv/smb/find/<IP>.txt` 索引 |

ICG 不做全量定时刷新。ICG 策略信息在用户访问具体 IP 查询文件时按需刷新。

刷新日志：

```text
/var/log/switch-toolkit-refresh.log
```

## 3. Samba 手动触发

服务：

```text
samba-audit-trigger.service
```

脚本：

```text
/root/work/bin/samba_audit_trigger.py
```

监听日志：

```text
/var/log/samba/audit.log
```

触发日志：

```text
/var/log/samba-trigger-monitor.log
```

访问以下刷新文件时触发对应任务：

| 访问文件 | 触发命令 |
| --- | --- |
| `/srv/smb/100M_port/刷新.txt` | `/root/work/bin/refresh.sh 100m-port` |
| `/srv/smb/mac_table/刷新.txt` | `/root/work/bin/refresh.sh mac-arp` |
| `/srv/smb/PVID/刷新.txt` | `/root/work/bin/refresh.sh access-vlan` |
| `/srv/smb/time/刷新.txt` | `/root/work/bin/refresh.sh switch-time` |
| `/srv/smb/find/刷新.txt` | `/root/work/bin/refresh.sh find-index` |
| `/srv/smb/Wireless_user/刷新.txt` | `/root/work/bin/refresh.sh wireless` |

这些刷新入口冷却时间为 300 秒。

## 4. find 查询按需 ICG 刷新

用户访问具体 IP 查询文件时：

```text
/srv/smb/find/<IP>.txt
```

例如：

```text
/srv/smb/find/10.20.59.209.txt
```

触发：

```bash
/root/work/bin/icg_lookup_for_ip.py /srv/smb/find/<IP>.txt
```

按需查询逻辑：

1. 从当前 IP 文件历史无线记录中解析用户名、IP、MAC、AP 名称、APID。
2. 同时读取最新 `/srv/smb/Wireless_user` CSV，按 IP 查找当前无线在线用户。
3. 如果能找到用户名，则按用户名去 ICG 查询策略。
4. 只保留“启用”的“应用控制策略”。
5. 将结果写回当前 `/srv/smb/find/<IP>.txt` 顶部。
6. 同步缓存到 `/srv/smb/icg_users/`。

缓存文件：

```text
/srv/smb/icg_users/<IP>_icg_users.csv
/srv/smb/icg_users/<IP>_icg_users.json
```

find 按需查询只匹配标准 IPv4 `.txt` 文件，例如：

```text
/srv/smb/find/10.20.59.209.txt
```

不会触发目录访问或非 IP 文件访问。

find 查询冷却时间为 10 秒。

## 5. 有线和无线用户处理

无线用户：

- 可以从无线 CSV 或 IP 文件历史无线记录中拿到用户名。
- 能按用户名查询 ICG。
- 最终能显示启用的应用控制策略。

有线用户：

- 当前没有可靠的 `IP -> 用户名` 来源。
- 如果 `/srv/smb/find/<IP>.txt` 中无法解析到用户名，则不会查询 ICG。
- 不会全量查 AD，也不会猜测用户名。

## 6. 锁和并发控制

`refresh.sh` 使用全局锁：

```text
/tmp/switch-toolkit-lock/refresh.lock
```

同一时间只允许一个刷新任务运行。

每个任务还有独立任务锁：

```text
/tmp/switch-toolkit-lock/<任务名>.lock
```

Samba 触发服务当前 systemd 环境：

```text
SAMBA_TRIGGER_MAX_ACTIVE=1
REFRESH_PARALLEL_JOBS=6
```

含义：

- Samba 触发任务同一时间最多运行 1 个。
- 刷新脚本内部默认并发数为 6。
- 无线采集默认并发数由 `WIRELESS_PARALLEL_JOBS` 控制，未设置时为 2。

## 7. 日志优化

`find` 目录访问、冷却跳过、并发忙跳过默认降为 `DEBUG`，不会写入普通日志。

普通日志只记录：

- 服务启动
- 真正启动的触发任务
- 非 find 刷新入口的并发跳过
- 错误

触发日志已配置 logrotate：

```text
/etc/logrotate.d/samba-trigger-monitor
```

策略：

- 每周轮转
- 保留 8 份
- 压缩
- 使用 `copytruncate`

## 8. 关键文件位置

| 文件 | 作用 |
| --- | --- |
| `/root/work/bin/refresh.sh` | 统一刷新入口 |
| `/root/work/bin/samba_audit_trigger.py` | Samba 审计访问触发器 |
| `/root/work/bin/csv_to_ip.py` | 生成 `/srv/smb/find/<IP>.txt` 索引 |
| `/root/work/bin/icg_lookup_for_ip.py` | 按 IP 文件中的用户名查询 ICG 应用控制策略 |
| `/root/work/bin/collect_ac6508_users.sh` | 采集无线用户 |
| `/root/.config/switch-toolkit/icg.env` | ICG/AD 运行配置，包含真实账号密码，不提交 Git |
| `/root/work/config/icg.env.example` | ICG/AD 配置模板，不包含真实密码 |

