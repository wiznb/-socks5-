#!/usr/bin/env bash
set -euo pipefail

# ========= 默认值（按你要求）=========
DEFAULT_PORT="26216"
DEFAULT_USER="XnfdcpasL"
DEFAULT_PASS="+a5DBr!r:63NhM11Z"

need_root() {
  if [[ "$(id -u)" != "0" ]]; then
    echo "Error: 需要 root 运行（请用 sudo 或 root）"
    exit 1
  fi
}

detect_iface() {
  local iface=""
  iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  if [[ -z "$iface" ]]; then
    iface="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
  fi
  echo "${iface:-eth0}"
}

validate_port() {
  local p="$1"
  if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
    echo "Error: 端口无效：$p（应为 1-65535）"
    exit 1
  fi
}

create_or_update_user() {
  local u="$1" p="$2"
  local nologin_path="/usr/sbin/nologin"
  command -v nologin >/dev/null 2>&1 && nologin_path="$(command -v nologin)"
  [[ -x "$nologin_path" ]] || nologin_path="/bin/false"

  if id "$u" >/dev/null 2>&1; then
    echo "[i] 用户已存在：$u（将更新密码）"
  else
    echo "[i] 创建系统用户：$u"
    useradd -m -s "$nologin_path" "$u"
  fi
  echo "$u:$p" | chpasswd
}

open_ufw_port_if_needed() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
      ufw allow "${port}/tcp" >/dev/null || true
      echo "[i] ufw 已放行 TCP ${port}"
    fi
  fi
}

write_danted_conf() {
  local port="$1" iface="$2"
  local conf="/etc/danted.conf"

  if [[ -f "$conf" ]]; then
    cp -a "$conf" "${conf}.bak.$(date +%Y%m%d_%H%M%S)"
  fi

  # 核心：internal 绑定 0.0.0.0，避免重启早期 bind fe80:: 失败
  cat > "$conf" <<EOF
logoutput: syslog

# 避免开机 early 阶段网卡/IPv6 还没起来导致 bind 失败
internal: 0.0.0.0 port = ${port}

# 出站网卡（按默认路由推断）
external: ${iface}

user.privileged: root
user.unprivileged: nobody

# 账号密码认证：使用系统用户/密码
socksmethod: username
clientmethod: none

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: error
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  command: bind connect udpassociate
  log: error
  socksmethod: username
}
EOF
}

write_systemd_override() {
  local iface="$1"

  mkdir -p /etc/systemd/system/danted.service.d
  # 清理你之前留下的 .#override.conf 临时文件
  rm -f /etc/systemd/system/danted.service.d/.#override.conf* || true

  cat > /etc/systemd/system/danted.service.d/override.conf <<EOF
[Unit]
Wants=network-online.target
After=network-online.target

[Service]
Restart=always
RestartSec=3

# 保险：等网卡拿到 IPv4 再启动（最多等 60 秒）
ExecStartPre=/bin/sh -c 'iface="${iface}"; if ! ip link show "\$iface" >/dev/null 2>&1; then iface=\$(ip route get 1.1.1.1 2>/dev/null | awk "{for(i=1;i<=NF;i++) if(\\\$i==\\"dev\\"){print \\\$(i+1); exit}}"); [ -z "\$iface" ] && iface=eth0; fi; for i in \$(seq 1 60); do ip -4 addr show dev "\$iface" | grep -q "inet " && exit 0; sleep 1; done; exit 1'
EOF
}

main() {
  need_root

  # 交互输入
  echo "=============================="
  echo "Dante (danted) 不编译一键安装/修复"
  echo "=============================="
  read -r -p "端口 [默认 ${DEFAULT_PORT}]: " PORT
  PORT="${PORT:-$DEFAULT_PORT}"
  validate_port "$PORT"

  read -r -p "账号 [默认 ${DEFAULT_USER}]: " USERNAME
  USERNAME="${USERNAME:-$DEFAULT_USER}"
  if [[ -z "$USERNAME" ]]; then
    echo "Error: 账号不能为空"
    exit 1
  fi

  echo "密码（回车使用默认；输入将隐藏）："
  read -r -s -p "密码: " PASSWORD
  echo
  PASSWORD="${PASSWORD:-$DEFAULT_PASS}"
  if [[ -z "$PASSWORD" ]]; then
    echo "Error: 密码不能为空"
    exit 1
  fi

  echo
  echo "将使用："
  echo "  端口: $PORT"
  echo "  账号: $USERNAME"
  echo "  密码: (已隐藏，长度 ${#PASSWORD})"
  read -r -p "确认继续？[y/N]: " OK
  [[ "$OK" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

  # 仅适配 Debian/Ubuntu（你当前是 Debian）
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if ! echo "${ID:-} ${ID_LIKE:-}" | grep -Eqi 'debian|ubuntu'; then
      echo "Error: 这份脚本是 Debian/Ubuntu 专用。当前：${ID:-unknown}"
      exit 1
    fi
  fi

  IFACE="$(detect_iface)"
  echo "[i] 检测到默认出站网卡：$IFACE"

  echo "[i] 安装 dante-server（不编译）"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server

  create_or_update_user "$USERNAME" "$PASSWORD"

  echo "[i] 写入 /etc/danted.conf（internal=0.0.0.0 防止重启 bind 失败）"
  write_danted_conf "$PORT" "$IFACE"

  echo "[i] 写入 systemd override（等 IPv4 + 自动重启）"
  write_systemd_override "$IFACE"

  systemctl daemon-reload
  systemctl enable danted
  systemctl restart danted

  open_ufw_port_if_needed "$PORT"

  echo
  echo "[ok] 完成。当前状态："
  systemctl status danted --no-pager || true

  echo
  echo "[i] 测试示例（本机测试外网 IP）："
  echo "    curl --proxy 'socks5h://${USERNAME}:${PASSWORD}@127.0.0.1:${PORT}' https://ifconfig.me"
  echo
  echo "[i] 如果服务启动失败：先看日志"
  echo "    Debian/Ubuntu: journalctl -u danted -e --no-pager"
  echo "    CentOS/RHEL:   journalctl -u sockd  -e --no-pager"
}

main "$@"
