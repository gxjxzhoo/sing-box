# sb-modular 修复清单（基于 v2.6.1 modified）

入口文件名保持 `sb.sh`，因此原来的一键命令不变：
`bash <(curl -fsSL https://raw.githubusercontent.com/gxjxzhoo/sing-box/refs/heads/main/sb/sb.sh)`
（把本包内容覆盖到仓库 `sb/` 目录即可：`sb.sh` + `lib/*.sh`）

## 严重
1. 服务状态判断（nginx.sh）：`*"running"*` 会匹配 "not running" → 改为基于返回码的 `_svc_state`。启动不再被误判"已在运行"，重启后的校验也不再恒成功。
2. ARGO_PORT 持久化（common.sh / system.sh）：端口、优选域名(CFIP/CFPORT)、节点前缀写入 install.conf，已安装时启动即回读；旧版 install.conf 缺失时从 nginx 配置回读。
3. 内部 WS 端口（nginx.sh）：新增 `write_argo_ws_conf`，proxy_pass 端口以 inbounds.json 实际监听端口为准；改 Argo 对外端口改为重新生成配置。
4. argo.log（argo.sh / common.sh）：每次启动覆盖写；域名解析统一为 `parse_argo_domain`（取最后一个、排除 api.trycloudflare.com）。
5. config.sh 开头 `local x=$(..); $?` 恒 0 → 已修。
6. 菜单"重启 Argo"在固定隧道下现在会真正重启。
7. warp.sh 删除代理出站：先清理路由规则与 `route.final`，再删出站。
8. firewall.sh：插入位置自动夹到链长度内；持久化逻辑改正（Alpine 用独立服务 sb-iptables；Debian 用 netfilter-persistent；RHEL 提示）；不再把 firewalld public zone 设为 ACCEPT，不再改 FORWARD 策略；ip6tables 使用 ipv6-icmp。

## 中
- install.sh：conf_dir 总是创建；work_dir 755（原 777）；private.key 600；argo-start.sh 700；tunnel.json 600；SKIP_DIRECT=1 不再询问端口；安装期间 SKIP_DIRECT 不被旧 install.conf 覆盖；订阅端口占用时自动顺延；保留官方包内 libcronet*。
- 前缀/SNI：sed 转义（`&`、`|`、`\`），前缀禁止 `#`；节点备注 sed 全部加 `^` 锚定（`ss://` 规则不再误中 `vless://`）；SNI/优选域名/端口输入校验。
- HY2 端口跳跃：精确增删规则（hy2_hop.conf 记录），不再 `-F` 清空 PREROUTING；校验范围；改 HY2 端口时同步 DNAT 与 mport；保留原链接参数（sni 等）。
- telegram.sh：以 API 返回 `"ok":true` 判断推送结果；HTML 正文先截断再加标签；监控跳过未安装组件，nginx 增加进程判断；卸载时清理监控 cron。
- nginx.sh：默认不再覆盖用户的 nginx.conf / mime.types、不删 sites-enabled/default、不 pkill 全部 nginx；仅在 `nginx -t` 失败时才重写主配置（原始文件另存 nginx.conf.sb-orig + 时间戳备份）；安装前已有 nginx 的机器卸载时保留 nginx 并还原主配置；仅在机器支持 IPv6 时输出 `listen [::]`；`/tmp/sb-*` 改 `/run/sb-*`。
- 订阅关闭：同时移除 Argo 入口上的 `/s/<token>`。
- config.sh：AnyTLS 分支 `break` 改 `return 1`。
- 删除协议后同步清空直连缓存，避免"复活"。

## 安全 / 低
- `sb` 快捷方式：指向本模块化入口（上面的 URL），并在本机缓存一份模块，GitHub 不通时回退本机缓存。
- 菜单 11：改 https 并需确认后才以 root 执行第三方脚本。
- 添加代理出站：不再把带账号密码的代理地址发送给第三方检测 API，改为本机 curl 测试；规则出站候选中加入 wireguard-out；只给带 rule_set 的规则改 outbound。
- `change_hosts` 只在缺少 localhost 映射时补充；卸载时清理 /usr/bin/sb。
- 安装依赖补 curl。

## 未改动（设计取舍，需你自行决定）
- WARP 使用脚本内置的共享 WireGuard 账号/密钥。
- 分流规则集来自第三方域名 main.ssss.nyc.mn。
- sing-box 官方包失败后仍会回退到第三方镜像二进制（eooce.com），无校验和。
- cloudflared 官方二进制无校验和。
- 2026-10-11: hy2 链接不再输出 obfs=none（nodes.sh；开/关端口跳跃时同时清除旧链接里的 obfs=none）

## 复查补充
- `--force` 重装：卸载后重置回"环境变量/默认值"，不再沿用旧安装回读的端口/优选/前缀/SKIP_DIRECT/订阅端口。
- ufw 或 firewalld 在用时，不再自动安装 iptables-persistent。
- nginx 重启：运行中且 `nginx -t` 通过时用 reload，不再杀掉全部 nginx 进程。
- `sb` 快捷方式的临时脚本放进独立临时目录。

## HY2 端口跳跃补丁（2026-10-12）
- 开机自动恢复：新增 `hy2-hop-restore.sh` + 开机服务（systemd `sb-hy2-hop.service` / OpenRC `sb-hy2-hop`），按 `hy2_hop.conf` 补回 DNAT 规则。修复 ufw/firewalld 在用时 `persist_iptables` 跳过保存、重启后跳跃失效的问题
- 删除跳跃时同步移除开机服务与恢复脚本
- 输入校验前置：先校验起始端口再计算默认结束端口；默认结束端口不超过 65535；起始端口限定 1024-65534
- 新增区间冲突检查：跳跃区间包含任何已用入站端口（HY2 自身、TUIC 等）时拒绝
- 卸载（菜单卸载 / 自动卸载）时清除跳跃 DNAT 规则与开机服务，不再残留
