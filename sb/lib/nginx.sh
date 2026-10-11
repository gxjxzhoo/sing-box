# ---------- [v2.6.0] nginx.conf / mime.types 备份只保留最近一份 ----------
_prune_nginx_backup() {
    local pattern="$1"   # 例如 /etc/nginx/nginx.conf.bak.sb.*
    # shellcheck disable=SC2086
    ls -1t ${pattern} 2>/dev/null | tail -n +2 | xargs -r rm -f
}

# 内部 WS 端口：以 inbounds.json 里的实际监听端口为准（改 Argo 对外端口后也不会错位）；
# 取不到才退回 ARGO_PORT+10/11/12
_argo_inner_ports() {
    local f="${conf_dir}/inbounds.json" t p out="" off=10
    for t in vmess-ws vless-ws trojan-ws; do
        p=""
        [ -f "$f" ] && command_exists jq && \
            p=$(jq -r --arg t "$t" '.inbounds[] | select(.tag==$t) | .listen_port // empty' "$f" 2>/dev/null | head -1)
        [[ "$p" =~ ^[0-9]+$ ]] || p=$((ARGO_PORT + off))
        out="${out}${p} "
        off=$((off + 1))
    done
    echo "$out"
}

# 写 Argo 入口 nginx 配置（路径分流 + 可选 /s/<token> 订阅）
write_argo_ws_conf() {
    local vmess_ws_port vless_ws_port trojan_ws_port
    read -r vmess_ws_port vless_ws_port trojan_ws_port <<< "$(_argo_inner_ports)"
    ensure_sub_token
    local sub_block=""
    if [ "${SUB_ENABLED:-1}" = "1" ]; then
        sub_block="    # Base64 订阅（客户端导入）
    location = /s/${SUB_TOKEN} {
        default_type text/plain;
        charset utf-8;
        alias ${work_dir}/sub.txt;
        add_header Cache-Control \"no-store\";
        add_header Access-Control-Allow-Origin *;
    }
    # 明文节点列表
    location = /s/${SUB_TOKEN}/raw {
        default_type text/plain;
        charset utf-8;
        alias ${work_dir}/url.txt;
        add_header Cache-Control \"no-store\";
        add_header Access-Control-Allow-Origin *;
    }
"
    fi
    mkdir -p /etc/nginx/conf.d
    cat > /etc/nginx/conf.d/argo-ws.conf << EOF
server {
    listen ${ARGO_PORT};
    $(_nginx_listen6 "${ARGO_PORT}")
    server_name _;

    location /vmess-argo {
        proxy_pass http://127.0.0.1:${vmess_ws_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location /vless-argo {
        proxy_pass http://127.0.0.1:${vless_ws_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location /trojan-argo {
        proxy_pass http://127.0.0.1:${trojan_ws_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

${sub_block}
    location / { return 404; }
}
EOF
}

# 仅在 nginx -t 失败（或主配置没 include conf.d）时才重写主配置；写之前先留存文件
_sb_rewrite_nginx_main() {
    local nginx_user
    nginx_user=$(_resolve_nginx_user)
    if [ -f /etc/nginx/mime.types ]; then
        cp -f /etc/nginx/mime.types "/etc/nginx/mime.types.bak.sb.$(date +%s)" 2>/dev/null || true
        _prune_nginx_backup "/etc/nginx/mime.types.bak.sb.*"
    fi
    if [ -f /etc/nginx/nginx.conf ]; then
        cp -f /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.sb.$(date +%s)" 2>/dev/null || true
        _prune_nginx_backup "/etc/nginx/nginx.conf.bak.sb.*"
    fi
    _write_safe_mime_types
    cat > /etc/nginx/nginx.conf << EOF
user ${nginx_user};
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    include /etc/nginx/conf.d/*.conf;
}
EOF
}

# 还原安装前的 nginx 主配置（若脚本改过）
_sb_restore_nginx_main() {
    if [ -f /etc/nginx/nginx.conf.sb-orig ]; then
        cp -f /etc/nginx/nginx.conf.sb-orig /etc/nginx/nginx.conf 2>/dev/null && rm -f /etc/nginx/nginx.conf.sb-orig
    fi
}

# Nginx：Argo 隧道路径分流 + /s/<token> 订阅；独立订阅见 sb-sub.conf
# [v2.6.2] 默认不再覆盖用户的 nginx.conf / mime.types、不再删 sites-enabled/default、不再 pkill 全部 nginx；
# 只有 nginx -t 失败时才重写主配置（并保留原始文件）
add_nginx_conf() {
    if ! command_exists nginx; then
        red "nginx 未安装，无法配置 Argo 隧道路径分流"
        return 1
    fi

    mkdir -p /etc/nginx/conf.d /var/log/nginx /run /var/lib/nginx /var/cache/nginx
    rm -f /etc/nginx/conf.d/sing-box.conf
    if [ -f /etc/nginx/nginx.conf ] && [ ! -f /etc/nginx/nginx.conf.sb-orig ]; then
        cp -p /etc/nginx/nginx.conf /etc/nginx/nginx.conf.sb-orig 2>/dev/null || true
    fi

    write_argo_ws_conf
    write_sub_nginx_conf

    local nginx_test_out nginx_test_rc
    _sb_nginx_check() {
        nginx_test_out=$(nginx -t 2>&1)
        nginx_test_rc=$?
        if [ $nginx_test_rc -eq 0 ] && ! grep -qE 'include[[:space:]]+[^;]*conf\.d/\*\.conf' /etc/nginx/nginx.conf 2>/dev/null; then
            nginx_test_out="nginx.conf 没有 include conf.d/*.conf"
            nginx_test_rc=1
        fi
    }
    _sb_nginx_check

    if [ $nginx_test_rc -ne 0 ]; then
        yellow "nginx 配置检测未通过，重写主配置（原始文件已备份）..."
        echo "$nginx_test_out" | while IFS= read -r line; do red "  $line"; done
        _sb_rewrite_nginx_main
        _sb_nginx_check
    fi

    if [ $nginx_test_rc -ne 0 ]; then
        yellow "仍失败，尝试修复 nginx 包文件后重试..."
        if command_exists apt; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall nginx-common nginx 2>/dev/null || \
            DEBIAN_FRONTEND=noninteractive apt-get install -y nginx 2>/dev/null || true
        elif command_exists dnf; then
            dnf reinstall -y nginx 2>/dev/null || dnf install -y nginx 2>/dev/null || true
        elif command_exists yum; then
            yum reinstall -y nginx 2>/dev/null || yum install -y nginx 2>/dev/null || true
        elif command_exists apk; then
            apk add --no-cache nginx 2>/dev/null || true
        fi
        _sb_rewrite_nginx_main
        _sb_nginx_check
    fi

    if [ $nginx_test_rc -ne 0 ]; then
        red "nginx 配置检测仍失败："
        echo "$nginx_test_out" | while IFS= read -r line; do red "  $line"; done
        red "请手动执行并反馈完整输出: nginx -t ; ls -la /etc/nginx/ ; head -20 /etc/nginx/nginx.conf"
        return 1
    fi

    green "nginx -t 检测通过"

    if _nginx_start; then
        return 0
    fi
    red "nginx 启动失败。请执行: nginx -t ; ss -lntp | grep -E \":${ARGO_PORT:-8001} \" ; rc-service nginx status 2>/dev/null || systemctl status nginx"
    return 1
}

_resolve_nginx_user() {
    local u
    for u in nginx www-data www nobody; do
        if id "$u" >/dev/null 2>&1; then
            printf '%s' "$u"
            return 0
        fi
    done
    printf '%s' "root"
}

# 兼容旧调用名（其它位置可能仍引用）
_write_safe_mime_types() {
    cat > /etc/nginx/mime.types << 'MIMEOF'
types {
    text/html                             html htm shtml;
    text/css                              css;
    text/xml                              xml;
    image/gif                             gif;
    image/jpeg                            jpeg jpg;
    application/javascript                js;
    application/json                      json;
    application/octet-stream              bin exe dmg;
    application/pdf                       pdf;
    image/png                             png;
    image/svg+xml                         svg svgz;
    image/webp                            webp;
    image/x-icon                          ico;
    text/plain                            txt;
}
MIMEOF
}
_ensure_nginx_ready() {
    mkdir -p /etc/nginx/conf.d /var/log/nginx /run
    _write_safe_mime_types
}
_fix_nginx_user_directive() { :; }
_write_minimal_nginx_conf() { :; }

# 从已安装配置中获取UUID
# [优化] 原实现按 .type == "vless" 模糊匹配，若同时存在
# vless-reality / vless-ws(argo) / vless-ws-direct 三个 inbound，
# jq 会把三条 UUID 都选出来，最终靠 head -1 只取数组里排在前面的一条，
# 一旦某个 inbound 的 UUID 被单独改过就会取错。
# 这里改为按明确的 tag 优先级依次尝试，取不到才降级到按 type 兜底。
get_current_uuid() {
    local inbounds_file="${conf_dir}/inbounds.json"
    [ -f "$inbounds_file" ] || return 0
    local uuid tag
    for tag in vless-reality vmess-ws vless-ws vless-ws-direct trojan-ws; do
        uuid=$(jq -r --arg tag "$tag" \
            '.inbounds[] | select(.tag == $tag) | .users[0].uuid // .users[0].password // empty' \
            "$inbounds_file" 2>/dev/null | head -1)
        [ -n "$uuid" ] && { echo "$uuid"; return 0; }
    done
    # 兜底：按 type 模糊匹配（旧逻辑，仅在上面全部找不到时使用）
    uuid=$(jq -r '.inbounds[] | select(.type == "vless") | .users[0].uuid // empty' "$inbounds_file" 2>/dev/null | head -1)
    [ -z "$uuid" ] && uuid=$(jq -r '.inbounds[] | select(.type == "vmess") | .users[0].uuid // empty' "$inbounds_file" 2>/dev/null | head -1)
    [ -z "$uuid" ] && uuid=$(jq -r '.inbounds[] | select(.type == "hysteria2") | .users[0].password // empty' "$inbounds_file" 2>/dev/null | head -1)
    echo "$uuid"
}

# 通用服务管理函数
# 通用服务管理函数（已修复状态检测 + 强制清理残留进程）

# ---------- Nginx 启停（Alpine OpenRC / systemd / 二进制统一）----------
_nginx_is_running() {
    # 以 master 进程为准，避免 pgrep 路径误匹配
    pgrep -f 'nginx: master process' >/dev/null 2>&1 && return 0
    pgrep -x nginx >/dev/null 2>&1 && return 0
    return 1
}

_nginx_stop_all() {
    # 先走服务管理器，再清理可能由「nginx 二进制直启」留下的进程
    if command_exists rc-service; then
        rc-service nginx stop >/dev/null 2>&1 || true
    elif command_exists systemctl; then
        systemctl stop nginx >/dev/null 2>&1 || true
    fi
    if command_exists nginx; then
        nginx -s stop >/dev/null 2>&1 || true
        nginx -s quit >/dev/null 2>&1 || true
    fi
    sleep 0.5
    if _nginx_is_running; then
        pkill -15 -f 'nginx: master process' 2>/dev/null || true
        pkill -15 -x nginx 2>/dev/null || true
        sleep 0.8
    fi
    if _nginx_is_running; then
        pkill -9 -f 'nginx: master process' 2>/dev/null || true
        pkill -9 -x nginx 2>/dev/null || true
        sleep 0.3
    fi
    # 不再用 return 码表示失败，由调用方检查
    return 0
}

_nginx_who_holds_port() {
    local p="${1:-}"
    [ -z "$p" ] && return 0
    if command_exists ss; then
        ss -lntp 2>/dev/null | grep -E ":${p}\\b" || true
    elif command_exists lsof; then
        lsof -i ":${p}" -sTCP:LISTEN 2>/dev/null || true
    fi
}

_nginx_start() {
    if ! command_exists nginx; then
        red "nginx 未安装"
        return 1
    fi
    if ! nginx -t >/dev/null 2>&1; then
        red "nginx -t 失败，拒绝启动"
        nginx -t
        return 1
    fi

    # 若已在跑且可响应，视为成功
    if _nginx_is_running; then
        if nginx -s reload >/dev/null 2>&1; then
            green "nginx 已在运行（已 reload）"
            return 0
        fi
        # reload 失败则彻底停掉再启
        _nginx_stop_all
    fi

    local port="${ARGO_PORT:-}"
    if [ -z "$port" ] && [ -f /etc/nginx/conf.d/argo-ws.conf ]; then
        port=$(grep -oE 'listen[[:space:]]+[0-9]+' /etc/nginx/conf.d/argo-ws.conf 2>/dev/null | head -1 | awk '{print $2}')
    fi
    port="${port:-8001}"

    # 启动前确认端口空闲（排除将由本进程占用的情况：已无 nginx）
    if command_exists ss && ss -lntp 2>/dev/null | grep -qE ":${port}\\b"; then
        yellow "端口 ${port} 仍被占用，尝试释放 nginx 后重试..."
        _nginx_stop_all
        sleep 0.5
        if ss -lntp 2>/dev/null | grep -qE ":${port}\\b"; then
            red "端口 ${port} 仍被占用，占用进程如下："
            _nginx_who_holds_port "$port" | while IFS= read -r l; do red "  $l"; done
            return 1
        fi
    fi

    local started=0
    if command_exists rc-service; then
        # Alpine：优先 OpenRC，避免「二进制直启」与 rc-service 双实例抢端口
        rc-update add nginx default >/dev/null 2>&1 || true
        if rc-service nginx start >/run/sb-nginx-start.err 2>&1; then
            sleep 1
            if rc-service nginx status 2>/dev/null | grep -q started && _nginx_is_running; then
                started=1
                green "nginx 服务已启动 (OpenRC)"
            fi
        fi
    elif command_exists systemctl; then
        systemctl reset-failed nginx 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable nginx 2>/dev/null || true
        if systemctl start nginx >/run/sb-nginx-start.err 2>&1; then
            sleep 1
            if systemctl is-active --quiet nginx 2>/dev/null; then
                started=1
                green "nginx 服务已启动 (systemctl)"
            fi
        fi
    fi

    if [ "$started" -eq 0 ]; then
        # 回退二进制直启（仅当服务管理器不可用或失败且端口已空闲）
        _nginx_stop_all
        if nginx >/run/sb-nginx-bin.err 2>&1; then
            sleep 0.5
            if _nginx_is_running; then
                started=1
                green "nginx 已通过二进制直接启动"
            fi
        fi
        [ -s /run/sb-nginx-bin.err ] && grep -q . /run/sb-nginx-bin.err && \
            while IFS= read -r l; do [ -n "$l" ] && red "$l"; done < /run/sb-nginx-bin.err
    fi

    if [ "$started" -eq 1 ]; then
        return 0
    fi
    [ -s /run/sb-nginx-start.err ] && while IFS= read -r l; do [ -n "$l" ] && red "$l"; done < /run/sb-nginx-start.err
    return 1
}

# 服务状态（不依赖带颜色的文本，避免 "not running" 被 *running* 误匹配）
# 输出: running | stopped | missing
_svc_state() {
    local rc
    if [ "$1" = "nginx" ]; then
        check_nginx >/dev/null 2>&1; rc=$?
    else
        check_service "$1" "$2" >/dev/null 2>&1; rc=$?
    fi
    case "$rc" in
        0) echo running ;;
        2) echo missing ;;
        *) echo stopped ;;
    esac
}

manage_service() {
    local service_name="$1"
    local action="$2"

    if [ -z "$service_name" ] || [ -z "$action" ]; then
        red "缺少服务名或操作参数\n"
        return 1
    fi

    # 根据服务名确定检测文件
    local service_file=""
    case "$service_name" in
        "sing-box")
            service_file="${work_dir}/${server_name}"
            ;;
        "argo")
            service_file="${work_dir}/argo"
            ;;
        "nginx")
            service_file="$(command -v nginx 2>/dev/null)"
            ;;
        *)
            service_file=""
            ;;
    esac

    mkdir -p /run 2>/dev/null || true
    local status
    status=$(_svc_state "$service_name" "$service_file")

    case "$action" in
        "start")
            if [ "$status" = "running" ]; then
                yellow "${service_name} 已在运行中\n"
                return 0
            fi
            if [ "$status" = "missing" ]; then
                yellow "${service_name} 尚未安装！\n"
                return 1
            fi

            yellow "正在启动 ${service_name} 服务...\n"
            if [ "$service_name" = "nginx" ]; then
                if _nginx_start; then
                    return 0
                else
                    red "nginx 服务启动失败\n"
                    return 1
                fi
            fi
            if command_exists rc-service; then
                rc-service "$service_name" start
            elif command_exists systemctl; then
                systemctl reset-failed "$service_name" 2>/dev/null
                systemctl daemon-reload
                systemctl start "$service_name"
            fi

            sleep 1
            if [ "$(_svc_state "$service_name" "$service_file")" = "running" ]; then
                green "${service_name} 服务已成功启动\n"
                return 0
            else
                red "${service_name} 服务启动失败\n"
                return 1
            fi
            ;;

        "stop")
            if [ "$status" = "missing" ]; then
                yellow "${service_name} 尚未安装！\n"
                return 2
            fi
            if [ "$status" = "stopped" ]; then
                yellow "${service_name} 当前未运行\n"
                return 1
            fi

            yellow "正在停止 ${service_name} 服务...\n"
            if [ "$service_name" = "nginx" ]; then
                _nginx_stop_all
                if _nginx_is_running; then
                    red "nginx 停止失败，仍有进程残留\n"
                    return 1
                fi
                green "nginx 服务已彻底停止\n"
                return 0
            fi

            if command_exists rc-service; then
                rc-service "$service_name" stop
            elif command_exists systemctl; then
                systemctl stop "$service_name"
            fi
            sleep 1

            local process_pattern=""
            case "$service_name" in
                "sing-box") process_pattern="${work_dir}/sing-box" ;;
                "argo")     process_pattern="${work_dir}/argo" ;;
            esac

            if [ -n "$process_pattern" ] && pgrep -f "$process_pattern" >/dev/null 2>&1; then
                yellow "检测到残留进程，正在强制终止...\n"
                pkill -15 -f "$process_pattern" 2>/dev/null
                sleep 1
                pkill -9 -f "$process_pattern" 2>/dev/null
                sleep 0.5
            fi

            if [ -n "$process_pattern" ] && pgrep -f "$process_pattern" >/dev/null 2>&1; then
                red "${service_name} 停止失败，仍有进程残留，请手动检查\n"
                return 1
            else
                green "${service_name} 服务已彻底停止\n"
                return 0
            fi
            ;;

        "restart")
            if [ "$status" = "missing" ]; then
                yellow "${service_name} 尚未安装！\n"
                return 1
            fi

            yellow "正在重启 ${service_name} 服务...\n"
            if [ "$service_name" = "nginx" ]; then
                # 运行中且配置有效时优先 reload：不中断同机其它站点的连接
                if [ "$status" = "running" ] && nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1; then
                    green "nginx 配置已重载\n"
                    return 0
                fi
                _nginx_stop_all
                sleep 0.5
                if _nginx_start; then
                    green "nginx 服务已成功重启\n"
                    return 0
                fi
                red "nginx 服务重启失败\n"
                yellow "请执行: nginx -t ; ss -lntp | head -30 ; rc-service nginx status 2>/dev/null || systemctl status nginx"
                return 1
            fi

            manage_service "$service_name" "stop" >/dev/null 2>&1
            sleep 1
            if command_exists rc-service; then
                rc-service "$service_name" start
            elif command_exists systemctl; then
                systemctl daemon-reload >/dev/null 2>&1
                systemctl start "$service_name" 2>/run/sb-svc-start.err
                if [ $? -ne 0 ] && [ -s /run/sb-svc-start.err ]; then
                    while IFS= read -r _eline; do
                        [ -n "$_eline" ] && red "$_eline"
                    done < /run/sb-svc-start.err
                fi
            fi
            sleep 1
            if [ "$(_svc_state "$service_name" "$service_file")" = "running" ]; then
                green "${service_name} 服务已成功重启\n"
                return 0
            fi
            red "${service_name} 服务重启失败\n"
            return 1
            ;;

        *)
            red "无效的操作: $action\n"
            return 1
            ;;
    esac
}

start_singbox()  { manage_service "sing-box" "start"; }
stop_singbox()   { manage_service "sing-box" "stop"; }
restart_singbox(){ manage_service "sing-box" "restart"; }
start_argo()     { manage_service "argo" "start"; }
stop_argo()      { manage_service "argo" "stop"; }
restart_argo()   { manage_service "argo" "restart"; }
start_nginx()    { manage_service "nginx" "start"; }
restart_nginx()  { manage_service "nginx" "restart"; }

# 卸载 sing-box（交互式）
uninstall_singbox() {
    reading "确定要卸载 sing-box 吗? (y/n): " choice
    case "${choice}" in
        y|Y)
            yellow "正在卸载 sing-box"
            # nginx 是否为安装本脚本之前就存在（安装时写入标记）；必须在删除 work_dir 之前读取
            local _ngx_pre=0
            [ -f "${work_dir}/nginx_preinstalled" ] && _ngx_pre=1
            command_exists uninstall_tg_monitor && uninstall_tg_monitor >/dev/null 2>&1 || true
            if command_exists rc-service; then
                rc-service sing-box stop; rc-service argo stop
                rm -f /etc/init.d/sing-box /etc/init.d/argo
                rc-update del sing-box default; rc-update del argo default
            else
                systemctl stop "${server_name}"; systemctl stop argo
                systemctl disable "${server_name}"; systemctl disable argo
                systemctl daemon-reload || true
            fi
            rm -rf "${work_dir}" || true
            rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
            rm -f /etc/nginx/conf.d/sing-box.conf /etc/nginx/conf.d/argo-ws.conf /etc/nginx/conf.d/sb-sub.conf
            rm -f /usr/bin/sb

            if [ "$_ngx_pre" = "1" ]; then
                yellow "\nnginx 在安装本脚本之前就已存在，保留 nginx（只移除本脚本的配置并还原主配置）"
                _sb_restore_nginx_main
                command_exists nginx && nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1
            else
                reading "\n是否卸载 Nginx？${green}(卸载请输入 ${yellow}y${re} ${green}回车将跳过卸载Nginx) (y/n): ${re}" choice
                case "${choice}" in
                    y|Y) manage_packages uninstall nginx ;;
                    *)
                        yellow "取消卸载Nginx\n\n"
                        _sb_restore_nginx_main
                        command_exists nginx && nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1
                        ;;
                esac
            fi
            green "\nsing-box 卸载成功\n\n" && exit 0
            ;;
        *) purple "已取消卸载操作\n\n" ;;
    esac
}

# 创建快捷指令 sb：每次运行远程拉取模块化入口脚本；GitHub 不通时回退到本机缓存的模块
create_shortcut() {
    local remote_default="https://raw.githubusercontent.com/gxjxzhoo/sing-box/refs/heads/main/sb/sb.sh"
    local cache="${work_dir}/cache"

    # 缓存当前已加载的模块，供离线/远程失败时使用
    if [ -n "${_SB_LIB:-}" ] && [ -d "${_SB_LIB}" ]; then
        rm -rf "${cache}"
        mkdir -p "${cache}"
        cp -r "${_SB_LIB}" "${cache}/lib" 2>/dev/null
        {
            echo '#!/bin/bash'
            echo 'export LANG=en_US.UTF-8'
            echo "for _m in ${_SB_MODS:-}; do source \"${cache}/lib/\${_m}.sh\"; done"
        } > "${cache}/sb-local.sh"
        chmod 700 "${cache}/sb-local.sh"
    fi

    cat > "$work_dir/sb.sh" << 'EOF'
#!/usr/bin/env bash
REMOTE_URL="${SB_REMOTE_URL:-__REMOTE_DEFAULT__}"
LOCAL="__CACHE__/sb-local.sh"
tmpd=$(mktemp -d) || exit 1
tmp="$tmpd/sb.sh"
trap 'rm -rf "$tmpd"' EXIT
if curl -fsSL --retry 2 -m 30 "$REMOTE_URL" -o "$tmp" && [ -s "$tmp" ]; then
    bash "$tmp" "$@"
elif [ -f "$LOCAL" ]; then
    echo "无法访问远程脚本，使用本机缓存版本" >&2
    bash "$LOCAL" "$@"
else
    echo "无法获取脚本: $REMOTE_URL" >&2
    exit 1
fi
EOF
    sed -i "s|__REMOTE_DEFAULT__|${remote_default}|; s|__CACHE__|${cache}|" "$work_dir/sb.sh"
    chmod 700 "$work_dir/sb.sh"
    ln -sf "$work_dir/sb.sh" /usr/bin/sb
    if [ -L /usr/bin/sb ] || [ -x /usr/bin/sb ]; then
        green "\n快捷指令 sb 创建成功（远程: ${SB_REMOTE_URL:-$remote_default}；失败时回退本机缓存）\n"
    else
        red "\n快捷指令创建失败\n"
    fi
}

