```
curl -sSL https://raw.githubusercontent.com/zhugo1982/tuic/refs/heads/main/t -o /usr/local/bin/tuic && chmod +x /usr/local/bin/tuic; tuic
```

可以，两个脚本能共存在同一台 VPS 上，我写好了单协议脚本 tuic-single.sh。

为什么不会互相影响
端口分开。 12 协议脚本里的 TUIC 用的是 UDP 9443，新脚本默认随机选一个 20000–59999 之间没被占用的 UDP 端口，也可以自己指定，被占用会拒绝。
文件分开。 新脚本用独立目录 /etc/tuic-single，独立服务 tuic-single，不往 /etc/sing-box 放任何文件。这点很重要：官方 sing-box 服务会把 /etc/sing-box 里所有 .json 合并读取，放进去就会像之前那次一样把服务搞坏。
内核副本独立。 新脚本会复制一份 sing-box 到 /usr/local/bin/tuic-singbox。这样即使你在 12 协议脚本里选「彻底卸载」（它会卸载系统的 sing-box 包），单协议 TUIC 也不受影响。

菜单里选 2 部署，会输出 tuic:// 链接、sing-box 出站配置、Clash 节点，还有二维码（装了 qrencode 的话）。之后用 tuic show、tuic port、tuic status 这些命令管理。快捷命令我取名 tuic，不会和 12 协议脚本的 sub 冲突。

tuic
```
bash <(curl -fsSL https://raw.githubusercontent.com/zhugo1982/tuic/refs/heads/main/muse)
```
```
bash <(curl -Ls https://raw.githubusercontent.com/zhugo1982/tuic/main/muse)
```
```
bash <(curl -fsSL https://raw.githubusercontent.com/zhugo1982/tuic/main/muse)
```
