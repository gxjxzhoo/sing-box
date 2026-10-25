#!/usr/bin/env bash
# sing-box 一键脚本（单文件重写版）
# 入站：VLESS-Reality / Hysteria2 / TUIC v5 / AnyTLS / Socks5（直连）+ VLESS-WS（Cloudflare Argo 隧道）
# 支持：Debian/Ubuntu/CentOS/RHEL/Alpine，systemd 或 OpenRC；amd64/arm64/armv7/386
#
# 用法：
#   bash sb.sh              交互菜单
#   bash sb.sh install      安装（可用环境变量免交互，见下）
#   bash sb.sh nodes        查看节点
#   bash sb.sh set KEY=VAL  修改设置并重建（如 UUID=... PORT=... HY2_PORT=... ARGO_TOKEN=...）
#   bash sb.sh restart|status|update|uninstall
#
# 安装时可用的环境变量：
#   PORT        直连起始端口（Reality=PORT，Hy2=+1，TUIC=+2，AnyTLS=+3，Socks5=+4；默认随机）
#   REALITY_PORT/HY2_PORT/TUIC_PORT/ANYTLS_PORT/SOCKS_PORT  单独指定某协议端口（留空=按 PORT 推算）
#   PROTOCOLS   要启用的协议，逗号分隔，默认 reality,hy2,tuic,anytls,argo；可加 socks
#   UUID        默认随机
#   SNI         Reality 偷取的站点，默认 www.iij.ad.jp
#   ARGO_PORT   Argo 本地端口（只监听 127.0.0.1），默认随机
#   ARGO_TOKEN  固定隧道 Token（不填则用临时隧道 trycloudflare）
#   ARGO_DOMAIN 固定隧道绑定的域名（固定隧道必填）
#   CFIP/CFPORT Argo 节点的优选地址/端口，默认 cf.090227.xyz / 443
#   NAME        节点名前缀，默认主机名
#   SB_VERSION  固定 sing-box 版本（需 ≥1.12，如 1.12.9），默认最新正式版
# Alpine 需先 apk add bash curl
set -o pipefail
export LANG=en_US.UTF-8

SCRIPT_VERSION="3.2.0"
DIR=/etc/sing-box
ENV_FILE=$DIR/sb.env
CONF=$DIR/config.json
NODES=$DIR/nodes.txt
BIN_SB=$DIR/sing-box
BIN_CF=$DIR/cloudflared
SELF=/usr/local/bin/sb
SCRIPT_URL=${SCRIPT_URL:-https://raw.githubusercontent.com/gxjxzhoo/sing-box/main/sb.sh}
ALL_PROTOCOLS="reality,hy2,tuic,anytls,argo,socks"
DEFAULT_PROTOCOLS="reality,hy2,tuic,anytls,argo"

# ---------- 输出 ----------
c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { c "1;32" "$*"; }
warn() { c "1;33" "$*"; }
err()  { c "1;91" "$*" >&2; }
die()  { err "$*"; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }
ask()  { local p="$1" d="${2:-}" v; read -r -p "$(printf '\033[1;36m%s\033[0m' "$p${d:+ [$d]}: ")" v; echo "${v:-$d}"; }

# ---------- 系统 ----------
need_root() { [ "$(id -u)" = 0 ] || die "请用 root 运行（sudo -i）"; }

INIT=""
detect_init() {
  if has systemctl && [ -d /run/systemd/system ]; then INIT=systemd
  elif has rc-service; then INIT=openrc
  else die "不支持的 init 系统（需要 systemd 或 OpenRC）"; fi
}

pkg_install() {
  if has apt-get; then DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif has dnf; then dnf install -y -q "$@"
  elif has yum; then yum install -y -q "$@"
  elif has apk; then apk add --no-cache -q "$@"
  else die "找不到包管理器，请手动安装：$*"; fi
}

ensure_deps() {
  local miss=() p
  for p in curl jq openssl tar; do has "$p" || miss+=("$p"); done
  has sha256sum || miss+=(coreutils)
  [ ${#miss[@]} -eq 0 ] || { info "安装依赖：${miss[*]}"; pkg_install "${miss[@]}" || die "依赖安装失败"; }
}

ARCH=""; CF_ARCH=""
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   ARCH=amd64; CF_ARCH=amd64 ;;
    aarch64|arm64)  ARCH=arm64; CF_ARCH=arm64 ;;
    armv7l|armv7)   ARCH=armv7; CF_ARCH=arm ;;
    i386|i686|x86)  ARCH=386;   CF_ARCH=386 ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
}

rand_port() { # 在 10000-60000 找一个空闲端口
  local p i
  for i in $(seq 1 50); do
    p=$(( (RANDOM << 15 | RANDOM) % 50000 + 10000 ))
    port_free "$p" && { echo "$p"; return; }
  done
  die "找不到空闲端口"
}

port_free() {
  local p=$1
  if has ss; then ! ss -Hlntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$p\$"
  elif has netstat; then ! netstat -lntu 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$p\$"
  else return 0; fi
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

public_ip() {
  local ip
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.co; do
    ip=$(curl -4 -fsS -m 5 "$u" 2>/dev/null | tr -d '[:space:]') && [ -n "$ip" ] && { echo "$ip"; return; }
  done
  for u in https://api64.ipify.org https://ipv6.icanhazip.com; do
    ip=$(curl -6 -fsS -m 5 "$u" 2>/dev/null | tr -d '[:space:]') && [ -n "$ip" ] && { echo "[$ip]"; return; }
  done
  die "获取公网 IP 失败"
}

# ---------- 状态文件（唯一数据源，权限 600）----------
load_env() { [ -f "$ENV_FILE" ] && . "$ENV_FILE"; }

save_env() {
  local k
  umask 077
  {
    for k in UUID PORT $PORT_KEYS PROTOCOLS SNI ARGO_PORT ARGO_TOKEN ARGO_DOMAIN CFIP CFPORT NAME \
             REALITY_PRIVATE REALITY_PUBLIC REALITY_SID SB_VERSION; do
      printf '%s=%q\n' "$k" "${!k:-}"
    done
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

on() { [[ ",$PROTOCOLS," == *",$1,"* ]]; }

# 各协议端口：单独设置优先，否则按 PORT 推算
PORT_KEYS="REALITY_PORT HY2_PORT TUIC_PORT ANYTLS_PORT SOCKS_PORT"
pt() {
  case "$1" in
    reality) echo "${REALITY_PORT:-$PORT}" ;;
    hy2)     echo "${HY2_PORT:-$((PORT + 1))}" ;;
    tuic)    echo "${TUIC_PORT:-$((PORT + 2))}" ;;
    anytls)  echo "${ANYTLS_PORT:-$((PORT + 3))}" ;;
    socks)   echo "${SOCKS_PORT:-$((PORT + 4))}" ;;
  esac
}

check_ports() { # 已启用协议的端口必须合法且互不冲突
  local seen=" $ARGO_PORT " x p
  for x in reality hy2 tuic anytls socks; do
    on "$x" || continue
    p=$(pt "$x")
    valid_port "$p" || die "$x 端口无效：$p"
    [[ "$seen" == *" $p "* ]] && die "$x 端口 $p 与其他协议冲突"
    seen+="$p "
  done
}

# ---------- 下载（校验 GitHub 发布的 sha256）----------
gh_asset() { # repo tag(可空=latest) 名称正则 → 输出 "url sha256 tag"
  local repo=$1 tag=$2 re=$3 api json
  if [ -n "$tag" ]; then api="https://api.github.com/repos/$repo/releases/tags/$tag"
  else api="https://api.github.com/repos/$repo/releases/latest"; fi
  json=$(curl -fsSL -m 20 -H 'Accept: application/vnd.github+json' "$api") \
    || die "访问 GitHub API 失败（可能被限流，稍后重试）：$api"
  jq -r --arg re "$re" '. as $r | .assets[] | select(.name|test($re))
        | "\(.browser_download_url) \((.digest // "")|sub("^sha256:";"")) \($r.tag_name)"' <<<"$json" | head -1
}

fetch_verified() { # url sha256 dest
  local url=$1 sum=$2 out=$3
  [ -n "$sum" ] || die "发布没有提供 sha256，拒绝安装：$url"
  curl -fsSL --retry 2 -m 300 -o "$out" "$url" || die "下载失败：$url"
  echo "$sum  $out" | sha256sum -c --status - || { rm -f "$out"; die "sha256 校验失败：$url"; }
}

install_singbox() {
  local tag="" line url sum tmp
  [ -n "${SB_VERSION:-}" ] && tag="v${SB_VERSION#v}"
  line=$(gh_asset SagerNet/sing-box "$tag" "^sing-box-[0-9.]+-linux-${ARCH}\\.tar\\.gz$")
  [ -n "$line" ] || die "找不到 sing-box ${tag:-latest} 的 linux-${ARCH} 包"
  read -r url sum tag <<<"$line"
  info "下载 sing-box ${tag}"
  tmp=$(mktemp -d)
  fetch_verified "$url" "$sum" "$tmp/sb.tgz"
  tar -xzf "$tmp/sb.tgz" -C "$tmp" || die "解压失败"
  install -m 755 "$(find "$tmp" -type f -name sing-box | head -1)" "$BIN_SB"
  find "$tmp" -type f -name 'libcronet*' -exec cp -f {} "$DIR/" \;
  rm -rf "$tmp"
  "$BIN_SB" version >/dev/null 2>&1 || die "sing-box 无法在本机运行"
}

install_cloudflared() {
  local line url sum tag
  line=$(gh_asset cloudflare/cloudflared "" "^cloudflared-linux-${CF_ARCH}$")
  [ -n "$line" ] || die "找不到 cloudflared linux-${CF_ARCH}"
  read -r url sum tag <<<"$line"
  info "下载 cloudflared ${tag}"
  fetch_verified "$url" "$sum" "$BIN_CF.part"
  chmod 755 "$BIN_CF.part" && mv -f "$BIN_CF.part" "$BIN_CF"
  "$BIN_CF" --version >/dev/null 2>&1 || die "cloudflared 无法在本机运行"
}

# ---------- 证书与密钥 ----------
ensure_keys() {
  if [ ! -s "$DIR/cert.pem" ] || [ ! -s "$DIR/key.pem" ]; then
    openssl ecparam -genkey -name prime256v1 -out "$DIR/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$DIR/key.pem" -out "$DIR/cert.pem" -subj "/CN=bing.com" 2>/dev/null
    chmod 600 "$DIR/key.pem"
  fi
  if [ -z "${REALITY_PRIVATE:-}" ] || [ -z "${REALITY_PUBLIC:-}" ]; then
    local out
    out=$("$BIN_SB" generate reality-keypair) || die "生成 Reality 密钥失败"
    REALITY_PRIVATE=$(awk -F': *' '/PrivateKey/{print $2}' <<<"$out")
    REALITY_PUBLIC=$(awk -F': *' '/PublicKey/{print $2}' <<<"$out")
  fi
  [ -n "${REALITY_SID:-}" ] || REALITY_SID=$(openssl rand -hex 8)
}

# ---------- 生成配置 ----------
build_config() {
  local hy2 tuic anytls socks tls inb='[]'
  hy2=$(pt hy2); tuic=$(pt tuic); anytls=$(pt anytls); socks=$(pt socks)
  tls=$(jq -n --arg c "$DIR/cert.pem" --arg k "$DIR/key.pem" \
        '{enabled:true, certificate_path:$c, key_path:$k}')

  on reality && inb=$(jq --argjson p "$(pt reality)" --arg u "$UUID" --arg sni "$SNI" \
      --arg pk "$REALITY_PRIVATE" --arg sid "$REALITY_SID" '. + [{
        type:"vless", tag:"reality", listen:"::", listen_port:$p,
        users:[{uuid:$u, flow:"xtls-rprx-vision"}],
        tls:{enabled:true, server_name:$sni,
             reality:{enabled:true, handshake:{server:$sni, server_port:443},
                      private_key:$pk, short_id:[$sid]}}}]' <<<"$inb")

  on hy2 && inb=$(jq --argjson p "$hy2" --arg u "$UUID" --argjson t "$tls" '. + [{
        type:"hysteria2", tag:"hy2", listen:"::", listen_port:$p,
        users:[{password:$u}], masquerade:"https://www.bing.com",
        tls:($t + {alpn:["h3"]})}]' <<<"$inb")

  on tuic && inb=$(jq --argjson p "$tuic" --arg u "$UUID" --argjson t "$tls" '. + [{
        type:"tuic", tag:"tuic", listen:"::", listen_port:$p,
        users:[{uuid:$u, password:$u}], congestion_control:"bbr",
        tls:($t + {alpn:["h3"]})}]' <<<"$inb")

  on anytls && inb=$(jq --argjson p "$anytls" --arg u "$UUID" --argjson t "$tls" '. + [{
        type:"anytls", tag:"anytls", listen:"::", listen_port:$p,
        users:[{password:$u}], tls:$t}]' <<<"$inb")

  on socks && inb=$(jq --argjson p "$socks" --arg n "${UUID%%-*}" --arg u "$UUID" '. + [{
        type:"socks", tag:"socks", listen:"::", listen_port:$p,
        users:[{username:$n, password:$u}]}]' <<<"$inb")

  on argo && inb=$(jq --argjson p "$ARGO_PORT" --arg u "$UUID" '. + [{
        type:"vless", tag:"argo", listen:"127.0.0.1", listen_port:$p,
        users:[{uuid:$u}],
        transport:{type:"ws", path:"/argo", early_data_header_name:"Sec-WebSocket-Protocol"}}]' <<<"$inb")

  jq -n --argjson inb "$inb" '{
    log:{level:"warn", timestamp:true},
    dns:{servers:[{type:"local", tag:"local"}]},
    inbounds:$inb,
    outbounds:[{type:"direct", tag:"direct"}],
    route:{final:"direct", default_domain_resolver:"local"}}' > "$CONF.new"
  chmod 600 "$CONF.new"
  "$BIN_SB" check -c "$CONF.new" || { rm -f "$CONF.new"; die "配置校验失败，未改动现有配置"; }
  mv -f "$CONF.new" "$CONF"
}

# ---------- 服务（systemd / OpenRC 共用）----------
write_service() { # 名称 描述 命令 [环境文件]
  local name=$1 desc=$2 cmd=$3 envf=${4:-}
  if [ "$INIT" = systemd ]; then
    cat > "/etc/systemd/system/$name.service" <<EOF
[Unit]
Description=$desc
After=network-online.target
Wants=network-online.target

[Service]
${envf:+EnvironmentFile=$envf}
ExecStart=$cmd
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
StandardOutput=append:$DIR/$name.log
StandardError=append:$DIR/$name.log

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$name" >/dev/null 2>&1
  else
    local bin=${cmd%% *} args=${cmd#* }
    [ "$bin" = "$cmd" ] && args=""
    cat > "/etc/init.d/$name" <<EOF
#!/sbin/openrc-run
description="$desc"
command="$bin"
command_args="$args"
command_background=true
pidfile="/run/$name.pid"
output_log="$DIR/$name.log"
error_log="$DIR/$name.log"
depend() { need net; }
start_pre() { ${envf:+set -a; . $envf; set +a;} :; }
EOF
    chmod 755 "/etc/init.d/$name"
    rc-update add "$name" default >/dev/null 2>&1
  fi
}

svc() { # 动作 名称
  if [ "$INIT" = systemd ]; then systemctl "$1" "$2" >/dev/null 2>&1
  else rc-service "$2" "$1" >/dev/null 2>&1; fi
}

svc_active() {
  if [ "$INIT" = systemd ]; then systemctl is-active --quiet "$1"
  else rc-service "$1" status >/dev/null 2>&1; fi
}

remove_service() {
  svc stop "$1"
  if [ "$INIT" = systemd ]; then
    systemctl disable "$1" >/dev/null 2>&1; rm -f "/etc/systemd/system/$1.service"; systemctl daemon-reload
  else
    rc-update del "$1" default >/dev/null 2>&1; rm -f "/etc/init.d/$1"
  fi
}

setup_argo_service() {
  if ! on argo; then remove_service sb-argo 2>/dev/null; rm -f "$DIR/argo.env"; return; fi
  [ -x "$BIN_CF" ] || install_cloudflared
  local cmd="$BIN_CF tunnel --no-autoupdate --edge-ip-version auto --protocol http2"
  if [ -n "${ARGO_TOKEN:-}" ]; then
    # Token 只放在 600 权限的环境文件里，不出现在进程命令行
    ( umask 077; printf 'TUNNEL_TOKEN=%s\n' "$ARGO_TOKEN" > "$DIR/argo.env" )
    write_service sb-argo "Cloudflare Tunnel (sing-box)" "$cmd run" "$DIR/argo.env"
  else
    rm -f "$DIR/argo.env"
    write_service sb-argo "Cloudflare Tunnel (sing-box)" "$cmd --url http://127.0.0.1:$ARGO_PORT"
  fi
  : > "$DIR/sb-argo.log"
  svc restart sb-argo
}

# ---------- 防火墙（仅在已启用时放行）----------
open_ports() {
  local tcp=() udp=() p
  on reality && tcp+=("$(pt reality)")
  on hy2 && udp+=("$(pt hy2)")
  on tuic && udp+=("$(pt tuic)")
  on anytls && tcp+=("$(pt anytls)")
  on socks && { tcp+=("$(pt socks)"); udp+=("$(pt socks)"); }
  if has ufw && ufw status 2>/dev/null | grep -q active; then
    for p in "${tcp[@]}"; do ufw allow "$p/tcp" >/dev/null; done
    for p in "${udp[@]}"; do ufw allow "$p/udp" >/dev/null; done
  elif has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    for p in "${tcp[@]}"; do firewall-cmd -q --permanent --add-port="$p/tcp"; done
    for p in "${udp[@]}"; do firewall-cmd -q --permanent --add-port="$p/udp"; done
    firewall-cmd -q --reload
  fi
}

# ---------- 节点 ----------
argo_domain() {
  [ -n "${ARGO_DOMAIN:-}" ] && { echo "$ARGO_DOMAIN"; return; }
  local d i
  for i in $(seq 1 20); do
    d=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$DIR/sb-argo.log" 2>/dev/null | tail -1)
    [ -n "$d" ] && { echo "${d#https://}"; return; }
    sleep 2
  done
}

urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

show_nodes() {
  load_env
  [ -f "$CONF" ] || die "尚未安装"
  local ip n host; ip=$(public_ip); n=$(urlenc "${NAME}")
  {
    on reality && echo "vless://$UUID@$ip:$(pt reality)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$REALITY_PUBLIC&sid=$REALITY_SID&type=tcp#$n-reality"
    on hy2     && echo "hysteria2://$UUID@$ip:$(pt hy2)?sni=www.bing.com&alpn=h3&insecure=1#$n-hy2"
    on tuic    && echo "tuic://$UUID:$UUID@$ip:$(pt tuic)?sni=www.bing.com&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#$n-tuic"
    on anytls  && echo "anytls://$UUID@$ip:$(pt anytls)?sni=www.bing.com&insecure=1#$n-anytls"
    on socks   && echo "socks5://${UUID%%-*}:$UUID@$ip:$(pt socks)#$n-socks5"
    if on argo; then
      host=$(argo_domain)
      if [ -n "$host" ]; then
        echo "vless://$UUID@$CFIP:$CFPORT?encryption=none&security=tls&sni=$host&fp=chrome&type=ws&host=$host&path=%2Fargo%3Fed%3D2560#$n-argo"
      else
        warn "未获取到 Argo 域名，稍后执行 sb nodes 再试" >&2
      fi
    fi
  } > "$NODES.new"
  mv -f "$NODES.new" "$NODES"; chmod 600 "$NODES"
  echo; c "1;35" "$(cat "$NODES")"; echo
  info "Base64（客户端可直接导入）："
  base64 -w0 "$NODES" 2>/dev/null || base64 "$NODES" | tr -d '\n'; echo
  on hy2 || on tuic || on anytls && warn "Hy2/TUIC/AnyTLS 用自签证书，客户端需开启“跳过证书验证”"
  [ -n "${ARGO_TOKEN:-}" ] && on argo && warn "固定隧道：请在 Cloudflare 把 $ARGO_DOMAIN 指向 http://localhost:$ARGO_PORT"
  return 0
}

# ---------- 主要操作 ----------
apply() { # 生成配置并（重）启动
  save_env
  ensure_keys; save_env
  build_config
  write_service sing-box "sing-box" "$BIN_SB run -c $CONF"
  svc restart sing-box
  setup_argo_service
  open_ports
  sleep 1
  svc_active sing-box || { err "sing-box 未能启动，日志："; tail -n 20 "$DIR/sing-box.log" 2>/dev/null; exit 1; }
}

do_install() {
  need_root; detect_init; detect_arch; ensure_deps
  if [ -f "$ENV_FILE" ]; then
    warn "检测到已安装，将保留现有设置重新安装（要全新安装请先卸载）"
    load_env
  fi
  mkdir -p "$DIR"; chmod 700 "$DIR"

  PROTOCOLS=${PROTOCOLS:-$DEFAULT_PROTOCOLS}
  UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
  SNI=${SNI:-www.iij.ad.jp}
  CFIP=${CFIP:-cf.090227.xyz}
  CFPORT=${CFPORT:-443}
  NAME=${NAME:-$(hostname | cut -c1-20)}
  if [ -z "${PORT:-}" ]; then
    if [ -t 0 ]; then PORT=$(ask "直连起始端口（默认占用 5 个连续端口，回车随机）" ""); fi
    PORT=${PORT:-$(rand_port)}
  fi
  valid_port "$PORT" || die "端口无效：$PORT"
  ARGO_PORT=${ARGO_PORT:-$(rand_port)}
  check_ports
  if on argo && [ -n "${ARGO_TOKEN:-}" ] && [ -z "${ARGO_DOMAIN:-}" ]; then
    die "使用固定隧道 ARGO_TOKEN 时必须同时设置 ARGO_DOMAIN"
  fi

  [ -x "$BIN_SB" ] || install_singbox
  apply
  install_self
  info "安装完成（脚本 v$SCRIPT_VERSION），以后输入 sb 打开菜单"
  show_nodes
}

# 把脚本装到本机 /usr/local/bin/sb；之后 sb 命令只运行本地副本，不再每次联网拉取
install_self() {
  if [ -f "$0" ] && [ "$(readlink -f "$0")" != "$SELF" ]; then
    install -m 700 "$0" "$SELF"
  elif [ ! -f "$0" ]; then  # 通过 bash <(curl ...) 运行时只下载一次
    curl -fsSL -m 30 -o "$SELF.part" "$SCRIPT_URL" && chmod 700 "$SELF.part" && mv -f "$SELF.part" "$SELF" \
      || warn "未能保存 sb 快捷命令，可手动下载脚本运行"
  fi
  # 旧版脚本留下的 /usr/bin/sb 软链会指向已删除的文件，统一指向本地副本
  [ -f "$SELF" ] && ln -sf "$SELF" /usr/bin/sb
}

do_set() { # KEY=VAL ...
  need_root; detect_init; load_env
  [ -f "$ENV_FILE" ] || die "尚未安装"
  local kv k v p
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    case "$k" in
      PROTOCOLS) for p in ${v//,/ }; do [[ ",$ALL_PROTOCOLS," == *",$p,"* ]] || die "未知协议：$p"; done; PROTOCOLS=$v ;;
      UUID|SNI|CFIP|CFPORT|NAME|ARGO_DOMAIN|ARGO_TOKEN) printf -v "$k" '%s' "$v" ;;
      PORT|ARGO_PORT) valid_port "$v" || die "端口无效：$v"; printf -v "$k" '%s' "$v" ;;
      REALITY_PORT|HY2_PORT|TUIC_PORT|ANYTLS_PORT|SOCKS_PORT)
        [ -z "$v" ] || valid_port "$v" || die "端口无效：$v"; printf -v "$k" '%s' "$v" ;;
      *) die "不支持的设置：$k" ;;
    esac
  done
  check_ports
  if on argo && [ -n "${ARGO_TOKEN:-}" ] && [ -z "${ARGO_DOMAIN:-}" ]; then die "固定隧道需要 ARGO_DOMAIN"; fi
  apply
  info "已更新"
  show_nodes
}

do_update() {
  need_root; detect_init; detect_arch; ensure_deps; load_env
  [ -f "$ENV_FILE" ] || die "尚未安装"
  install_singbox
  on argo && install_cloudflared
  svc restart sing-box; on argo && svc restart sb-argo
  info "已更新到：$("$BIN_SB" version | head -1)"
}

do_restart() { need_root; detect_init; load_env; svc restart sing-box; on argo && svc restart sb-argo; do_status; }

do_status() {
  detect_init; load_env
  local s
  for s in sing-box sb-argo; do
    [ "$s" = sb-argo ] && ! on argo && continue
    if svc_active "$s"; then info "$s：运行中"; else err "$s：未运行"; fi
  done
}

do_uninstall() {
  need_root; detect_init
  remove_service sb-argo; remove_service sing-box
  [ "$(readlink /usr/bin/sb 2>/dev/null)" = "$SELF" ] && rm -f /usr/bin/sb
  rm -rf "$DIR" "$SELF"
  info "已卸载（防火墙规则如有需要请手动删除）"
}

port_menu() {
  local x k
  for x in reality hy2 tuic anytls socks; do on "$x" && echo "  $x：$(pt "$x")"; done
  echo "  输入 all 改起始端口（各协议顺延），或输入协议名单独改"
  x=$(ask "要改哪个" "all")
  case "$x" in
    all) do_set "PORT=$(ask "新的起始端口" "${PORT:-}")" ;;
    reality|hy2|tuic|anytls|socks)
      k="$(tr a-z A-Z <<<"$x")_PORT"
      do_set "$k=$(ask "$x 新端口（留空=恢复按起始端口推算）" "")" ;;
    *) warn "无效选项" ;;
  esac
}

menu() {
  load_env
  while true; do
    echo
    c "1;36" "==== sing-box 管理 v$SCRIPT_VERSION ===="
    if [ -f "$ENV_FILE" ]; then do_status; else warn "未安装"; fi
    cat <<'EOF'
 1. 安装 / 重装        2. 查看节点
 3. 修改端口           4. 更换 UUID
 5. 设置固定隧道       6. 改回临时隧道
 7. 选择协议           8. 重启
 9. 更新内核           10. 卸载
 0. 退出
EOF
    case "$(ask "请选择" "")" in
      1) do_install ;;
      2) show_nodes ;;
      3) port_menu ;;
      4) do_set "UUID=$(cat /proc/sys/kernel/random/uuid)" ;;
      5) do_set "ARGO_TOKEN=$(ask "隧道 Token" "")" "ARGO_DOMAIN=$(ask "隧道域名" "${ARGO_DOMAIN:-}")" ;;
      6) do_set "ARGO_TOKEN=" "ARGO_DOMAIN=" ;;
      7) do_set "PROTOCOLS=$(ask "协议（可选 $ALL_PROTOCOLS）" "${PROTOCOLS:-$DEFAULT_PROTOCOLS}")" ;;
      8) do_restart ;;
      9) do_update ;;
      10) [ "$(ask "确认卸载？输入 y" "")" = y ] && do_uninstall ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
    load_env
  done
}

case "${1:-menu}" in
  install)   do_install ;;
  nodes)     show_nodes ;;
  set)       shift; do_set "$@" ;;
  restart)   do_restart ;;
  status)    do_status ;;
  update)    do_update ;;
  uninstall) do_uninstall ;;
  menu)      need_root; menu ;;
  -h|--help|help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0" ;;
  *) die "未知命令：$1（sb help 查看用法）" ;;
esac
