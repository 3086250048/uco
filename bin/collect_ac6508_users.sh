#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"
# ============================================================
# 脚本名称: collect_ac6508_users.sh
# 功能: 获取 AC 在线用户列表，并关联接入 AP 信息
# 输出字段: 接入AP名称, 用户名, APID, MAC地址, IP地址
# 默认配置: config/ac_areas.tsv
# 默认团体名: ucoac6508
# 依赖: snmpget, snmpbulkwalk, perl
# ============================================================

COMMUNITY="ucoac6508"
SNMP_VERSION="2c"
OUTPUT_DIR="/srv/smb/Wireless_user"
CONFIG_FILE="$ROOT_DIR/config/ac_areas.tsv"
PARALLEL_JOBS=4
SNMP_TIMEOUT=10
SNMP_RETRIES=2
IP_LIST_FILE=""
AC_IP=""

# 已在 10.2.248.253 / AC6508 上验证的 Huawei WLAN 用户表。
OID_STA_BASE="1.3.6.1.4.1.2011.6.139.18.1.2.1"
OID_USER_NAME="${OID_STA_BASE}.2"
OID_USER_AP_MAC="${OID_STA_BASE}.3"
OID_USER_AP_NAME="${OID_STA_BASE}.4"
OID_USER_IP="${OID_STA_BASE}.25"

# AP 信息表，索引为 AP MAC。用于补齐 AP 名称和 APID。
OID_AP_NAME_BY_MAC="1.3.6.1.4.1.2011.6.139.13.3.3.1.4"
OID_AP_ID_BY_MAC="1.3.6.1.4.1.2011.6.139.13.3.3.1.40"

# H3C WX 系列 AC WLAN 表。
OID_H3C_AP_BASE="1.3.6.1.4.1.25506.2.75.2.1.1.1"
OID_H3C_AP_IP="${OID_H3C_AP_BASE}.2"
OID_H3C_AP_MAC="${OID_H3C_AP_BASE}.3"
OID_H3C_AP_NAME="${OID_H3C_AP_BASE}.5"
OID_H3C_STA_BASE="1.3.6.1.4.1.25506.2.75.3.1.1.1"
OID_H3C_STA_IP="${OID_H3C_STA_BASE}.2"
OID_H3C_STA_USER="${OID_H3C_STA_BASE}.3"
OID_H3C_STA_SSID="${OID_H3C_STA_BASE}.12"
OID_H3C_STA_MAC="${OID_H3C_STA_BASE}.23"
OID_H3C_STA_AP_MAC="${OID_H3C_STA_BASE}.40"
OID_H3C_LOG_BUFFER="1.3.6.1.4.1.25506.2.119.1.2.1.2"

usage() {
    echo "用法: $0 [-f config_file] [-a ac_ip] [-i ip_list_file] [-o output_dir] [-p parallel_jobs] [-c community]"
    echo "示例: $0"
    echo "示例: $0 -f config/ac_areas.tsv -o /srv/smb/Wireless_user"
    echo "示例: $0 -a 10.2.248.253 -o ./result"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a) AC_IP="$2"; shift 2 ;;
        -i) IP_LIST_FILE="$2"; shift 2 ;;
        -f) CONFIG_FILE="$2"; shift 2 ;;
        -o) OUTPUT_DIR="$2"; shift 2 ;;
        -p) PARALLEL_JOBS="$2"; shift 2 ;;
        -c) COMMUNITY="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

[[ -z "$IP_LIST_FILE" ]] || ensure_file "$IP_LIST_FILE"
[[ -n "$AC_IP" || -n "$IP_LIST_FILE" ]] || ensure_file "$CONFIG_FILE"

ensure_dir "$OUTPUT_DIR"
TIMESTAMP=$(date +"%Y%m%d%H")
TMP_PREFIX="${OUTPUT_DIR}/.ac6508_user_tmp_$$"
TARGET_WORK_FILE="${TMP_PREFIX}.targets"

cleanup() {
    rm -f "${TMP_PREFIX}"_* "$TARGET_WORK_FILE" 2>/dev/null
}
trap cleanup EXIT

write_target() {
    local area="$1"
    local ip="$2"
    local community="${3:-$COMMUNITY}"
    local vendor="${4:-auto}"
    [[ -n "$area" && -n "$ip" ]] || return 0
    printf '%s\t%s\t%s\t%s\n' "$area" "$ip" "$community" "$vendor" >> "$TARGET_WORK_FILE"
}

if [[ -n "$IP_LIST_FILE" ]]; then
    while IFS= read -r ip; do
        write_target "AC" "$ip" "$COMMUNITY" "auto"
    done < <(read_ip_list "$IP_LIST_FILE")
elif [[ -n "$AC_IP" ]]; then
    write_target "AC" "$AC_IP" "$COMMUNITY" "auto"
else
    awk -v default_community="$COMMUNITY" '
        {
            sub(/\r$/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if ($0 == "") next
            area = $1
            ip = $2
            community = ($3 == "" ? default_community : $3)
            vendor = ($4 == "" ? "auto" : $4)
            if (area != "" && ip != "") {
                print area "\t" ip "\t" community "\t" vendor
            }
        }
    ' "$CONFIG_FILE" > "$TARGET_WORK_FILE"
fi

[[ -s "$TARGET_WORK_FILE" ]] || die "未找到可采集的 AC 目标"

echo "开始采集 AC 用户信息，输出目录: $OUTPUT_DIR"

process_huawei_ac() {
    local ac_ip="$1"
    local community="$2"
    local tmp_out="$3"
    local tmp_user=$(mktemp) || return 1
    local tmp_apmac=$(mktemp) || return 1
    local tmp_apname=$(mktemp) || return 1
    local tmp_ip=$(mktemp) || return 1
    local tmp_ap_table=$(mktemp) || return 1
    local tmp_apid_table=$(mktemp) || return 1

    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr10 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_USER_NAME" > "$tmp_user" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr10 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_USER_AP_MAC" > "$tmp_apmac" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr10 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_USER_AP_NAME" > "$tmp_apname" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr10 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_USER_IP" > "$tmp_ip" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr10 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_AP_NAME_BY_MAC" > "$tmp_ap_table" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr10 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_AP_ID_BY_MAC" > "$tmp_apid_table" 2>/dev/null &
    wait

    if [[ ! -s "$tmp_user" && ! -s "$tmp_ip" ]]; then
        rm -f "$tmp_user" "$tmp_apmac" "$tmp_apname" "$tmp_ip" "$tmp_ap_table" "$tmp_apid_table"
        return 1
    fi

    perl - "$OID_USER_NAME" "$tmp_user" "$OID_USER_AP_MAC" "$tmp_apmac" \
        "$OID_USER_AP_NAME" "$tmp_apname" "$OID_USER_IP" "$tmp_ip" \
        "$OID_AP_NAME_BY_MAC" "$tmp_ap_table" "$OID_AP_ID_BY_MAC" "$tmp_apid_table" > "$tmp_out" <<'PERL'
use strict;
use warnings;

my %file = (
    user      => [$ARGV[0],  $ARGV[1]],
    ap_mac    => [$ARGV[2],  $ARGV[3]],
    ap_name   => [$ARGV[4],  $ARGV[5]],
    user_ip   => [$ARGV[6],  $ARGV[7]],
    ap_table  => [$ARGV[8],  $ARGV[9]],
    ap_id     => [$ARGV[10], $ARGV[11]],
);

sub records {
    my ($path) = @_;
    open my $fh, "<", $path or return ();
    my @records;
    my $current = "";
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/^iso\./1./;
        if ($line =~ /^1\.3\./) {
            push @records, $current if $current ne "";
            $current = $line;
        } elsif ($line =~ /^\s+[0-9A-Fa-f]{2}/ && $current =~ /Hex-STRING:/) {
            $current .= " $line";
        }
    }
    push @records, $current if $current ne "";
    close $fh;
    return @records;
}


sub value_from_raw {
    my ($raw) = @_;
    if ($raw =~ /Hex-STRING:\s*(.*)$/s) {
        my $hex = $1;
        $hex =~ s/[^0-9A-Fa-f]//g;
        return pack("H*", $hex);
    }
    if ($raw =~ /STRING:\s*"(.*)"\s*$/s) {
        my $value = $1;
        $value =~ s/\\"/"/g;
        return $value;
    }
    if ($raw =~ /STRING:\s*(.*)\s*$/s) {
        return $1 eq '""' ? "" : $1;
    }
    if ($raw =~ /IpAddress:\s*([0-9.]+)/) {
        return $1;
    }
    if ($raw =~ /(?:INTEGER|Gauge32):\s*(-?\d+)/) {
        return $1;
    }
    return "";
}

sub table_map {
    my ($base, $path) = @_;
    my %map;
    for my $record (records($path)) {
        next unless $record =~ /^\Q$base\E\.(\d+(?:\.\d+)*)\s+=\s+(.+)$/s;
        $map{$1} = value_from_raw($2);
    }
    return %map;
}

sub mac_from_index {
    my ($idx) = @_;
    my @bytes = split /\./, $idx;
    return "" if @bytes < 6;
    @bytes = @bytes[-6..-1];
    my $hex = join "", map { sprintf "%02x", $_ } @bytes;
    return substr($hex, 0, 4) . "-" . substr($hex, 4, 4) . "-" . substr($hex, 8, 4);
}

sub mac_from_binary {
    my ($value) = @_;
    return "" if !defined($value) || length($value) < 6;
    my $hex = unpack "H*", substr($value, 0, 6);
    return substr($hex, 0, 4) . "-" . substr($hex, 4, 4) . "-" . substr($hex, 8, 4);
}

sub oid_index_from_binary_mac {
    my ($value) = @_;
    return "" if !defined($value) || length($value) < 6;
    return join ".", unpack "C6", substr($value, 0, 6);
}

sub csv {
    my ($value) = @_;
    $value = "" if !defined $value;
    $value =~ s/\r|\n/ /g;
    if ($value =~ /[",]/) {
        $value =~ s/"/""/g;
        return qq("$value");
    }
    return $value;
}

my %user      = table_map(@{$file{user}});
my %ap_mac    = table_map(@{$file{ap_mac}});
my %ap_name   = table_map(@{$file{ap_name}});
my %user_ip   = table_map(@{$file{user_ip}});
my %ap_table  = table_map(@{$file{ap_table}});
my %ap_id     = table_map(@{$file{ap_id}});

my %ap_id_by_name;
for my $ap_idx (keys %ap_table) {
    next if ($ap_table{$ap_idx} // "") eq "" || ($ap_id{$ap_idx} // "") eq "";
    $ap_id_by_name{$ap_table{$ap_idx}} = $ap_id{$ap_idx};
}

my %idx_seen;
$idx_seen{$_} = 1 for (keys %user, keys %ap_mac, keys %ap_name, keys %user_ip);

for my $idx (sort {
    ($ap_name{$a} // "") cmp ($ap_name{$b} // "") || mac_from_index($a) cmp mac_from_index($b)
} keys %idx_seen) {
    my $mac = mac_from_index($idx);
    next if $mac eq "";

    my $ap_mac_key = mac_from_binary($ap_mac{$idx} // "");
    my $ap_oid_idx = oid_index_from_binary_mac($ap_mac{$idx} // "");
    my $name = $ap_name{$idx} // "";
    $name = $ap_table{$ap_oid_idx} // "" if $name eq "" && $ap_oid_idx ne "";
    my $ap_id = $ap_id{$ap_oid_idx} // "";
    $ap_id = $ap_id_by_name{$name} // "" if $ap_id eq "" && $name ne "";
    next if $name eq "" || $ap_id eq "";

    my $username = $user{$idx} // "";
    $username = "(未认证)" if $username eq "";

    print join(",", map { csv($_) } (
        $name,
        $username,
        $ap_id,
        $mac,
        $user_ip{$idx} // "",
    )), "\n";
}
PERL

    rm -f "$tmp_user" "$tmp_apmac" "$tmp_apname" "$tmp_ip" "$tmp_ap_table" "$tmp_apid_table"

    if [[ ! -s "$tmp_out" ]]; then
        rm -f "$tmp_out"
        return 1
    fi
    return 0
}

process_h3c_ac() {
    local ac_ip="$1"
    local community="$2"
    local tmp_out="$3"
    local tmp_ap_ip=$(mktemp) || return 1
    local tmp_ap_mac=$(mktemp) || return 1
    local tmp_ap_name=$(mktemp) || return 1
    local tmp_sta_ip=$(mktemp) || return 1
    local tmp_sta_user=$(mktemp) || return 1
    local tmp_sta_mac=$(mktemp) || return 1
    local tmp_sta_ap_mac=$(mktemp) || return 1

    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr20 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_H3C_AP_IP" > "$tmp_ap_ip" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr20 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_H3C_AP_MAC" > "$tmp_ap_mac" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr20 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_H3C_AP_NAME" > "$tmp_ap_name" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr20 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_H3C_STA_IP" > "$tmp_sta_ip" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr20 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_H3C_STA_USER" > "$tmp_sta_user" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr20 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_H3C_STA_MAC" > "$tmp_sta_mac" 2>/dev/null &
    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr20 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_H3C_STA_AP_MAC" > "$tmp_sta_ap_mac" 2>/dev/null &
    wait

    if [[ ! -s "$tmp_sta_ip" && ! -s "$tmp_sta_mac" ]]; then
        rm -f "$tmp_ap_ip" "$tmp_ap_mac" "$tmp_ap_name" "$tmp_sta_ip" "$tmp_sta_user" "$tmp_sta_mac" "$tmp_sta_ap_mac"
        return 1
    fi

    perl - "$OID_H3C_AP_IP" "$tmp_ap_ip" "$OID_H3C_AP_MAC" "$tmp_ap_mac" "$OID_H3C_AP_NAME" "$tmp_ap_name" \
        "$OID_H3C_STA_IP" "$tmp_sta_ip" "$OID_H3C_STA_USER" "$tmp_sta_user" \
        "$OID_H3C_STA_MAC" "$tmp_sta_mac" "$OID_H3C_STA_AP_MAC" "$tmp_sta_ap_mac" > "$tmp_out" <<'H3C_PERL'
use strict;
use warnings;

my %file = (
    ap_ip      => [$ARGV[0],  $ARGV[1]],
    ap_mac     => [$ARGV[2],  $ARGV[3]],
    ap_name    => [$ARGV[4],  $ARGV[5]],
    sta_ip     => [$ARGV[6],  $ARGV[7]],
    sta_user   => [$ARGV[8],  $ARGV[9]],
    sta_mac    => [$ARGV[10], $ARGV[11]],
    sta_ap_mac => [$ARGV[12], $ARGV[13]],
);

sub records {
    my ($path) = @_;
    open my $fh, "<", $path or return ();
    my @records;
    my $current = "";
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/^iso\./1./;
        $line =~ s/^\./1./;
        if ($line =~ /^1\.3\./) {
            push @records, $current if $current ne "";
            $current = $line;
        } elsif ($line =~ /^\s+[0-9A-Fa-f]{2}/ && $current =~ /Hex-STRING:/) {
            $current .= " $line";
        }
    }
    push @records, $current if $current ne "";
    close $fh;
    return @records;
}

sub value_from_raw {
    my ($raw) = @_;
    if ($raw =~ /Hex-STRING:\s*(.*)$/s) {
        my $hex = $1;
        $hex =~ s/[^0-9A-Fa-f]//g;
        return pack("H*", $hex);
    }
    if ($raw =~ /STRING:\s*"(.*)"\s*$/s) {
        my $value = $1;
        $value =~ s/\\"/"/g;
        return $value;
    }
    if ($raw =~ /STRING:\s*(.*)\s*$/s) {
        return $1 eq '""' ? "" : $1;
    }
    if ($raw =~ /IpAddress:\s*([0-9.]+)/) {
        return $1;
    }
    if ($raw =~ /(?:INTEGER|Gauge32|Counter32|Counter64):\s*(-?\d+)/) {
        return $1;
    }
    return "";
}

sub table_map {
    my ($base, $path) = @_;
    my %map;
    for my $record (records($path)) {
        next unless $record =~ /^\Q$base\E\.(\d+(?:\.\d+)*)\s+=\s+(.+)$/s;
        $map{$1} = value_from_raw($2);
    }
    return %map;
}

sub mac_from_index {
    my ($idx) = @_;
    my @bytes = split /\./, $idx;
    return "" if @bytes < 6;
    @bytes = @bytes[-6..-1];
    my $hex = join "", map { sprintf "%02x", $_ } @bytes;
    return substr($hex, 0, 4) . "-" . substr($hex, 4, 4) . "-" . substr($hex, 8, 4);
}

sub mac_from_binary {
    my ($value) = @_;
    return "" if !defined($value) || length($value) < 6;
    my $hex = unpack "H*", substr($value, 0, 6);
    return substr($hex, 0, 4) . "-" . substr($hex, 4, 4) . "-" . substr($hex, 8, 4);
}

sub csv {
    my ($value) = @_;
    $value = "" if !defined $value;
    $value =~ s/\r|\n/ /g;
    if ($value =~ /[",]/) {
        $value =~ s/"/""/g;
        return qq("$value");
    }
    return $value;
}

my %ap_ip      = table_map(@{$file{ap_ip}});
my %ap_mac     = table_map(@{$file{ap_mac}});
my %ap_name    = table_map(@{$file{ap_name}});
my %sta_ip     = table_map(@{$file{sta_ip}});
my %sta_user   = table_map(@{$file{sta_user}});
my %sta_mac    = table_map(@{$file{sta_mac}});
my %sta_ap_mac = table_map(@{$file{sta_ap_mac}});

my %ap_by_mac;
for my $idx (keys %ap_mac) {
    my $mac = mac_from_binary($ap_mac{$idx});
    next if $mac eq "";
    $ap_by_mac{$mac} = {
        name => (($ap_name{$idx} // "") ne "" ? $ap_name{$idx} : $mac),
        id   => (($ap_ip{$idx} // "") ne "" ? $ap_ip{$idx} : $idx),
    };
}

my %idx_seen;
$idx_seen{$_} = 1 for (keys %sta_ip, keys %sta_mac, keys %sta_ap_mac);

for my $idx (sort {
    ($sta_ip{$a} // "") cmp ($sta_ip{$b} // "") || mac_from_index($a) cmp mac_from_index($b)
} keys %idx_seen) {
    my $mac = mac_from_binary($sta_mac{$idx} // "");
    $mac = mac_from_index($idx) if $mac eq "";
    next if $mac eq "";

    my $ap_mac = mac_from_binary($sta_ap_mac{$idx} // "");
    my $ap_name = $ap_by_mac{$ap_mac}{name} // ($ap_mac ne "" ? $ap_mac : "");
    my $ap_id = $ap_by_mac{$ap_mac}{id} // "";
    $ap_id = $ap_mac if $ap_id eq "" && $ap_mac ne "";
    next if $ap_name eq "" || $ap_id eq "";

    my $username = $sta_user{$idx} // "";
    $username = "(未认证)" if $username eq "";

    print join(",", map { csv($_) } (
        $ap_name,
        $username,
        $ap_id,
        $mac,
        $sta_ip{$idx} // "",
    )), "\n";
}
H3C_PERL

    rm -f "$tmp_ap_ip" "$tmp_ap_mac" "$tmp_ap_name" "$tmp_sta_ip" "$tmp_sta_user" "$tmp_sta_mac" "$tmp_sta_ap_mac"

    if [[ ! -s "$tmp_out" ]]; then
        rm -f "$tmp_out"
        return 1
    fi
    return 0
}

process_h3c_log_ac() {
    local ac_ip="$1"
    local community="$2"
    local tmp_out="$3"
    local tmp_log=$(mktemp) || return 1

    snmpbulkwalk -Cc -v "$SNMP_VERSION" -c "$community" -Cr50 -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" "$ac_ip" "$OID_H3C_LOG_BUFFER" > "$tmp_log" 2>/dev/null

    if [[ ! -s "$tmp_log" ]]; then
        rm -f "$tmp_log"
        return 1
    fi

    perl - "$OID_H3C_LOG_BUFFER" "$tmp_log" > "$tmp_out" <<'H3C_LOG_PERL'
use strict;
use warnings;

my ($base, $path) = @ARGV;

sub records {
    my ($path) = @_;
    open my $fh, "<", $path or return ();
    my @records;
    my $current = "";
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/^iso\./1./;
        $line =~ s/^\./1./;
        if ($line =~ /^1\.3\./) {
            push @records, $current if $current ne "";
            $current = $line;
        } elsif ($line =~ /^\s+/) {
            $current .= " $line";
        }
    }
    push @records, $current if $current ne "";
    close $fh;
    return @records;
}

sub string_value {
    my ($raw) = @_;
    return "" unless $raw =~ /STRING:\s*"(.*)"\s*$/s;
    my $value = $1;
    $value =~ s/\\"/"/g;
    return $value;
}

sub normalize_mac {
    my ($mac) = @_;
    $mac = lc($mac // "");
    $mac =~ s/[^0-9a-f]//g;
    return "" unless length($mac) == 12;
    return substr($mac, 0, 4) . "-" . substr($mac, 4, 4) . "-" . substr($mac, 8, 4);
}

sub csv {
    my ($value) = @_;
    $value = "" if !defined $value;
    $value =~ s/\r|\n/ /g;
    if ($value =~ /[",]/) {
        $value =~ s/"/""/g;
        return qq("$value");
    }
    return $value;
}

my %client;
for my $record (sort {
    my ($ai) = $a =~ /^\Q$base\E\.(\d+)/;
    my ($bi) = $b =~ /^\Q$base\E\.(\d+)/;
    ($ai // 0) <=> ($bi // 0);
} records($path)) {
    next unless $record =~ /^\Q$base\E\.\d+\s+=\s+(.+)$/s;
    my $msg = string_value($1);
    next if $msg eq "" || $msg !~ /STAMGR_CLIENT_/;

    if ($msg =~ /STAMGR_CLIENT_OFFLINE: Client\s+([0-9A-Fa-f-]+)/) {
        my $mac = normalize_mac($1);
        $client{$mac}{online} = 0 if $mac ne "";
        next;
    }

    if ($msg =~ /STAMGR_CLIENT_ONLINE: Client\s+([0-9A-Fa-f-]+).*?from BSS\s+([0-9A-Fa-f-]+).*?with SSID\s+(.+?)\s+on AP\s+(.+?)\s+Radio ID\s+(\d+)/) {
        my $mac = normalize_mac($1);
        next if $mac eq "";
        $client{$mac}{online} = 1;
        $client{$mac}{bssid} = normalize_mac($2);
        $client{$mac}{ssid} = $3;
        $client{$mac}{ap} = $4;
        $client{$mac}{radio} = $5;
        next;
    }

    if ($msg =~ /STAMGR_CLIENT_SNOOPING: .*?Client MAC:\s*([0-9A-Fa-f-]+),\s*IP:\s*([0-9.]+).*?Username:\s*([^,]+),\s*AP name:\s*(.+?),\s*Radio ID:\s*(\d+),\s*Channel number:\s*[^,]+,\s*SSID:\s*(.+?),\s*BSSID:\s*([0-9A-Fa-f-]+)/) {
        my $mac = normalize_mac($1);
        next if $mac eq "";
        $client{$mac}{online} = 1;
        $client{$mac}{ip} = $2;
        $client{$mac}{user} = $3;
        $client{$mac}{ap} = $4;
        $client{$mac}{radio} = $5;
        $client{$mac}{ssid} = $6;
        $client{$mac}{bssid} = normalize_mac($7);
        next;
    }
}

for my $mac (sort {
    ($client{$a}{ap} // "") cmp ($client{$b}{ap} // "") || $a cmp $b
} keys %client) {
    next unless $client{$mac}{online};
    my $ap = $client{$mac}{ap} // "";
    next if $ap eq "";
    my $username = $client{$mac}{user} // "";
    $username = "(未认证)" if $username eq "" || $username eq "-NA-";
    my $apid = $client{$mac}{bssid} // "";
    $apid = $ap . "/Radio" . ($client{$mac}{radio} // "") if $apid eq "";

    print join(",", map { csv($_) } (
        $ap,
        $username,
        $apid,
        $mac,
        $client{$mac}{ip} // "",
    )), "\n";
}
H3C_LOG_PERL

    rm -f "$tmp_log"

    if [[ ! -s "$tmp_out" ]]; then
        rm -f "$tmp_out"
        return 1
    fi
    return 0
}

process_ac() {
    local ac_ip="$1"
    local community="$2"
    local tmp_out="$3"
    local vendor="${4:-auto}"

    case "$vendor" in
        huawei|hw|ac6508)
            process_huawei_ac "$ac_ip" "$community" "$tmp_out"
            ;;
        h3c)
            process_h3c_ac "$ac_ip" "$community" "$tmp_out" || process_h3c_log_ac "$ac_ip" "$community" "$tmp_out"
            ;;
        auto|"")
            process_huawei_ac "$ac_ip" "$community" "$tmp_out" || process_h3c_ac "$ac_ip" "$community" "$tmp_out" || process_h3c_log_ac "$ac_ip" "$community" "$tmp_out"
            ;;
        *)
            process_huawei_ac "$ac_ip" "$community" "$tmp_out" || process_h3c_ac "$ac_ip" "$community" "$tmp_out" || process_h3c_log_ac "$ac_ip" "$community" "$tmp_out"
            ;;
    esac
}

areas=$(awk -F '\t' '{print $1}' "$TARGET_WORK_FILE" | sort -u)
for area in $areas; do
    area_dir="${OUTPUT_DIR}/${area}"
    ensure_dir "$area_dir"
    final_output="${area_dir}/${TIMESTAMP}_ac6508_users.csv"
    area_tmp_prefix="${TMP_PREFIX}_${area}"

    while IFS=$'\t' read -r target_area ac_ip community vendor; do
        [[ "$target_area" == "$area" ]] || continue
        [[ -n "$ac_ip" ]] || continue
        while [[ "$(jobs -rp | wc -l)" -ge "$PARALLEL_JOBS" ]]; do
            sleep 0.2
        done
        process_ac "$ac_ip" "$community" "${area_tmp_prefix}_${ac_ip//./_}" "$vendor" &
    done < "$TARGET_WORK_FILE"
    wait

    {
        printf '\xEF\xBB\xBF'
        echo "接入AP名称,用户名,APID,MAC地址,IP地址"
        cat "${area_tmp_prefix}"_* 2>/dev/null | sort -t',' -k1,1 -k4,4
    } > "$final_output"

    total_records=$(count_csv_records "$final_output")
    echo "采集完成: ${area} 共 ${total_records} 条记录，保存至 ${final_output}"
done

cleanup
