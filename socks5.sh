#!/usr/bin/env bash
set -euo pipefail

# ========== 默认值（按你要求）==========
DEFAULT_PORT="26216"
DEFAULT_USER="XnfdcpasL"
DEFAULT_PASS="+a5DBr!r:63NhM11Z"

# ========== 工具函数 ==========
need_root() {
  if [[ "$(id -u)" != "0" ]]; then
    echo "Error: 需要 root 运行（请用 sudo 或 root）"
    exit 1
  fi
}

detect_iface() {
  local iface=""
  iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  if [[ -z "${iface}" ]]; then
    iface="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
  fi
  echo "${iface:-eth0}"
}

create_or_update_user() {
  local u="$1" p="$2"
  local nologin_path="/usr/sbin/nologin"
  command -v nologin >/dev/null 2>&1 && nologin_path="$(command -v nologin)"
  [[ -x "${nologin_path}" ]] || nologin_path="/bin/false"

  if id "${u}" >/dev/null 2>&1; then
    echo "[i] 用户已存在：${u}（将更新密码）"
  else
    echo "[i] 创建系统用户：${u}"
    useradd -m -s "${nologin_path}" "${u}"
  fi

  echo "${u}:${p}" | chpasswd
}

open_firewall_port() {
  local port="$1"

  # firewalld（CentOS/RHEL 常见）
  if command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active --quiet firewalld; then
      firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null || true
      firewall-cmd --reload >/dev/null || true
      echo "[i] firewalld 已放行 TCP ${port}"
    fi
  fi

  # ufw（Ubuntu 常见）
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
      ufw allow "${port}/tcp" >/dev/null || true
      echo "[i] ufw 已放行 TCP ${port}"
    fi
  fi
}

install_debian_ubuntu() {
  local port="$1" user="$2" pass="$3" iface="$4"

  echo "[i] 检测到 Debian/Ubuntu：使用 apt 安装 dante-server（不编译）"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server

  create_or_update_user "${user}" "${pass}"

  # 备份配置
  if [[ -f /etc/danted.conf ]]; then
    cp -a /etc/danted.conf "/etc/danted.conf.bak.$(date +%Y%m%d_%H%M%S)"
  fi

  cat > /etc/danted.conf <<EOF
logoutput: syslog
internal: ${iface} port = ${port}
external: ${iface}

user.privileged: root
user.unprivileged: nobody

# 账号密码认证（匹配系统用户/密码）
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

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now danted

  open_firewall_port "${port}"

  echo "[ok] 安装完成：danted 已启动（/etc/danted.conf）"
}

install_centos_rhel() {
  local port="$1" user="$2" pass="$3" iface="$4"

  echo "[i] 检测到 CentOS/RHEL 系：使用 EPEL + dante-server（不编译）"

  local pm="yum"
  command -v dnf >/dev/null 2>&1 && pm="dnf"

  # EPEL（若已安装会自动跳过/更新）
  ${pm} -y install epel-release || true
  ${pm} -y install dante-server

  create_or_update_user "${user}" "${pass}"

  # 备份配置
  if [[ -f /etc/sockd.conf ]]; then
    cp -a /etc/sockd.conf "/etc/sockd.conf.bak.$(date +%Y%m%d_%H%M%S)"
  fi

  cat > /etc/sockd.conf <<EOF
logoutput: syslog
internal: ${iface} port = ${port}
external: ${iface}

user.privileged: root
user.unprivileged: nobody

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

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now sockd

  open_firewall_port "${port}"

  echo "[ok] 安装完成：sockd 已启动（/etc/sockd.conf）"
}

# ========== 主流程 ==========
need_root

# 交互输入（带默认值）
read -r -p "SOCKS5 端口 [默认 ${DEFAULT_PORT}]: " PORT
PORT="${PORT:-$DEFAULT_PORT}"

read -r -p "SOCKS5 账号 [默认 ${DEFAULT_USER}]: " USERNAME
USERNAME="${USERNAME:-$DEFAULT_USER}"

echo "SOCKS5 密码（回车使用默认；输入将隐藏）："
read -r -s -p "密码: " PASSWORD
echo
PASSWORD="${PASSWORD:-$DEFAULT_PASS}"

echo "========== 请确认 =========="
echo "端口: ${PORT}"
echo "账号: ${USERNAME}"
echo "密码: ${PASSWORD}"
echo "============================"
read -r -p "确认继续安装并启动服务？[y/N]: " OK
if [[ ! "${OK}" =~ ^[Yy]$ ]]; then
  echo "已取消"
  exit 0
fi

IFACE="$(detect_iface)"
echo "[i] 使用网卡/出口：${IFACE}"

# OS 识别
OS_ID=""
OS_LIKE=""
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
fi

if echo "${OS_ID} ${OS_LIKE}" | grep -Eqi 'debian|ubuntu'; then
  install_debian_ubuntu "${PORT}" "${USERNAME}" "${PASSWORD}" "${IFACE}"
elif echo "${OS_ID} ${OS_LIKE}" | grep -Eqi 'rhel|fedora|centos|rocky|almalinux'; then
  install_centos_rhel "${PORT}" "${USERNAME}" "${PASSWORD}" "${IFACE}"
else
  echo "[Error] 不支持的系统：${OS_ID} ${OS_LIKE}"
  exit 1
fi

echo
echo "[i] 测试示例（本机测试外网 IP）："
echo "    curl --proxy 'socks5h://${USERNAME}:${PASSWORD}@127.0.0.1:${PORT}' https://ifconfig.me"
echo
echo "[i] 如果服务启动失败：先看日志"
echo "    Debian/Ubuntu: journalctl -u danted -e --no-pager"
echo "    CentOS/RHEL:   journalctl -u sockd  -e --no-pager"
