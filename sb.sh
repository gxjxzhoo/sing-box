#!/usr/bin/env bash
# sing-box 一键脚本（单文件重写版）
# 入站：VLESS-Reality / Hysteria2 / TUIC v5 / AnyTLS / Socks5 / SS-2022 / Trojan / VMess-WS / ShadowTLS（直连）+ VLESS-WS（Cloudflare Argo 隧道）
# 支持：Debian/Ubuntu/CentOS/RHEL/Alpine，systemd 或 OpenRC；amd64/arm64/armv7/386
#
# 用法：
#   bash sb.sh              交互菜单
#   bash sb.sh install      安装（可用环境变量免交互，见下）
#   bash sb.sh nodes        查看节点
#   bash sb.sh set KEY=VAL  修改设置并重建（如 UUID=... PORT=... HY2_PORT=... ARGO_TOKEN=...）
#   bash sb.sh restart|status|update|upgrade|uninstall   （upgrade=更新本脚本）
#
# 安装时可用的环境变量：
#   PORT        直连起始端口（Reality=PORT，Hy2=+1，TUIC=+2，AnyTLS=+3，Socks5=+4，SS=+5，Trojan=+6，VMess=+7，ShadowTLS=+8；默认随机）
#   REALITY_PORT/HY2_PORT/TUIC_PORT/ANYTLS_PORT/SOCKS_PORT/SS_PORT/TROJAN_PORT/VMESS_PORT/SHADOWTLS_PORT  单独指定某协议端口（留空=按 PORT 推算）
#   PROTOCOLS   要启用的协议，逗号分隔，默认 reality,hy2,tuic,anytls,argo；可加 socks,ss,trojan,vmess,shadowtls
#   ARGO_PROTO  Argo 隧道里跑的协议：vless（默认）/vmess/trojan
#   UUID        默认随机
#   SNI         Reality 偷取的站点，默认 www.iij.ad.jp
#   ARGO_PORT   Argo 本地端口（只监听 127.0.0.1），默认随机
#   ARGO_TOKEN  固定隧道 Token（不填则用临时隧道 trycloudflare）
#   ARGO_DOMAIN 固定隧道绑定的域名（固定隧道必填）
#   SUB         Argo 订阅：1 开启（默认）/0 关闭；只通过 Argo 域名访问，不开公网端口
#   CFIP/CFPORT Argo 节点的优选地址/端口，默认 saas.sin.fan / 443
#   NAME        节点名前缀，默认主机名
#   IP_MODE     节点用哪个 IP：auto（优先 v4）/4/6/both，默认 auto
#   SB_VERSION  固定 sing-box 版本（需 ≥1.12，如 1.12.9），默认最新正式版
#   TUNE        1 开启 BBR+fq 与 UDP 缓冲调优（默认）/0 不改内核参数
# Alpine 需先 apk add bash curl
set -o pipefail
export LANG=en_US.UTF-8

SCRIPT_VERSION="3.7.4"
DIR=/etc/sing-box
ENV_FILE=$DIR/sb.env
CONF=$DIR/config.json
NODES=$DIR/nodes.txt
BIN_SB=$DIR/sing-box
BIN_CF=$DIR/cloudflared
SELF=/usr/local/bin/sb
SYSCTL_FILE=/etc/sysctl.d/99-sing-box.conf
SCRIPT_URL=${SCRIPT_URL:-https://raw.githubusercontent.com/gxjxzhoo/sing-box/main/sb.sh}
ALL_PROTOCOLS="hy2,reality,argo,tuic,trojan,vmess,ss,anytls,shadowtls,socks"  # 按热度排序（菜单字母 a-j 即此顺序）
DIRECT="hy2 reality tuic trojan vmess ss anytls shadowtls socks"
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

rand_base() { # 找一个起始端口，使 PORT..PORT+8 都空闲（各协议按偏移推算时不撞端口）
  local p i k ok
  for i in $(seq 1 50); do
    p=$(( (RANDOM << 15 | RANDOM) % 50000 + 10000 )); ok=1
    for k in 0 1 2 3 4 5 6 7 8; do port_free $((p + k)) || { ok=0; break; }; done
    [ "$ok" = 1 ] && { echo "$p"; return; }
  done
  die "找不到空闲端口"
}

valid_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

ip4() { local u ip; for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.co; do
  ip=$(curl -4 -fsS -m 5 "$u" 2>/dev/null | tr -d '[:space:]') && [ -n "$ip" ] && { echo "$ip"; return; }; done; }
ip6() { local u ip; for u in https://api64.ipify.org https://ipv6.icanhazip.com https://ifconfig.co; do
  ip=$(curl -6 -fsS -m 5 "$u" 2>/dev/null | tr -d '[:space:]') && [[ "$ip" == *:* ]] && { echo "[$ip]"; return; }; done; }

node_ips() { # 按 IP_MODE 输出“地址 后缀”：auto=优先 v4，4/6=只用该版本，both=两个都出
  local a b
  case "${IP_MODE:-auto}" in
    4)    a=$(ip4); [ -n "$a" ] || die "本机没有可用的 IPv4"; echo "$a" ;;
    6)    b=$(ip6); [ -n "$b" ] || die "本机没有可用的 IPv6"; echo "$b" ;;
    both) a=$(ip4); b=$(ip6)
          [ -n "$a$b" ] || die "获取公网 IP 失败"
          if [ -n "$a" ] && [ -n "$b" ]; then echo "$a -v4"; echo "$b -v6"; else echo "$a$b"; fi ;;
    *)    a=$(ip4); [ -n "$a" ] || a=$(ip6); [ -n "$a" ] || die "获取公网 IP 失败"; echo "$a" ;;
  esac
}

# ---------- 状态文件（唯一数据源，权限 600）----------
load_env() { [ -f "$ENV_FILE" ] && . "$ENV_FILE"; }

save_env() {
  local k
  umask 077
  {
    for k in UUID PORT $PORT_KEYS PROTOCOLS IP_MODE SNI ARGO_PORT ARGO_TOKEN ARGO_DOMAIN CFIP CFPORT NAME TUNE \
             REALITY_PRIVATE REALITY_PUBLIC REALITY_SID SS_PASSWORD STLS_INNER_PORT ARGO_PROTO SUB SUB_TOKEN SUB_PORT SB_VERSION; do
      printf '%s=%q\n' "$k" "${!k:-}"
    done
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

on() { [[ ",$PROTOCOLS," == *",$1,"* ]]; }
sub_on() { on argo && [ "${SUB:-1}" != 0 ]; }

# 各协议端口：单独设置优先，否则按 PORT 推算
PORT_KEYS="REALITY_PORT HY2_PORT TUIC_PORT ANYTLS_PORT SOCKS_PORT SS_PORT TROJAN_PORT VMESS_PORT SHADOWTLS_PORT"
pt() {
  case "$1" in
    reality) echo "${REALITY_PORT:-$PORT}" ;;
    hy2)     echo "${HY2_PORT:-$((PORT + 1))}" ;;
    tuic)    echo "${TUIC_PORT:-$((PORT + 2))}" ;;
    anytls)  echo "${ANYTLS_PORT:-$((PORT + 3))}" ;;
    socks)   echo "${SOCKS_PORT:-$((PORT + 4))}" ;;
    ss)      echo "${SS_PORT:-$((PORT + 5))}" ;;
    trojan)  echo "${TROJAN_PORT:-$((PORT + 6))}" ;;
    vmess)   echo "${VMESS_PORT:-$((PORT + 7))}" ;;
    shadowtls) echo "${SHADOWTLS_PORT:-$((PORT + 8))}" ;;
  esac
}

check_ports() { # 已启用协议的端口必须合法且互不冲突
  local seen=" $ARGO_PORT ${STLS_INNER_PORT:-} ${SUB_PORT:-} " x p
  for x in $DIRECT; do
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
same_keypair() { # 证书与私钥是否配对
  [ "$(openssl x509 -noout -pubkey -in "$1" 2>/dev/null | openssl sha256)" = "$(openssl pkey -pubout -in "$2" 2>/dev/null | openssl sha256)" ]
}

migrate_old() { # 旧版 sb（sb/ 目录）留下的证书与 Reality 密钥：配对则沿用，客户端不用改
  if [ ! -s "$DIR/key.pem" ] && [ -s "$DIR/private.key" ] && [ -s "$DIR/cert.pem" ] && same_keypair "$DIR/cert.pem" "$DIR/private.key"; then
    install -m 600 "$DIR/private.key" "$DIR/key.pem" && info "沿用旧版证书（cert.pem + private.key）"
  fi
  if [ -z "${REALITY_PRIVATE:-}" ] && [ -s "$DIR/reality.keys" ]; then
    REALITY_PRIVATE=$(sed -n 's/^PRIVATE_KEY=//p' "$DIR/reality.keys" | head -1)
    REALITY_PUBLIC=$(sed -n 's/^PUBLIC_KEY=//p' "$DIR/reality.keys" | head -1)
    [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] && info "沿用旧版 Reality 密钥" || { REALITY_PRIVATE=""; REALITY_PUBLIC=""; }
  fi
  return 0
}

ensure_keys() {
  migrate_old
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
  [ -n "${SS_PASSWORD:-}" ] || SS_PASSWORD=$(openssl rand -base64 16)
  [ -n "${STLS_INNER_PORT:-}" ] || STLS_INNER_PORT=$(rand_port)
  [ -n "${SUB_TOKEN:-}" ] || SUB_TOKEN=$(openssl rand -hex 12)
  [ -n "${SUB_PORT:-}" ] || SUB_PORT=$(rand_port)
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

  on ss && inb=$(jq --argjson p "$(pt ss)" --arg pw "$SS_PASSWORD" '. + [{
        type:"shadowsocks", tag:"ss", listen:"::", listen_port:$p,
        method:"2022-blake3-aes-128-gcm", password:$pw}]' <<<"$inb")

  on trojan && inb=$(jq --argjson p "$(pt trojan)" --arg u "$UUID" --argjson t "$tls" '. + [{
        type:"trojan", tag:"trojan", listen:"::", listen_port:$p,
        users:[{password:$u}], tls:$t}]' <<<"$inb")

  on vmess && inb=$(jq --argjson p "$(pt vmess)" --arg u "$UUID" '. + [{
        type:"vmess", tag:"vmess", listen:"::", listen_port:$p,
        users:[{uuid:$u, alterId:0}],
        transport:{type:"ws", path:"/vmess", early_data_header_name:"Sec-WebSocket-Protocol"}}]' <<<"$inb")

  # ShadowTLS v3：对外握手伪装 www.bing.com，内层是只听本机的 SS-2022
  on shadowtls && inb=$(jq --argjson p "$(pt shadowtls)" --argjson ip "$STLS_INNER_PORT" \
      --arg u "$UUID" --arg pw "$SS_PASSWORD" '. + [{
        type:"shadowtls", tag:"shadowtls", listen:"::", listen_port:$p, version:3,
        users:[{name:"sb", password:$u}], handshake:{server:"www.bing.com", server_port:443},
        strict_mode:true, detour:"stls-ss"},
       {type:"shadowsocks", tag:"stls-ss", listen:"127.0.0.1", listen_port:$ip,
        method:"2022-blake3-aes-128-gcm", password:$pw}]' <<<"$inb")

  if on argo; then
    local au
    case "${ARGO_PROTO:-vless}" in
      vmess)  au='[{uuid:$u, alterId:0}]' ;;
      trojan) au='[{password:$u}]' ;;
      *)      au='[{uuid:$u}]' ;;
    esac
    inb=$(jq --argjson p "$ARGO_PORT" --arg u "$UUID" --arg ty "${ARGO_PROTO:-vless}" ". + [{
        type:\$ty, tag:\"argo\", listen:\"127.0.0.1\", listen_port:\$p, users:$au,
        transport:{type:\"ws\", path:\"/argo\", early_data_header_name:\"Sec-WebSocket-Protocol\"}}]" <<<"$inb")
  fi

  # Argo 订阅：借用 sing-box 自带的静态文件服务（clash_api external_ui），只监听 127.0.0.1，经隧道按路径转发
  local exp='{}'
  if sub_on; then
    mkdir -p "$DIR/sub/$SUB_TOKEN"; : > "$DIR/sub/index.html"; : > "$DIR/sub/$SUB_TOKEN/index.html"
    exp=$(jq -n --arg c "127.0.0.1:$SUB_PORT" --arg u "$DIR/sub" --arg s "$(openssl rand -hex 16)" \
      '{clash_api:{external_controller:$c, external_ui:$u, secret:$s}}')
  fi

  jq -n --argjson inb "$inb" --argjson exp "$exp" '{
    log:{level:"warn", timestamp:true},
    dns:{servers:[{type:"local", tag:"local"}]},
    inbounds:$inb,
    outbounds:[{type:"direct", tag:"direct"}],
    route:{final:"direct", default_domain_resolver:"local"}}
    + (if $exp == {} then {} else {experimental:$exp} end)' > "$CONF.new"
  chmod 600 "$CONF.new"
  "$BIN_SB" check -c "$CONF.new" || { rm -f "$CONF.new"; die "配置校验失败，未改动现有配置"; }
  mv -f "$CONF.new" "$CONF"
}

# ---------- 服务（systemd / OpenRC 共用）----------
write_service() { # 名称 描述 命令 [环境文件] [启动后执行]
  local name=$1 desc=$2 cmd=$3 envf=${4:-} post=${5:-}
  if [ "$INIT" = systemd ]; then
    cat > "/etc/systemd/system/$name.service" <<EOF
[Unit]
Description=$desc
After=network-online.target
Wants=network-online.target

[Service]
${envf:+EnvironmentFile=$envf}
ExecStart=$cmd
${post:+ExecStartPost=-/bin/sh -c '($post) >/dev/null 2>&1 &'}
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
start_post() { ${post:+($post) >/dev/null 2>&1 &} :; }
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

svc_sig() { cat "/etc/systemd/system/$1.service" "/etc/init.d/$1" "$DIR/argo.env" "$DIR/argo.yml" 2>/dev/null | cksum; }

setup_argo_service() {
  if ! on argo; then remove_service sb-argo 2>/dev/null; rm -f "$DIR/argo.env" "$DIR/argo.yml"; return; fi
  local before; before=$(svc_sig sb-argo)
  [ -x "$BIN_CF" ] || install_cloudflared
  local cmd="$BIN_CF tunnel --no-autoupdate --edge-ip-version auto --protocol http2"
  if [ -n "${ARGO_TOKEN:-}" ]; then
    # Token 只放在 600 权限的环境文件里，不出现在进程命令行
    ( umask 077; printf 'TUNNEL_TOKEN=%s\n' "$ARGO_TOKEN" > "$DIR/argo.env" )
    write_service sb-argo "Cloudflare Tunnel (sing-box)" "$cmd run" "$DIR/argo.env"
  else
    rm -f "$DIR/argo.env"
    if sub_on; then  # 临时隧道：本地 ingress 按路径分流，订阅路径 → 订阅服务，其余 → Argo 节点
      ( umask 077; printf 'ingress:\n  - path: ^/ui/%s/\n    service: http://127.0.0.1:%s\n  - service: http://127.0.0.1:%s\n' \
        "$SUB_TOKEN" "$SUB_PORT" "$ARGO_PORT" > "$DIR/argo.yml" )
      cmd="$cmd --config $DIR/argo.yml"
    else rm -f "$DIR/argo.yml"; fi
    # 临时隧道每次启动（含开机）域名都会变：启动后自动刷新节点和订阅内容
    write_service sb-argo "Cloudflare Tunnel (sing-box)" "$cmd --url http://127.0.0.1:$ARGO_PORT" "" "sleep 5; $SELF nodes"
  fi
  # 隧道配置没变且在运行就不重启：临时隧道一重启就换域名
  if [ "$before" = "$(svc_sig sb-argo)" ] && svc_active sb-argo; then return; fi
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
  on ss && { tcp+=("$(pt ss)"); udp+=("$(pt ss)"); }
  on trojan && tcp+=("$(pt trojan)")
  on vmess && tcp+=("$(pt vmess)")
  on shadowtls && tcp+=("$(pt shadowtls)")
  if has ufw && ufw status 2>/dev/null | grep -q "^Status: active"; then
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
b64() { printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'; }
vmess_b64() { # 名称 地址 端口 host path tls
  b64 "$(jq -cn --arg ps "$1" --arg add "$2" --arg port "$3" --arg id "$UUID" --arg host "$4" --arg path "$5" --arg tls "$6" \
    '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto", net:"ws", type:"none", host:$host, path:$path, tls:$tls, sni:$host}')"
}

show_nodes() {
  load_env
  [ -f "$CONF" ] || die "尚未安装"
  local ip n host sfx nn ips; ips=$(node_ips) || exit 1; nn=$(urlenc "${NAME}")
  {
   while read -r ip sfx; do
    n="$nn$sfx"
    on hy2     && echo "hysteria2://$UUID@$ip:$(pt hy2)?sni=www.bing.com&alpn=h3&insecure=1#$n-hy2"
    on reality && echo "vless://$UUID@$ip:$(pt reality)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$REALITY_PUBLIC&sid=$REALITY_SID&type=tcp#$n-reality"
    on tuic    && echo "tuic://$UUID:$UUID@$ip:$(pt tuic)?sni=www.bing.com&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#$n-tuic"
    on trojan  && echo "trojan://$UUID@$ip:$(pt trojan)?security=tls&sni=www.bing.com&allowInsecure=1&type=tcp#$n-trojan"
    on vmess   && echo "vmess://$(vmess_b64 "${NAME}$sfx-vmess" "${ip//[\[\]]/}" "$(pt vmess)" "" "/vmess?ed=2560" "")"
    on ss      && echo "ss://$(b64 "2022-blake3-aes-128-gcm:$SS_PASSWORD")@$ip:$(pt ss)#$n-ss"
    on anytls  && echo "anytls://$UUID@$ip:$(pt anytls)?sni=www.bing.com&insecure=1#$n-anytls"
    on shadowtls && echo "ss://$(b64 "2022-blake3-aes-128-gcm:$SS_PASSWORD")@$ip:$(pt shadowtls)?shadow-tls=$(b64 "{\"version\":\"3\",\"host\":\"www.bing.com\",\"password\":\"$UUID\"}")#$n-shadowtls"
    on socks   && echo "socks5://${UUID%%-*}:$UUID@$ip:$(pt socks)#$n-socks5"
   done <<<"$ips"
    n=$nn
    if on argo; then
      host=$(argo_domain)
      if [ -n "$host" ]; then
        case "${ARGO_PROTO:-vless}" in
          vmess)  echo "vmess://$(vmess_b64 "${NAME}-argo" "$CFIP" "$CFPORT" "$host" "/argo?ed=2560" tls)" ;;
          trojan) echo "trojan://$UUID@$CFIP:$CFPORT?security=tls&sni=$host&fp=chrome&type=ws&host=$host&path=%2Fargo%3Fed%3D2560#$n-argo" ;;
          *)      echo "vless://$UUID@$CFIP:$CFPORT?encryption=none&security=tls&sni=$host&fp=chrome&type=ws&host=$host&path=%2Fargo%3Fed%3D2560#$n-argo" ;;
        esac
      else
        warn "未获取到 Argo 域名，稍后执行 sb nodes 再试" >&2
      fi
    fi
  } > "$NODES.$$"
  chmod 600 "$NODES.$$"; mv -f "$NODES.$$" "$NODES"
  if sub_on && [ -d "$DIR/sub/$SUB_TOKEN" ]; then
    { base64 -w0 "$NODES" 2>/dev/null || base64 "$NODES" | tr -d '\n'; } > "$DIR/sub/$SUB_TOKEN/sub"
    cp -f "$NODES" "$DIR/sub/$SUB_TOKEN/raw"
  fi
  echo; c "1;35" "$(cat "$NODES")"; echo
  info "Base64（客户端可直接导入）："
  base64 -w0 "$NODES" 2>/dev/null || base64 "$NODES" | tr -d '\n'; echo
  { on hy2 || on tuic || on anytls || on trojan; } && warn "Hy2/TUIC/AnyTLS/Trojan 用自签证书，客户端需开启“跳过证书验证”"
  on shadowtls && warn "ShadowTLS 链接为 Shadowrocket 格式；其他客户端手填：SS-2022 aes-128-gcm + ShadowTLS v3，SNI www.bing.com，密码=UUID"
  [ -n "${ARGO_TOKEN:-}" ] && on argo && warn "固定隧道：请在 Cloudflare 把 $ARGO_DOMAIN 指向 http://localhost:$ARGO_PORT"
  if sub_on && [ -n "${host:-}" ]; then
    info "订阅链接（Base64，只经 Argo 域名访问；明文把 sub 换成 raw）："
    echo "https://$host/ui/$SUB_TOKEN/sub"
    [ -n "${ARGO_TOKEN:-}" ] && warn "固定隧道需在 Cloudflare 同域名再加一条路由：路径 ^/ui/$SUB_TOKEN/ → http://localhost:$SUB_PORT，并排在无路径那条之前"
    [ -z "${ARGO_TOKEN:-}" ] && warn "临时隧道重启后域名会变，订阅链接随之变化；执行 sb nodes 查看新链接"
  fi
  return 0
}

# ---------- 主要操作 ----------
trim_logs() { local f; for f in "$DIR"/*.log; do [ -f "$f" ] && [ "$(wc -c <"$f")" -gt 5242880 ] && : > "$f"; done; return 0; }

tune_sysctl() { # BBR+fq（TCP 协议提速）与更大的 UDP 缓冲（Hy2/TUIC 的 QUIC 吞吐）
  [ "${TUNE:-1}" = 0 ] && { rm -f "$SYSCTL_FILE"; return 0; }
  [ -f "$SYSCTL_FILE" ] && return 0
  mkdir -p "${SYSCTL_FILE%/*}"; local f=$SYSCTL_FILE.new
  : > "$f"
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || modprobe tcp_bbr 2>/dev/null; then
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >> "$f"
  fi
  printf 'net.core.rmem_max=16777216\nnet.core.wmem_max=16777216\n' >> "$f"
  mv -f "$f" "$SYSCTL_FILE"
  sysctl -q -p "$SYSCTL_FILE" >/dev/null 2>&1 || warn "内核参数未完全生效（容器/OpenVZ 常见），不影响使用"
  return 0
}

apply() { # 生成配置并（重）启动
  save_env
  trim_logs; tune_sysctl
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
    warn "检测到已安装，将保留现有设置重新安装（命令行传入的变量优先）"
    local k ov=()
    for k in UUID PORT $PORT_KEYS PROTOCOLS IP_MODE ARGO_PROTO SUB SNI ARGO_PORT ARGO_TOKEN ARGO_DOMAIN CFIP CFPORT NAME SB_VERSION TUNE; do
      [ -n "${!k+x}" ] && ov+=("$k=${!k}")
    done
    load_env
    for k in "${ov[@]}"; do printf -v "${k%%=*}" '%s' "${k#*=}"; done
    [ ${#ov[@]} -gt 0 ] && info "使用传入的：${ov[*]%%=*}"
  fi
  mkdir -p "$DIR"; chmod 700 "$DIR"

  if [ -z "${PROTOCOLS:-}" ] && [ -t 0 ]; then
    PROTOCOLS=$DEFAULT_PROTOCOLS
    PROTOCOLS=$(pick_protocols "默认 abcdh") || exit 1
  fi
  PROTOCOLS=${PROTOCOLS:-$DEFAULT_PROTOCOLS}
  UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
  valid_uuid "$UUID" || die "UUID 格式不对：$UUID"
  SNI=${SNI:-www.iij.ad.jp}
  CFIP=${CFIP:-saas.sin.fan}
  CFPORT=${CFPORT:-443}
  NAME=${NAME:-$(hostname | cut -c1-20)}
  if [ -z "${PORT:-}" ] && [ -t 0 ]; then
    # 交互安装：逐个询问已选直连协议的端口，回车随机
    local x v pk
    PORT=$(rand_base)
    for x in $DIRECT; do
      on "$x" || continue
      pk="$(tr a-z A-Z <<<"$x")_PORT"
      [ -n "${!pk:-}" ] && continue
      while :; do
        v=$(ask "$x 端口（回车随机）" "")
        [ -n "$v" ] || v=$(rand_port)
        valid_port "$v" && break; warn "端口无效：$v"
      done
      printf -v "$pk" '%s' "$v"
    done
  fi
  PORT=${PORT:-$(rand_base)}
  valid_port "$PORT" || die "端口无效：$PORT"
  ARGO_PORT=${ARGO_PORT:-$(rand_port)}
  check_ports
  if on argo && [ -z "${ARGO_PROTO:-}" ] && [ -t 0 ] && [ ! -f "$ENV_FILE" ]; then
    echo "Argo 隧道协议：" >&2; printf '  %s\n' "1. vless（默认）" "2. vmess" "3. trojan" >&2
    case "$(ask "请选择（回车 vless）" "")" in
      2) ARGO_PROTO=vmess ;; 3) ARGO_PROTO=trojan ;; *) ARGO_PROTO=vless ;;
    esac
  fi
  ARGO_PROTO=${ARGO_PROTO:-vless}
  if on argo && [ -z "${ARGO_TOKEN:-}" ] && [ -t 0 ] && [ ! -f "$ENV_FILE" ]; then
    ARGO_TOKEN=$(ask "Argo 固定隧道 Token（回车用临时隧道）" "")
    [ -n "$ARGO_TOKEN" ] && ARGO_DOMAIN=$(ask "固定隧道域名" "${ARGO_DOMAIN:-}")
  fi
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
  local kv k v p only_view=1
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    case "$k" in IP_MODE|NAME|CFIP|CFPORT) ;; *) only_view=0 ;; esac
    case "$k" in
      PROTOCOLS) for p in ${v//,/ }; do [[ ",$ALL_PROTOCOLS," == *",$p,"* ]] || die "未知协议：$p"; done; PROTOCOLS=$v ;;
      ARGO_PROTO) case "$v" in vless|vmess|trojan) ARGO_PROTO=$v ;; *) die "ARGO_PROTO 只能是 vless/vmess/trojan" ;; esac ;;
      SUB) case "$v" in 0|1) SUB=$v ;; *) die "SUB 只能是 0 或 1" ;; esac ;;
      TUNE) case "$v" in 0|1) TUNE=$v; rm -f "$SYSCTL_FILE" ;; *) die "TUNE 只能是 0 或 1" ;; esac ;;
      SUB_TOKEN) [ -n "$v" ] || v=$(openssl rand -hex 12); [[ "$v" =~ ^[A-Za-z0-9_-]{8,64}$ ]] || die "SUB_TOKEN 需 8-64 位字母数字"; rm -rf "$DIR/sub"; SUB_TOKEN=$v ;;
      IP_MODE) case "$v" in auto|4|6|both) IP_MODE=$v ;; *) die "IP_MODE 只能是 auto/4/6/both" ;; esac ;;
      UUID) valid_uuid "$v" || die "UUID 格式不对：$v"; UUID=$v ;;
      SNI|CFIP|CFPORT|NAME|ARGO_DOMAIN|ARGO_TOKEN) printf -v "$k" '%s' "$v" ;;
      PORT|ARGO_PORT) valid_port "$v" || die "端口无效：$v"; printf -v "$k" '%s' "$v" ;;
      REALITY_PORT|HY2_PORT|TUIC_PORT|ANYTLS_PORT|SOCKS_PORT|SS_PORT|TROJAN_PORT|VMESS_PORT|SHADOWTLS_PORT)
        [ -z "$v" ] || valid_port "$v" || die "端口无效：$v"; printf -v "$k" '%s' "$v" ;;
      *) die "不支持的设置：$k" ;;
    esac
  done
  check_ports
  if on argo && [ -n "${ARGO_TOKEN:-}" ] && [ -z "${ARGO_DOMAIN:-}" ]; then die "固定隧道需要 ARGO_DOMAIN"; fi
  if [ "$only_view" = 1 ]; then save_env  # 只影响节点显示，不重启（避免临时隧道换域名）
  else apply; fi
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

do_upgrade() { # 更新本脚本：下载 → 语法检查 → 替换，不改配置
  need_root
  local t; t=$(mktemp)
  curl -fsSL -m 30 -o "$t" "$SCRIPT_URL" || { rm -f "$t"; die "下载脚本失败"; }
  bash -n "$t" || { rm -f "$t"; die "新脚本语法错误，已放弃"; }
  install -m 700 "$t" "$SELF"; rm -f "$t"
  info "脚本已更新：v$SCRIPT_VERSION → v$(sed -n 's/^SCRIPT_VERSION="\(.*\)"/\1/p' "$SELF")"
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
  rm -f "$SYSCTL_FILE"
  rm -rf "$DIR" "$SELF"
  info "已卸载（防火墙规则如有需要请手动删除）"
}

port_menu() {
  local list=() x i k
  for x in $DIRECT; do on "$x" && list+=("$x"); done
  echo "  1. 起始端口（各协议顺延）：$PORT"
  for i in "${!list[@]}"; do echo "  $((i + 2)). ${list[$i]}：$(pt "${list[$i]}")"; done
  echo "  0. 返回"
  i=$(ask "请选择" "")
  case "$i" in
    0|"") return ;;
    1) do_set "PORT=$(ask "新的起始端口" "${PORT:-}")" ;;
    *) [[ "$i" =~ ^[0-9]+$ ]] && x=${list[$((i - 2))]:-} || x=""
       [ -n "$x" ] || { warn "无效选项"; return; }
       k="$(tr a-z A-Z <<<"$x")_PORT"
       do_set "$k=$(ask "$x 新端口（留空=恢复按起始端口推算）" "")" ;;
  esac
}

# 协议选择：字母 a-j（也接受数字 1-10），可连写 abce 或用空格/逗号分隔；输出逗号列表，回车输出空
pick_protocols() {
  local all=(${ALL_PROTOCOLS//,/ }) desc=("Hysteria2" "VLESS-Reality" "Argo 隧道（${ARGO_PROTO:-vless}-WS）" "TUIC v5" "Trojan（TLS）" "VMess-WS" "Shadowsocks-2022" "AnyTLS" "ShadowTLS v3" "Socks5")
  local L=abcdefghij i n sel="" tok idx
  if [ -f "$ENV_FILE" ]; then echo "  ✓ = 当前已安装" >&2; else echo "  ✓ = 默认选中" >&2; fi
  for i in "${!all[@]}"; do
    # 勾放在行尾：✓ 在中文终端里宽度不定，放行首会让后面错位
    if on "${all[$i]}"; then printf '  %s. %s \033[1;32m✓\033[0m\n' "${L:$i:1}" "${desc[$i]}" >&2
    else printf '  %s. %s\n' "${L:$i:1}" "${desc[$i]}" >&2; fi
  done
  n=$(ask "输入要启用的协议（如 abce，回车=${1:-不变}）" "")
  [ -n "$n" ] || return 0
  n=$(tr 'A-Z,' 'a-z ' <<<"$n")
  if [[ "$n" =~ [0-9] ]]; then n=${n//[^0-9 ]/}; else n=$(sed 's/[^a-z]//g; s/./& /g' <<<"$n"); fi
  for tok in $n; do
    if [[ "$tok" =~ ^[0-9]+$ ]]; then idx=$((tok - 1)); else idx=${L%%"$tok"*}; idx=${#idx}; fi
    [ "$idx" -ge 0 ] && [ "$idx" -lt ${#all[@]} ] || { err "无效选项：$tok"; return 1; }
    [[ ",$sel," == *",${all[$idx]},"* ]] || sel+="${sel:+,}${all[$idx]}"
  done
  echo "$sel"
}

proto_menu() {
  local sel
  sel=$(pick_protocols) || return
  [ -n "$sel" ] && do_set "PROTOCOLS=$sel"
}

ip_menu() {
  echo "  当前：${IP_MODE:-auto}"
  printf '  %s\n' "1. 自动（优先 IPv4）" "2. 仅 IPv4" "3. 仅 IPv6" "4. 同时输出 IPv4 和 IPv6" "0. 返回"
  case "$(ask "请选择" "")" in
    1) do_set IP_MODE=auto ;; 2) do_set IP_MODE=4 ;; 3) do_set IP_MODE=6 ;; 4) do_set IP_MODE=both ;;
  esac
}

argo_menu() {
  on argo || { warn "未启用 Argo，请先在「选择协议」里勾选"; return; }
  local t="临时隧道"; [ -n "${ARGO_TOKEN:-}" ] && t="固定隧道（$ARGO_DOMAIN）"
  echo "  隧道：$t   协议：${ARGO_PROTO:-vless}   订阅：$(sub_on && echo 开启 || echo 关闭)"
  printf '  %s\n' "1. 设置固定隧道" "2. 改回临时隧道" "3. 切换隧道协议" "4. 订阅开/关" "5. 更换订阅令牌" "0. 返回"
  case "$(ask "请选择" "")" in
    1) do_set "ARGO_TOKEN=$(ask "隧道 Token" "")" "ARGO_DOMAIN=$(ask "隧道域名" "${ARGO_DOMAIN:-}")" ;;
    2) do_set "ARGO_TOKEN=" "ARGO_DOMAIN=" ;;
    3) printf '  %s\n' "1. vless" "2. vmess" "3. trojan"
       case "$(ask "请选择" "")" in
         1) do_set ARGO_PROTO=vless ;; 2) do_set ARGO_PROTO=vmess ;; 3) do_set ARGO_PROTO=trojan ;;
       esac ;;
    4) if sub_on; then do_set SUB=0; else do_set SUB=1; fi ;;
    5) do_set SUB_TOKEN= ;;
  esac
}

update_menu() {
  echo "  内核：$("$BIN_SB" version 2>/dev/null | head -1 | awk '{print $3}')   脚本：v$SCRIPT_VERSION"
  printf '  %s\n' "1. 更新 sing-box/cloudflared 内核" "2. 更新本脚本" "0. 返回"
  case "$(ask "请选择" "")" in
    1) do_update ;; 2) do_upgrade ;;
  esac
}

menu_status() {
  local a="" s; s=$(svc_active sing-box && echo 运行中 || echo 未运行)
  if on argo; then
    a="  Argo：$(svc_active sb-argo && echo 运行中 || echo 未运行)（$([ -n "${ARGO_TOKEN:-}" ] && echo 固定 || echo 临时)）"
  fi
  if [ "$s" = 运行中 ]; then info "sing-box：$s$a"; else err "sing-box：$s$a"; fi
  echo "协议：${PROTOCOLS//,/ }"
}

menu() {
  local x; detect_init
  while true; do
    load_env
    echo
    c "1;36" "==== sing-box 管理 v$SCRIPT_VERSION ===="
    if [ ! -f "$ENV_FILE" ]; then
      warn "未安装"
      echo " 1. 安装"
      echo " 0. 退出"
      x=$(ask "请选择" "")
      case "$x" in 1) ( do_install ) ;; 0) exit 0 ;; *) warn "无效选项" ;; esac
      continue
    fi
    menu_status
    cat <<'EOF'
 1. 查看节点 / 订阅
 ─── 配置 ───
 2. 选择协议
 3. 修改端口
 4. 修改 UUID
 5. 节点 IP（v4/v6）
 6. Argo 隧道 / 订阅
 ─── 维护 ───
 7. 重启
 8. 更新
 9. 重装（保留设置）
10. 卸载
 0. 退出
EOF
    x=$(ask "请选择" "")
    [ "$x" = 0 ] && exit 0
    ( case "$x" in
      1) show_nodes ;;
      2) proto_menu ;;
      3) port_menu ;;
      4) x=$(ask "新 UUID（回车随机生成）" ""); do_set "UUID=${x:-$(cat /proc/sys/kernel/random/uuid)}" ;;
      5) ip_menu ;;
      6) argo_menu ;;
      7) do_restart ;;
      8) update_menu ;;
      9) do_install ;;
      10) [ "$(ask "确认卸载？输入 y" "")" = y ] && do_uninstall ;;
      *) warn "无效选项" ;;
    esac )  # 子 shell：某项出错只返回菜单，不退出
  done
}

case "${1:-menu}" in
  install)   do_install ;;
  nodes)     show_nodes ;;
  set)       shift; do_set "$@" ;;
  restart)   do_restart ;;
  status)    do_status ;;
  update)    do_update ;;
  upgrade)   do_upgrade ;;
  uninstall) do_uninstall ;;
  menu)      need_root; menu ;;
  -h|--help|help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0" ;;
  *) die "未知命令：$1（sb help 查看用法）" ;;
esac
