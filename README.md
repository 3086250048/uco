# Switch Toolkit

用于批量采集交换机 MAC/ARP、端口速率、PVID、系统时间，以及生成按 IP 查询的索引文件。

## 目录结构

- `bin/`: 可执行入口脚本
- `lib/`: Shell 公共函数
- `config/`: 区域配置、交换机 IP 列表和 AC IP 列表
- `tests/`: 离线测试和 SNMP mock
- `docs/`: 历史脚本备份

## 依赖

- Bash 4+
- `awk`, `xargs`, `sort`, `find`
- `snmpget`, `snmpbulkwalk`，来自 net-snmp 工具包
- Python 3，用于 `bin/csv_to_ip.py` 和 `bin/samba_audit_trigger.py`
- Perl，用于 `bin/collect_ac6508_users.sh` 的 Huawei AC6508 / H3C AC 表解析

## 常用命令

```bash
bin/collect_mac_arp.sh -i config/switches/UCO_switch -o /srv/smb/mac_table/UCO -p 20
bin/filter_100M_port.sh -i config/switches/UCO_switch -o /srv/smb/100M_port/UCO -p 20
bin/get_access_vlan.sh -i config/switches/UCO-1F-switch -o /srv/smb/PVID -p 20
bin/collect_switch_time.sh -i config/switches/UCO_switch -o /srv/smb/time/UCO -p 20
bin/collect_ac6508_users.sh -f config/ac_areas.tsv -o /srv/smb/Wireless_user -p 4
bin/csv_to_ip.py --mac-dir /srv/smb/mac_table --wireless-dir /srv/smb/Wireless_user --find-dir /srv/smb/find
```

批量刷新入口读取 `config/areas.tsv` 或 `config/pvid_switches.tsv`：
无线用户采集默认读取 `config/ac_areas.tsv`，格式为 `区域 AC地址 团体名 厂商`，并输出到 `/srv/smb/Wireless_user/<区域>/`。
H3C AC 优先读取 WLAN station table；TJ 这类 Comware 9 设备没有老表时，会自动从 `STAMGR_CLIENT_*` 日志表还原在线用户。

```bash
bin/flash_mac_arp.sh
bin/flash_100M_port.sh
bin/flash_switch_time.sh
bin/flash_access_vlan.sh
```

## 测试

测试不连接真实交换机，使用 `tests/mocks` 中的 mock SNMP 命令验证脚本输出。

```bash
tests/run_tests.sh
```

当前覆盖：

- MAC 表采集
- MAC/ARP 关联采集
- 低速率端口筛选
- PVID 采集
- 交换机时间采集
- AC6508 用户采集
- IP 查询索引生成
- Shell/Python 语法检查
