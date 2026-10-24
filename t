#!/bin/bash
# ============================================================
#  TUIC v5 单协议一键脚本（基于 sing-box）
#  - 可与 Hugo 12 协议脚本共存在同一台 VPS
#  - 独立目录 /etc/tuic-single，独立服务 tuic-single，独立内核副本
#  - 不会往 /etc/sing-box 里放任何文件（那个目录会被 sing-box 合并读取）
# ============================================================

SCRIPT_VERSION="1.0.0"

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 权限运行此脚本！(例如: sudo bash ...)"
  exit 1
fi

DIR="/etc/tuic-single"
INFO="$DIR/info"
CFG="$DIR/config.json"
CERT="$DIR/tuic.crt"
KEY="$DIR/tuic.key"
BIN="/usr/local/bin/tuic-singbox"
SVC="tuic-single"
LINE="============================================================"

# ---------- 工具函数 ----------

get_ip() {
    local ip u
    for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
        ip=$(curl -s4 -m 6 "$u" | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
}

install_deps() {
    local need=""
    for c in curl openssl; do
        command -v "$c" >/dev/null 2>&1 || need="$need $c"
    done
    [ -z "$need" ] && return 0
    echo "==> 安装依赖:$need"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y $need ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $need ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $need ca-certificates
    fi
}

# 端口是否已被占用（TCP 或 UDP 任一监听即视为占用）
port_in_use() {
    ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$1$"
}

random_port() {
    local p i
    for i in $(seq 1 30); do
        p=$(shuf -i 20000-59999 -n 1)
        if ! port_in_use "$p"; then
            echo "$p"
            return
        fi
    done
}

valid_port() {
    local np="$1" op="$2"
    if ! [[ "$np" =~ ^[0-9]+$ ]] || [ "$np" -lt 1 ] || [ "$np" -gt 65535 ]; then
        echo "❌ 端口必须是 1-65535 之间的数字。"
        return 1
    fi
    if [ -n "$op" ] && [ "$np" = "$op" ]; then
        echo "❌ 新端口与当前端口相同。"
        return 1
    fi
    if port_in_use "$np"; then
        echo "❌ 端口 $np 已被系统上其他程序占用（包括 Hugo 脚本的协议）。"
        return 1
    fi
    return 0
}

fw_open() {
    local p="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${p}/udp" >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

fw_close() {
    local p="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "${p}/udp" >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --remove-port="${p}/udp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

# ---------- 内核 ----------

# 把系统里的 sing-box 复制一份给本服务独占使用（不受 Hugo 脚本卸载/升级影响）
copy_core() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo "==> 未检测到 sing-box，正在安装..."
        if command -v apt-get >/dev/null 2>&1; then
            bash <(curl -fsSL https://sing-box.app/deb-install.sh)
        else
            bash <(curl -fsSL https://sing-box.app/install.sh)
        fi
    fi
    if ! command -v sing-box >/dev/null 2>&1; then
        if [ -x "$BIN" ]; then
            echo "ℹ️  系统未找到 sing-box，继续使用已有内核副本。"
            return 0
        fi
        echo "❌ sing-box 安装失败，请检查网络后重试。"
        return 1
    fi
    install -m 755 "$(command -v sing-box)" "$BIN" || return 1
    echo "✅ 内核副本: $("$BIN" version 2>/dev/null | awk 'NR==1{print $3}')"
}

# ---------- 配置 ----------

load_info() {
    [ -f "$INFO" ] || return 1
    # shellcheck disable=SC1090
    . "$INFO"
    [ -n "$IP" ] && [ -n "$PORT" ] && [ -n "$UUID" ] && [ -n "$PASS" ]
}

save_info() {
    cat > "$INFO" << INFOEOF
IP="$IP"
PORT="$PORT"
UUID="$UUID"
PASS="$PASS"
INFOEOF
    chmod 600 "$INFO"
}

write_config() {
    cat > "$CFG" << CFGEOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "0.0.0.0",
      "listen_port": $PORT,
      "users": [ { "uuid": "$UUID", "password": "$PASS" } ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "certificate_path": "$CERT",
        "key_path": "$KEY"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "bittorrent", "action": "reject" },
      { "ip_is_private": true, "action": "reject" }
    ],
    "final": "direct"
  }
}
CFGEOF
    chmod 600 "$CFG"
}

write_service() {
    cat > /etc/systemd/system/$SVC.service << SVCEOF
[Unit]
Description=TUIC v5 (single) via sing-box
After=network.target

[Service]
Type=simple
ExecStart=$BIN run -c $CFG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
}

make_cert() {
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$KEY" -out "$CERT" \
        -days 3650 -subj "/CN=bing.com" \
        -addext "subjectAltName=DNS:bing.com" 2>/dev/null
    chmod 600 "$KEY"
    chmod 644 "$CERT"
}

# 检查配置并(重)启动服务，失败时打印原因
apply_and_start() {
    if ! "$BIN" check -c "$CFG"; then
        echo "❌ 配置检查未通过（上面是具体报错）。"
        return 1
    fi
    systemctl enable "$SVC" >/dev/null 2>&1
    systemctl restart "$SVC"
    sleep 2
    if ! systemctl is-active --quiet "$SVC"; then
        echo "❌ 服务启动失败，最近日志:"
        journalctl -u "$SVC" -n 20 --no-pager
        return 1
    fi
    return 0
}

# ---------- 显示 ----------

show_info() {
    if ! load_info; then
        echo "❌ 未找到已部署的 TUIC，请先选择「部署」。"
        return 1
    fi
    local link
    link="tuic://$UUID:$PASS@$IP:$PORT?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=bing.com&udp_relay_mode=native#TUIC-Single"

    echo "$LINE"
    echo "✨ TUIC v5 节点 (UDP $PORT):"
    echo "$LINE"
    echo "$link"
    echo ""
    echo "─── sing-box 客户端出站配置 ───"
    cat << SBEOF
{
  "type": "tuic", "tag": "TUIC-Single",
  "server": "$IP", "server_port": $PORT,
  "uuid": "$UUID", "password": "$PASS",
  "congestion_control": "bbr",
  "tls": { "enabled": true, "insecure": true, "server_name": "bing.com", "alpn": [ "h3" ] }
}
SBEOF
    echo ""
    echo "─── Clash Meta 节点 (加到 proxies 下) ───"
    cat << CLEOF
- name: "TUIC-Single"
  type: tuic
  server: $IP
  port: $PORT
  uuid: "$UUID"
  password: "$PASS"
  alpn:
    - h3
  congestion-controller: bbr
  udp-relay-mode: native
  sni: bing.com
  skip-cert-verify: true
CLEOF
    echo "$LINE"
    if command -v qrencode >/dev/null 2>&1; then
        echo "📱 扫码导入:"
        qrencode -t ANSIUTF8 "$link"
        echo "$LINE"
    fi
    echo "⚠️  请在云安全组放行 UDP $PORT（TUIC 走 UDP，不是 TCP）。"
    echo "⚠️  使用自签证书，客户端需开启「允许不安全 / 跳过证书验证」。"
    echo "$LINE"
}

# ---------- 部署 ----------

install_tuic() {
    install_deps
    copy_core || exit 1

    mkdir -p "$DIR"
    systemctl stop "$SVC" 2>/dev/null

    local defp inp oldp
    oldp=""
    load_info && oldp="$PORT"

    defp=$(random_port)
    [ -z "$defp" ] && defp=24443
    while true; do
        read -p "请输入 TUIC 监听端口（UDP，直接回车使用随机端口 $defp）: " inp
        inp=${inp:-$defp}
        # 重新部署时允许沿用原端口
        if [ -n "$oldp" ] && [ "$inp" = "$oldp" ]; then
            break
        fi
        valid_port "$inp" "" && break
    done
    PORT="$inp"

    IP=$(get_ip)
    if [ -z "$IP" ]; then
        read -p "❌ 自动获取公网 IP 失败，请手动输入服务器公网 IP: " IP
    fi
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PASS=$(openssl rand -hex 8)

    echo "==> 生成自签名证书..."
    make_cert
    save_info
    write_config
    write_service

    echo "==> 启动服务..."
    if ! apply_and_start; then
        exit 1
    fi
    fw_open "$PORT"
    [ -n "$oldp" ] && [ "$oldp" != "$PORT" ] && fw_close "$oldp"

    echo "✅ 部署完成！"
    echo ""
    show_info
}

change_port() {
    if ! load_info; then
        echo "❌ 未找到已部署的 TUIC，请先选择「部署」。"
        return 1
    fi
    local newp oldp
    oldp="$PORT"
    read -p "请输入新的 UDP 端口 (当前 $oldp): " newp
    valid_port "$newp" "$oldp" || return 1

    cp "$INFO" "$INFO.bak"
    cp "$CFG" "$CFG.bak"
    PORT="$newp"
    save_info
    write_config
    if ! apply_and_start; then
        echo "❌ 已回滚到原端口。"
        cp "$INFO.bak" "$INFO"
        cp "$CFG.bak" "$CFG"
        systemctl restart "$SVC"
        return 1
    fi
    fw_open "$newp"
    fw_close "$oldp"
    echo "✅ 端口已由 $oldp 改为 $newp，凭证不变。请在云安全组放行 UDP $newp，并更新客户端。"
    echo ""
    show_info
}

check_status() {
    echo "$LINE"
    systemctl status "$SVC" --no-pager 2>&1 | head -12
    echo ""
    echo "🔍 监听端口:"
    ss -lnup 2>/dev/null | grep -E "tuic-singbox|sing-box" | awk '{print $1, $5}'
    echo ""
    echo "🔍 最近 15 行日志:"
    journalctl -u "$SVC" -n 15 --no-pager 2>&1
    echo "$LINE"
}

sync_core() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo "❌ 系统里没有 sing-box，无法同步。可以先运行官方安装脚本安装/升级系统版。"
        return 1
    fi
    local old new
    old=$("$BIN" version 2>/dev/null | awk 'NR==1{print $3}')
    copy_core || return 1
    new=$("$BIN" version 2>/dev/null | awk 'NR==1{print $3}')
    if [ -f "$CFG" ]; then
        if apply_and_start; then
            echo "✅ 内核已同步并重启: $old -> $new"
        else
            echo "⚠️  新内核启动失败，请查看上面的日志。"
            return 1
        fi
    fi
}

uninstall_tuic() {
    echo "$LINE"
    echo "⚠️  将卸载 TUIC 单协议服务并删除其配置，不会影响 Hugo 脚本和系统的 sing-box。"
    read -p "确定要卸载吗？(y/N): " CONFIRM
    case "$CONFIRM" in
        [yY][eE][sS]|[yY])
            load_info && fw_close "$PORT"
            systemctl stop "$SVC" 2>/dev/null
            systemctl disable "$SVC" 2>/dev/null
            rm -f /etc/systemd/system/$SVC.service
            systemctl daemon-reload
            rm -rf "$DIR"
            rm -f "$BIN"
            rm -f /usr/local/bin/tuic
            echo "✅ 卸载完成。"
            exit 0
            ;;
        *)
            echo "❌ 操作已取消。"
            ;;
    esac
}

# ---------- 入口 ----------

case "$1" in
    show)      show_info;      exit 0 ;;
    install)   install_tuic;   exit 0 ;;
    port)      change_port;    exit 0 ;;
    status)    check_status;   exit 0 ;;
    core)      sync_core;      exit 0 ;;
    uninstall) uninstall_tuic; exit 0 ;;
    version)   echo "$SCRIPT_VERSION"; exit 0 ;;
esac

echo "$LINE"
echo "      TUIC v5 单协议一键脚本  v$SCRIPT_VERSION"
echo "$LINE"
echo "  1. 查看节点信息"
echo "  2. 部署 / 重置 TUIC（生成新凭证）"
echo "  3. 修改端口"
echo "  4. 状态检测"
echo "  5. 同步内核（用系统最新 sing-box 更新本服务内核）"
echo "  6. 卸载"
echo "  0. 退出"
echo "$LINE"
echo " 💡 直达: tuic show | install | port | status | core | uninstall"
echo "$LINE"
read -p "请输入数字选择 [0-6]: " CHOICE

case "$CHOICE" in
    1) show_info ;;
    2) install_tuic ;;
    3) change_port ;;
    4) check_status ;;
    5) sync_core ;;
    6) uninstall_tuic ;;
    0) exit 0 ;;
    *) echo "❌ 无效输入，脚本已退出。"; exit 1 ;;
esac
