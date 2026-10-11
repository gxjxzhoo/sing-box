# ---------- 防火墙放行 / 规则持久化 ----------

# 在 INPUT 链安全插入：目标位置超过「现有规则数+1」时退到末尾，
# 避免空链/短链上 `iptables -I INPUT 3` 报 "Index of insertion too big"
_ipt_ensure() {
    local cmd="$1" pos="$2" cnt
    shift 2
    "$cmd" -C INPUT "$@" 2>/dev/null && return 0
    cnt=$("$cmd" -S INPUT 2>/dev/null | grep -c '^-A INPUT')
    [ "$pos" -gt $((cnt + 1)) ] && pos=$((cnt + 1))
    "$cmd" -I INPUT "$pos" "$@" 2>/dev/null
}

# 持久化 iptables 规则（Alpine / Debian / RHEL）
persist_iptables() {
    command_exists iptables || command_exists ip6tables || return 0
    # ufw / firewalld 在用时由它们自己保存规则，不再额外安装 iptables-persistent（避免冲突）
    if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then return 0; fi
    if command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1; then return 0; fi
    if command_exists rc-service; then
        mkdir -p /etc/iptables
        command_exists iptables && iptables-save > /etc/iptables/rules.v4 2>/dev/null
        command_exists ip6tables && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
        # 用独立服务名，避免覆盖 Alpine 自带的 iptables 服务
        if [ ! -f /etc/init.d/sb-iptables ]; then
            cat > /etc/init.d/sb-iptables << 'IEOF'
#!/sbin/openrc-run
description="restore iptables rules saved by sb"
depend() { need net; }
start() {
    [ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4
    command -v ip6tables >/dev/null 2>&1 && [ -f /etc/iptables/rules.v6 ] && ip6tables-restore < /etc/iptables/rules.v6
    return 0
}
IEOF
            chmod +x /etc/init.d/sb-iptables
            rc-update add sb-iptables default >/dev/null 2>&1 || true
        fi
    elif command_exists netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1
    elif [ -f /etc/debian_version ]; then
        DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent >/dev/null 2>&1 \
            || yellow "请手动安装 iptables-persistent 以持久化防火墙规则"
        command_exists netfilter-persistent && netfilter-persistent save >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        if systemctl list-unit-files 2>/dev/null | grep -q '^iptables\.service'; then
            service iptables save >/dev/null 2>&1
            service ip6tables save >/dev/null 2>&1
        else
            yellow "RHEL 系需安装 iptables-services 才能持久化规则（与 firewalld 二选一）"
        fi
    fi
    return 0
}

# 放行端口，参数形如 443/tcp 8443/udp
allow_port() {
    local has_ufw=0 has_firewalld=0 has_iptables=0 has_ip6tables=0 rule port proto

    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists iptables && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    [ "$has_ufw" -eq 1 ] && ufw --force default allow outgoing >/dev/null 2>&1
    # [v2.6.2] 不再把 firewalld public zone 设为 ACCEPT（等于全放行），也不再改 FORWARD 策略
    if [ "$has_iptables" -eq 1 ]; then
        _ipt_ensure iptables 3 -i lo -j ACCEPT
        _ipt_ensure iptables 4 -p icmp -j ACCEPT
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
    fi
    if [ "$has_ip6tables" -eq 1 ]; then
        _ipt_ensure ip6tables 3 -i lo -j ACCEPT
        _ipt_ensure ip6tables 4 -p ipv6-icmp -j ACCEPT
        ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
    fi

    for rule in "$@"; do
        port=${rule%/*}
        proto=${rule#*/}
        [ "$has_ufw" -eq 1 ] && ufw allow in "${port}/${proto}" >/dev/null 2>&1
        [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
        [ "$has_iptables" -eq 1 ] && _ipt_ensure iptables 4 -p "$proto" --dport "$port" -j ACCEPT
        [ "$has_ip6tables" -eq 1 ] && _ipt_ensure ip6tables 4 -p "$proto" --dport "$port" -j ACCEPT
    done

    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1
    persist_iptables
    return 0
}
