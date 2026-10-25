# sing-box

sing-box 一键脚本（单文件 `sb.sh`，v3）。

- 直连入站：VLESS-Reality、Hysteria2、TUIC v5、AnyTLS
- Argo：VLESS-WS 经 Cloudflare 隧道（临时隧道或固定 Token），只监听 127.0.0.1，不装 Nginx、不对公网开订阅
- sing-box / cloudflared 均从官方 GitHub Release 下载并校验 sha256
- 安装后 `sb` 命令运行本机副本，不再每次联网拉脚本
- 支持 systemd / OpenRC（Alpine 需先 `apk add bash curl`）

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/gxjxzhoo/sing-box/main/sb.sh) install
```

免交互示例：

```bash
PORT=20000 ARGO_TOKEN=xxx ARGO_DOMAIN=sb.example.com \
  bash <(curl -fsSL https://raw.githubusercontent.com/gxjxzhoo/sing-box/main/sb.sh) install
```

## 常用命令

```bash
sb               # 菜单
sb nodes         # 查看节点
sb set PORT=30000 UUID=...      # 改设置并重建
sb set PROTOCOLS=reality,hy2    # 只开部分协议
sb restart | status | update | upgrade | uninstall   # upgrade=更新脚本本身
```

固定隧道：在 Cloudflare Zero Trust 把域名的 Public Hostname 设为 HTTP → `127.0.0.1:8001`（ARGO_PORT 默认 8001，路径留空；`sb nodes` 会自检）。

旧版模块化脚本仍在 `sb/` 目录。
