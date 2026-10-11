# ---------- HY2 端口跳跃：规则精确增删（不再 -F 清空整条 PREROUTING 链）----------
HY2_HOP_CONF="${work_dir}/hy2_hop.conf"

# 读取当前跳跃配置：优先 hy2_hop.conf，兼容旧版从节点链接 mport= 参数解析
_hy2_hop_load() {
    HOP_MIN=""; HOP_MAX=""; HOP_PORT=""
    if [ -f "$HY2_HOP_CONF" ]; then
        # shellcheck source=/dev/null
        source "$HY2_HOP_CONF" 2>/dev/null || true
    elif [ -f "$client_dir" ]; then
        local m r
        m=$(grep -m1 '^hysteria2://' "$client_dir" 2>/dev/null | grep -oE 'mport=[0-9]+,[0-9]+-[0-9]+' | head -1)
        if [ -n "$m" ]; then
            HOP_PORT=${m#mport=}; HOP_PORT=${HOP_PORT%%,*}
            r=${m#*,}; HOP_MIN=${r%-*}; HOP_MAX=${r#*-}
        fi
    fi
    [ -n "$HOP_MIN" ] && [ -n "$HOP_MAX" ] && [ -n "$HOP_PORT" ]
}

# 开机恢复：ufw/firewalld 不会保存手动加的 nat 规则，persist_iptables 在它们启用时也会跳过，
# 所以单独装一个开机服务，按 hy2_hop.conf 把 DNAT 规则补回来（-C 检查，已存在则不重复添加）
HY2_HOP_RESTORE="${work_dir}/hy2-hop-restore.sh"
_hy2_hop_boot_enable() {
    cat > "$HY2_HOP_RESTORE" << 'REOF'
#!/bin/sh
f=/etc/sing-box/hy2_hop.conf
[ -f "$f" ] || exit 0
. "$f"
[ -n "$HOP_MIN" ] && [ -n "$HOP_MAX" ] && [ -n "$HOP_PORT" ] || exit 0
for c in iptables ip6tables; do
    command -v "$c" >/dev/null 2>&1 || continue
    "$c" -t nat -C PREROUTING -p udp --dport "${HOP_MIN}:${HOP_MAX}" -j DNAT --to-destination ":${HOP_PORT}" 2>/dev/null \
        || "$c" -t nat -A PREROUTING -p udp --dport "${HOP_MIN}:${HOP_MAX}" -j DNAT --to-destination ":${HOP_PORT}" 2>/dev/null
done
exit 0
REOF
    chmod 700 "$HY2_HOP_RESTORE"
    if command_exists rc-service; then
        cat > /etc/init.d/sb-hy2-hop << 'OEOF'
#!/sbin/openrc-run
description="restore sing-box hysteria2 port hopping rules"
depend() { need net; after firewall iptables ip6tables sb-iptables; }
start() { /etc/sing-box/hy2-hop-restore.sh; return 0; }
OEOF
        chmod +x /etc/init.d/sb-hy2-hop
        rc-update add sb-hy2-hop default >/dev/null 2>&1 || true
    elif command_exists systemctl; then
        cat > /etc/systemd/system/sb-hy2-hop.service << 'SEOF'
[Unit]
Description=Restore sing-box hysteria2 port hopping rules
After=network-online.target ufw.service firewalld.service netfilter-persistent.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/sing-box/hy2-hop-restore.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SEOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable sb-hy2-hop >/dev/null 2>&1 || true
    fi
}
_hy2_hop_boot_disable() {
    if command_exists rc-service; then
        rc-update del sb-hy2-hop default >/dev/null 2>&1 || true
        rm -f /etc/init.d/sb-hy2-hop
    elif command_exists systemctl; then
        systemctl disable sb-hy2-hop >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sb-hy2-hop.service
        systemctl daemon-reload >/dev/null 2>&1
    fi
    rm -f "$HY2_HOP_RESTORE"
}

hy2_hop_del() {
    _hy2_hop_boot_disable
    _hy2_hop_load || { rm -f "$HY2_HOP_CONF"; return 0; }
    local c
    for c in iptables ip6tables; do
        command_exists "$c" || continue
        while "$c" -t nat -D PREROUTING -p udp --dport "${HOP_MIN}:${HOP_MAX}" -j DNAT --to-destination ":${HOP_PORT}" 2>/dev/null; do :; done
    done
    rm -f "$HY2_HOP_CONF"
}

hy2_hop_add() {
    local min="$1" max="$2" port="$3" c
    for c in iptables ip6tables; do
        command_exists "$c" || continue
        "$c" -t nat -C PREROUTING -p udp --dport "${min}:${max}" -j DNAT --to-destination ":${port}" 2>/dev/null \
            || "$c" -t nat -A PREROUTING -p udp --dport "${min}:${max}" -j DNAT --to-destination ":${port}" >/dev/null 2>&1
    done
    printf 'HOP_MIN=%s\nHOP_MAX=%s\nHOP_PORT=%s\n' "$min" "$max" "$port" > "$HY2_HOP_CONF"
    _hy2_hop_boot_enable
}

# HY2 监听端口变更后：把跳跃规则的 DNAT 目标同步到新端口，并更新链接里的 mport
hy2_hop_retarget() {
    local new_port="$1" min max
    _hy2_hop_load || return 0
    min="$HOP_MIN"; max="$HOP_MAX"
    hy2_hop_del
    hy2_hop_add "$min" "$max" "$new_port"
    persist_iptables
    sed -i -E "/^hysteria2:\/\//s/mport=[0-9]+,/mport=${new_port},/" "$client_dir"
}

change_config() {
    # [v2.6.2] 原写法 local x=$(...) 后 $? 恒为 0，"未安装"检查失效
    check_singbox >/dev/null 2>&1
    local singbox_installed=$?
    local singbox_status
    singbox_status=$(check_singbox 2>/dev/null)

    if [ $singbox_installed -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; return
    fi

    clear; echo ""
    green "=== 修改节点配置 ===\n"
    green "sing-box当前状态: $singbox_status\n"
    green "1. 修改端口"
    skyblue "----------------"
    green "2. 修改UUID"
    skyblue "----------------"
    green "3. 修改Reality伪装域名"
    skyblue "----------------"
    green "4. 添加hysteria2端口跳跃"
    skyblue "----------------"
    green "5. 删除hysteria2端口跳跃"
    skyblue "----------------"
    green "6. 修改vmess-argo优选域名"
    skyblue "----------------"
    green "7. 修改节点ip为ipv4"
    skyblue "----------------"
    green "8. 修改节点ip为ipv6"
    skyblue "----------------"
    green "9. 修改节点前缀名称"
    skyblue "----------------"
    purple "0. 返回主菜单"
    skyblue "----------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            echo ""
            green "1. 修改vless-reality端口"
            skyblue "----------------"
            green "2. 修改hysteria2端口"
            skyblue "----------------"
            green "3. 修改tuic端口"
            skyblue "----------------"
            green "4. 修改Argo对外端口（Nginx入口，三协议共用）"
            skyblue "----------------"
            green "5. 修改 AnyTLS 端口"
            skyblue "----------------"
            purple "0. 返回上一级"
            skyblue "----------------"
            reading "请输入选择: " choice
            local inbounds_file="${conf_dir}/inbounds.json"
            # [优化] 下面 1/2/3/5 四个端口修改分支，原来各自手写了一遍
            # "输入→随机兜底→范围校验→port_really_in_use占用检测→重试"的循环，
            # 脚本自己已经定义了完全等价的通用函数 read_available_port，这里改
            # 为直接复用。注意：read_available_port 的随机端口范围是
            # 10000-65000（原手写循环是 2000-65000），范围收窄但依然是安全的
            # 非特权高位端口，不影响功能。
            case "${choice}" in
                1)
                    read_available_port "\n请输入vless-reality端口 (回车跳过将使用随机端口): " new_port
                    # 仅修改 tag=vless-reality，避免误改 vless-ws
                    jq --argjson port "$new_port" \
                        '(.inbounds[] | select(.tag == "vless-reality")).listen_port = $port' \
                        "$inbounds_file" > "${inbounds_file}.tmp"
                    if ! safe_apply_conf "$inbounds_file" "${inbounds_file}.tmp" "vless-reality 端口"; then
                        return 1
                    fi
                    allow_port $new_port/tcp > /dev/null 2>&1
                    restart_singbox
                    # 仅更新 reality 直连节点端口（排除 argo 的 vless-ws）；用端口后紧跟 ? 定位，兼容 IPv6 主机地址
                    sed -i -E "/vless:\/\/.*flow=xtls-rprx-vision/ s/:[0-9]+\?/:${new_port}?/" "$client_dir"
                    refresh_sub
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nvless-reality端口已修改成：${purple}$new_port${re}\n"
                    ;;
                2)
                    read_available_port "\n请输入hysteria2端口 (回车跳过将使用随机端口): " new_port
                    jq --argjson port "$new_port" \
                        '(.inbounds[] | select(.tag == "hysteria2")).listen_port = $port' \
                        "$inbounds_file" > "${inbounds_file}.tmp"
                    if ! safe_apply_conf "$inbounds_file" "${inbounds_file}.tmp" "hysteria2 端口"; then
                        return 1
                    fi
                    allow_port $new_port/udp > /dev/null 2>&1
                    restart_singbox
                    # 用端口后紧跟 /? 定位，兼容 IPv6 主机地址
                    sed -i -E "/hysteria2:\/\// s#:[0-9]+/\?#:${new_port}/?#" "$client_dir"
                    hy2_hop_retarget "$new_port"
                    refresh_sub
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nhysteria2端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                3)
                    read_available_port "\n请输入tuic端口 (回车跳过将使用随机端口): " new_port
                    jq --argjson port "$new_port" \
                        '(.inbounds[] | select(.tag == "tuic")).listen_port = $port' \
                        "$inbounds_file" > "${inbounds_file}.tmp"
                    if ! safe_apply_conf "$inbounds_file" "${inbounds_file}.tmp" "tuic 端口"; then
                        return 1
                    fi
                    allow_port $new_port/udp > /dev/null 2>&1
                    restart_singbox
                    # 用端口后紧跟 ? 定位，兼容 IPv6 主机地址
                    sed -i -E "/tuic:\/\// s/:[0-9]+\?/:${new_port}?/" "$client_dir"
                    refresh_sub
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\ntuic端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                4)
                    # Argo 对外端口 = Nginx 监听端口（内部三个协议端口不变）
                    read_available_port "\n请输入Argo对外端口 (当前Nginx入口, 回车跳过将使用随机端口): " new_port
                    allow_port $new_port/tcp > /dev/null 2>&1
                    export ARGO_PORT=$new_port
                    save_sub_conf    # [v2.6.2] 持久化，新会话/重新生成配置时不再退回 8001
                    if [ -f /etc/nginx/conf.d/argo-ws.conf ]; then
                        # 重新生成：内部 WS 端口以 inbounds.json 实际监听端口为准，不会错位
                        write_argo_ws_conf
                        nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1 || restart_nginx >/dev/null 2>&1
                    fi
                    # 同步到固定配置（若有）并重写 argo 启动脚本
                    if [ -f "${work_dir}/argo_fixed.conf" ]; then
                        sed -i "s/^ARGO_PORT=.*/ARGO_PORT=\"${new_port}\"/" "${work_dir}/argo_fixed.conf"
                    fi
                    rewrite_argo_service
                    restart_argo
                    sleep 2
                    # 仅临时隧道需要重新拉取域名
                    if [ -f "${work_dir}/argo-start.sh" ] && grep -q -- '--url http://localhost' "${work_dir}/argo-start.sh" 2>/dev/null; then
                        get_quick_tunnel && change_argo_domain
                    fi
                    green "\nArgo对外端口已修改为：${purple}${new_port}${re}（三个协议仍共用此入口）\n"
                    ;;
                5)
                    # AnyTLS
                    if ! jq -e '.inbounds[] | select(.tag=="anytls")' "$inbounds_file" >/dev/null 2>&1; then
                        red "当前未安装 AnyTLS 协议（可能已选择跳过直连）"
                        return 1
                    fi
                    read_available_port "\n请输入 AnyTLS 端口 (回车随机): " new_port
                    jq --argjson port "$new_port" \
                        '(.inbounds[] | select(.tag == "anytls")).listen_port = $port' \
                        "$inbounds_file" > "${inbounds_file}.tmp"
                    if ! safe_apply_conf "$inbounds_file" "${inbounds_file}.tmp" "AnyTLS 端口"; then
                        return 1
                    fi
                    allow_port $new_port/tcp > /dev/null 2>&1
                    restart_singbox
                    # 仅更新 anytls 节点，兼容 IPv6
                    sed -i -E "/^anytls:\/\// s/:[0-9]+\?/:${new_port}?/" "$client_dir"
                    refresh_sub
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nAnyTLS 端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                0) change_config ;;
                *) red "无效的选项，请输入 1 到 5" ;;
            esac
            ;;
        2)
            reading "\n请输入新的UUID(直接回车随机生成UUID): " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            if ! echo "$new_uuid" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
                red "UUID 格式无效"; return 1
            fi
            # Socks5 用户名/密码保持与添加时一致：前8位 / 后12位，避免整段 UUID 污染密码
            local sk_user sk_pass
            sk_user=$(printf '%s' "${new_uuid:0:8}")
            sk_pass=$(printf '%s' "${new_uuid: -12}")
            jq --arg uuid "$new_uuid" --arg sk_user "$sk_user" --arg sk_pass "$sk_pass" '
                (.inbounds[] | select(.users != null) | .users[] | select(.uuid != null).uuid) = $uuid |
                (.inbounds[] | select(.tag != "socks5-in" and .users != null) | .users[] | select(.password != null).password) = $uuid |
                (.inbounds[] | select(.tag == "socks5-in") | .users[0].username) = $sk_user |
                (.inbounds[] | select(.tag == "socks5-in") | .users[0].password) = $sk_pass
            ' "${conf_dir}/inbounds.json" > "${conf_dir}/inbounds.json.tmp"
            if ! safe_apply_conf "${conf_dir}/inbounds.json" "${conf_dir}/inbounds.json.tmp" "UUID"; then
                return 1
            fi
            restart_singbox
            sed -i -E 's/(vless:\/\/|hysteria2:\/\/|anytls:\/\/|trojan:\/\/)[^@]*(@.*)/\1'"$new_uuid"'\2/' $client_dir
            sed -i -E "s#tuic://[0-9a-fA-F-]{36}:[0-9a-fA-F-]{36}@#tuic://$new_uuid:$new_uuid@#g" $client_dir
            # 同步更新 socks:// 订阅链接中的账号密码（base64(user:pass)）
            if grep -q '^socks://' "$client_dir" 2>/dev/null; then
                local sk_auth sk_b64
                sk_auth=$(printf '%s:%s' "$sk_user" "$sk_pass")
                sk_b64=$(printf '%s' "$sk_auth" | base64 -w0 2>/dev/null || printf '%s' "$sk_auth" | base64 | tr -d '\n')
                sed -i -E "s#socks://[^@]+@#socks://${sk_b64}@#g" "$client_dir"
            fi
            # 更新全部 vmess 的 id，保留 ps/add/port/host/sni 等
            update_all_vmess --arg id "$new_uuid" '.id = $id' >/dev/null
            refresh_sub
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nUUID已修改为：${purple}${new_uuid}${re}\n"
            if jq -e '.inbounds[] | select(.tag == "socks5-in")' "${conf_dir}/inbounds.json" >/dev/null 2>&1; then
                green "Socks5 用户名/密码已同步为 UUID 前8位/后12位，并已更新订阅链接\n"
            fi
            ;;
        3)
            clear
            green "\n1. www.joom.com\n\n2. www.stengg.com\n\n3. www.wedgehr.com\n\n4. www.cerebrium.ai\n\n5. www.nazhumi.com\n"
            reading "\n请输入新的Reality伪装域名(可自定义输入,回车留空将使用默认1): " new_sni
            case "$new_sni" in
                ""|"1") new_sni="www.joom.com" ;;
                "2") new_sni="www.stengg.com" ;;
                "3") new_sni="www.wedgehr.com" ;;
                "4") new_sni="www.cerebrium.ai" ;;
                "5") new_sni="www.nazhumi.com" ;;
            esac
            if ! [[ "$new_sni" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
                red "域名格式无效"; return 1
            fi
            jq --arg sni "$new_sni" \
               '(.inbounds[] | select(.tag == "vless-reality") | .tls.server_name) = $sni |
                (.inbounds[] | select(.tag == "vless-reality") | .tls.reality.handshake.server) = $sni' \
               "${conf_dir}/inbounds.json" > "${conf_dir}/inbounds.json.tmp"
            if ! safe_apply_conf "${conf_dir}/inbounds.json" "${conf_dir}/inbounds.json.tmp" "Reality SNI"; then
                return 1
            fi
            restart_singbox
            # 仅更新 Reality 节点的 sni
            sed -i -E "/flow=xtls-rprx-vision/s/(sni=)[^&]*/\1${new_sni}/" $client_dir
            refresh_sub
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nReality sni已修改为：${purple}${new_sni}${re}\n"
            ;;
        4)
            if ! command_exists iptables; then
                red "未检测到 iptables，无法设置端口跳跃（请先安装 iptables）"; return 1
            fi
            purple "端口跳跃需确保跳跃区间的端口没有被占用\n"
            reading "请输入跳跃起始端口 (回车跳过将使用随机端口): " min_port
            [ -z "$min_port" ] && min_port=$(shuf -i 50000-65000 -n 1)
            if ! [[ "$min_port" =~ ^[0-9]+$ ]] || [ "$min_port" -lt 1024 ] || [ "$min_port" -gt 65534 ]; then
                red "起始端口无效：需为 1024-65534 的数字"; return 1
            fi
            yellow "你的起始端口为：$min_port"
            reading "\n请输入跳跃结束端口 (需大于起始端口，回车=起始+100): " max_port
            if [ -z "$max_port" ]; then
                max_port=$((min_port + 100)); [ "$max_port" -gt 65535 ] && max_port=65535
            fi
            yellow "你的结束端口为：$max_port\n"
            if ! [[ "$max_port" =~ ^[0-9]+$ ]] || [ "$max_port" -gt 65535 ] || [ "$min_port" -ge "$max_port" ]; then
                red "端口范围无效：结束端口需为不超过 65535 的数字，且大于起始端口"; return 1
            fi
            local listen_port
            listen_port=$(jq -r '.inbounds[] | select(.type == "hysteria2").listen_port' "${conf_dir}/inbounds.json" 2>/dev/null | head -1)
            if ! [[ "$listen_port" =~ ^[0-9]+$ ]]; then
                red "未找到 hysteria2 入站（可能已选择跳过直连）"; return 1
            fi
            # 区间不能盖住本脚本任何 UDP 入站端口（含 HY2 自身、TUIC），否则这些端口的流量会被 DNAT 走
            local _p _clash=""
            for _p in $(jq -r '.inbounds[] | select(.listen_port != null) | .listen_port' "${conf_dir}/inbounds.json" 2>/dev/null); do
                if [ "$_p" -ge "$min_port" ] && [ "$_p" -le "$max_port" ]; then _clash="${_clash} ${_p}"; fi
            done
            if [ -n "$_clash" ]; then
                red "跳跃区间 ${min_port}-${max_port} 包含已用入站端口:${_clash}，请换一个区间"; return 1
            fi
            hy2_hop_del
            hy2_hop_add "$min_port" "$max_port" "$listen_port"
            persist_iptables
            # 直接在原链接上改 mport，保留原有 sni/节点名等参数
            sed -i -E '/^hysteria2:\/\//{s/&mport=[^#&]*//; s/&obfs=none//}' "$client_dir"
            sed -i -E "/^hysteria2:\/\//s|#|\&mport=${listen_port},${min_port}-${max_port}#|" "$client_dir"
            refresh_sub
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nhysteria2端口跳跃已开启：${purple}$min_port-$max_port${re}\n"
            ;;
        5)
            hy2_hop_del
            persist_iptables
            sed -i -E '/^hysteria2:\/\//{s/&mport=[^#&]*//; s/&obfs=none//}' "$client_dir"
            refresh_sub
            green "\n端口跳跃已删除\n"
            ;;
        6) change_cfip ;;
        7)
            local new_ipv4
            [ -f "$client_dir" ] || {
                red "\n错误: $client_dir 不存在\n"
                return 1
            }
            new_ipv4=$(curl -4 -sm 2 ip.sb)
            if ! printf '%s' "$new_ipv4" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
                red "\n错误: 获取 IPv4 失败: $new_ipv4\n"
                return 1
            fi
            if curl -4 -sm 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
                red "\n当前服务器的ipv4: $new_ipv4 为warp ip,无法作为直连节点使用\n"
                return 1
            fi
            if grep -Eq '^(vless|hysteria2|tuic|anytls|socks|ss)://[^@]+@\[[0-9a-fA-F:]+\]' "$client_dir"; then
                # 替换 @ 后的 IPv6 主机
                sed -i -E "/^(vless|hysteria2|tuic|anytls|socks|ss):\/\// s#@\[[0-9a-fA-F:]+\]#@${new_ipv4}#g" "$client_dir"
                # 同步直连节点 host=（可选 vless-ws 依赖 Host 头；仅改 path=/vless-ws 行，不动 argo）
                sed -i -E "/path=%2Fvless-ws|path=\/vless-ws/ s#(host=)\[[0-9a-fA-F:]+\]#\1${new_ipv4}#g" "$client_dir"
                green "\n已将 IPv6 修改为 IPv4: $new_ipv4 可复制以下节点或更新订阅\n"
                check_nodes
            else
                yellow "\n当前已是ipv4, 无需切换\n" && return 0
            fi
            refresh_sub
           ;;
        8)
            local new_ipv6
            [ -f "$client_dir" ] || {
                red "\n错误: $client_dir 不存在\n"
                return 1
            }
            new_ipv6=$(curl -6 -sm 3 ip.sb)
            if ! printf '%s' "$new_ipv6" | grep -Eq '^[0-9a-fA-F:]+$'; then
                red "\n当前服务器没有可用的ipv6\n"
                return 1
            fi
            if curl -6 -sm 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
                red "\n当前服务器的ipv6 $new_ipv6 为warp ip,无法作为直连节点使用\n"
                return 1
            fi
            if grep -Eq '^(vless|hysteria2|tuic|anytls|socks|ss)://[^@]+@([0-9]{1,3}\.){3}[0-9]{1,3}' "$client_dir"; then
                sed -i -E "/^(vless|hysteria2|tuic|anytls|socks|ss):\/\// s#@(([0-9]{1,3}\.){3}[0-9]{1,3})#@[${new_ipv6}]#g" "$client_dir"
                # 同步直连 vless-ws 的 host= 为 [ipv6]
                sed -i -E "/path=%2Fvless-ws|path=\/vless-ws/ s#(host=)([0-9]{1,3}\.){3}[0-9]{1,3}#\1[${new_ipv6}]#g" "$client_dir"
                sed -i -E "/path=%2Fvless-ws|path=\/vless-ws/ s#(host=)\[[0-9a-fA-F:]+\]#\1[${new_ipv6}]#g" "$client_dir"
                green "\n已将 IPv4 修改为 IPv6: [${new_ipv6}] 可复制以下节点或更新订阅\n"
                check_nodes
            else
                yellow "\n当前已是ipv6, 无需切换\n" && return 0
            fi
            refresh_sub
           ;;
        9)
            # 修改节点前缀名称
            reading "\n请输入新的节点前缀名称 (回车清空前缀，改用服务商名称): " new_prefix
            new_prefix="$(sanitize_prefix "$new_prefix")"
            export node_prefix="$new_prefix"
            save_sub_conf    # [v2.6.2] 持久化前缀，新会话不再丢失

            if [ -z "$new_prefix" ]; then
                prefix_display="(使用服务商名称)"
            else
                prefix_display="$new_prefix"
            fi
            green "节点前缀已设置为: ${purple}${prefix_display}${re}"

            # 重新生成节点名称
            if [ ! -f "$client_dir" ]; then
                red "节点文件不存在"
                return 1
            fi

            isp=$(get_isp "node")

            # 自定义前缀优先；有自定义时不输出服务商
            prefix="$(sanitize_prefix "${node_prefix:-$isp}")"
            local pfx
            pfx=$(sed_escape_repl "$prefix")

            # 更新各协议节点备注（顺序：先区分 argo / 直连 ws，再处理 reality，避免互相覆盖）
            sed -i -E "s|^(hysteria2://[^#]+)#.*|\1#${pfx}-hysteria2|" "$client_dir"
            sed -i -E "s|^(tuic://[^#]+)#.*|\1#${pfx}-tuic|" "$client_dir"
            sed -i -E "s|^(trojan://[^#]+)#.*|\1#${pfx}-argo-trojan|" "$client_dir"
            sed -i -E "s|^(anytls://[^#]+)#.*|\1#${pfx}-anytls|" "$client_dir"
            sed -i -E "s|^(socks://[^#]+)#.*|\1#${pfx}-socks5|" "$client_dir"
            sed -i -E "s|^(ss://[^#]+)#.*|\1#${pfx}-ss2022|" "$client_dir"

            # vless-ws argo 隧道
            sed -i -E "s|^(vless://[^#]*path=%2Fvless-argo[^#]*)#.*|\1#${pfx}-argo-vless|" "$client_dir"
            sed -i -E "s|^(vless://[^#]*path=/vless-argo[^#]*)#.*|\1#${pfx}-argo-vless|" "$client_dir"

            # vless-ws 直连（无 TLS，path 为 /vless-ws，非 argo）
            sed -i -E "s|^(vless://[^#]*path=%2Fvless-ws[^#]*)#.*|\1#${pfx}-vless-ws|" "$client_dir"
            sed -i -E "s|^(vless://[^#]*path=/vless-ws[^#]*)#.*|\1#${pfx}-vless-ws|" "$client_dir"

            # Reality（含 flow=xtls-rprx-vision）
            sed -i -E "s|^(vless://[^#]*flow=xtls-rprx-vision[^#]*)#.*|\1#${pfx}-vless-reality|" "$client_dir"

            # 更新全部 vmess 的 ps 字段
            update_all_vmess --arg ps "${prefix}-argo-vmess" '.ps = $ps' >/dev/null

            refresh_sub
            green "\n节点前缀已更新，可复制以下节点或更新订阅\n"
            while IFS= read -r line; do yellow "$line"; done < "$client_dir"
            ;;
        0) return ;;
        *)
            # [修复] 原来这里什么都不做，case结束后函数静默返回，
            # 主循环会 pause 然后重画主菜单——等于"输入错误直接跳回主菜单"，
            # 和 setup_telegram/manage_protocols 等"输入错误留在本菜单重试"
            # 的行为不一致。这里改为重新显示本菜单，保持一致。
            red "无效的选项！\n"; sleep 1; change_config; return
            ;;
    esac
}

# singbox 管理（优化版：循环 + 状态刷新）
