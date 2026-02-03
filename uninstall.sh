#!/bin/bash
set -euo pipefail

# =================配置区域=================
URL_AMD="https://github.com/nurohia/hiaportfusion/releases/download/hipf-panel/hipf-panel-amd.tar.gz"
URL_ARM="https://github.com/nurohia/hiaportfusion/releases/download/hipf-panel/hipf-panel-arm.tar.gz"

# 默认配置（若检测到历史安装会自动保留）
PANEL_PORT="4796"
DEFAULT_USER="admin"
DEFAULT_PASS="123456"

# 核心路径
BINARY_PATH="/usr/local/bin/hipf-panel"
SERVICE_FILE="/etc/systemd/system/hipf-panel.service"
DATA_FILE="/etc/hipf/panel_data.json"

GOST_BIN="/usr/local/bin/gost"
# 必须与 Rust 代码里的常量一致（v1.0.7+）
GOST_PRO_BIN="/usr/local/bin/hipf-gost-udp"

# 颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

log()  { echo -e "${CYAN}>>> $*${RESET}"; }
ok()   { echo -e "${GREEN}✔ $*${RESET}"; }
warn() { echo -e "${YELLOW}! $*${RESET}"; }
die()  { echo -e "${RED}✘ $*${RESET}"; exit 1; }

need_root() {
  [ "${EUID:-0}" -eq 0 ] || die "请以 root 用户运行！"
}

# systemctl 有些环境/首次安装会返回非0，别让 set -e 直接退出
sc() {
  systemctl "$@" >/dev/null 2>&1 || true
}

detect_arch_and_url() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "$URL_AMD" ;;
    aarch64|arm64) echo "$URL_ARM" ;;
    *) die "不支持的系统架构: $arch" ;;
  esac
}

restore_old_config_if_any() {
  if [ -f "$DATA_FILE" ] && [ -f "$SERVICE_FILE" ]; then
    log "检测到历史安装信息，尝试保留账号/端口"

    local old_user old_pass old_port
    old_user="$(grep '"username":' "$DATA_FILE" 2>/dev/null | awk -F'"' '{print $4}' || true)"
    old_pass="$(grep '"pass_hash":' "$DATA_FILE" 2>/dev/null | awk -F'"' '{print $4}' || true)"
    old_port="$(grep "PANEL_PORT=" "$SERVICE_FILE" 2>/dev/null | sed 's/.*PANEL_PORT=\([0-9]*\).*/\1/' || true)"

    if [ -n "${old_user:-}" ] && [ -n "${old_pass:-}" ]; then
      DEFAULT_USER="$old_user"
      DEFAULT_PASS="$old_pass"
      ok "已保留账号: $DEFAULT_USER"
    fi
    if [ -n "${old_port:-}" ]; then
      PANEL_PORT="$old_port"
      ok "已保留端口: $PANEL_PORT"
    fi
  fi
}

install_deps() {
  log "检查并安装依赖 (haproxy/curl/wget/tar/gzip/iptables)"

  local has_debian=0 has_redhat=0
  [ -f /etc/debian_version ] && has_debian=1
  [ -f /etc/redhat-release ] && has_redhat=1

  if [ $has_debian -eq 1 ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y haproxy curl wget tar gzip iptables ca-certificates >/dev/null 2>&1 || true
  elif [ $has_redhat -eq 1 ]; then
    yum install -y haproxy curl wget tar gzip iptables-services ca-certificates >/dev/null 2>&1 || true
  else
    warn "未识别系统包管理器（非 Debian/RedHat），请确保已安装: haproxy curl wget tar gzip iptables"
  fi

  mkdir -p /etc/hipf /etc/haproxy

  if [ ! -f "/etc/haproxy/haproxy.cfg" ] || [ ! -s "/etc/haproxy/haproxy.cfg" ]; then
    cat > "/etc/haproxy/haproxy.cfg" <<'EOF'
global
    daemon
    maxconn 10240
defaults
    mode tcp
    timeout connect 5s
    timeout client  60s
    timeout server  60s
EOF
  fi

  sc enable haproxy
  sc restart haproxy

  ok "依赖检查完成"
}

install_gost_and_copy() {
  if [ ! -f "$GOST_BIN" ]; then
    log "安装 GOST v3.0.0"
    local arch g_url
    arch="$(uname -m)"
    case "$arch" in
      x86_64|amd64) g_url="https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_amd64.tar.gz" ;;
      aarch64|arm64) g_url="https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_arm64.tar.gz" ;;
      *) die "不支持的架构（无法安装 GOST）: $arch" ;;
    esac

    rm -f /tmp/gost.tar.gz
    curl -fL --retry 3 --retry-delay 1 -o /tmp/gost.tar.gz "$g_url" || die "GOST 下载失败"
    tar -xzf /tmp/gost.tar.gz -C /tmp || die "GOST 解压失败"
    [ -f /tmp/gost ] || die "GOST 解压后未找到 /tmp/gost"
    install -m 755 /tmp/gost "$GOST_BIN"
    rm -f /tmp/gost.tar.gz /tmp/gost
  fi

  cp -f "$GOST_BIN" "$GOST_PRO_BIN"
  chmod +x "$GOST_PRO_BIN"
  ok "GOST 及专用副本已就绪: $GOST_PRO_BIN"
}

download_and_install_panel() {
  local download_url="$1"

  log "下载面板程序"
  sc stop hipf-panel
  rm -f /tmp/hipf-panel.tar.gz

  # 不要吞输出，方便看到进度/失败原因
  curl -fL --retry 3 --retry-delay 1 -o /tmp/hipf-panel.tar.gz "$download_url" || die "面板下载失败"

  local file_size
  file_size="$(stat -c%s "/tmp/hipf-panel.tar.gz" 2>/dev/null || echo 0)"
  [ "$file_size" -ge 100000 ] || die "文件过小，疑似下载失败 (Size: ${file_size} bytes)"

  log "解压并安装面板"
  # tar 包里只有 hipf-panel
  tar -xzf /tmp/hipf-panel.tar.gz -C /usr/local/bin/ || die "解压失败"
  [ -f /usr/local/bin/hipf-panel ] || die "解压后未找到 /usr/local/bin/hipf-panel"

  install -m 755 /usr/local/bin/hipf-panel "$BINARY_PATH"
  rm -f /usr/local/bin/hipf-panel /tmp/hipf-panel.tar.gz

  ok "面板二进制安装完成: $BINARY_PATH"
}

write_systemd_service() {
  log "写入 systemd 服务"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=HiaPortFusion Panel (HAProxy+GOST)
After=network.target haproxy.service

[Service]
User=root
Environment="PANEL_USER=$DEFAULT_USER"
Environment="PANEL_PASS=$DEFAULT_PASS"
Environment="PANEL_PORT=$PANEL_PORT"
LimitNOFILE=1048576
LimitNPROC=1048576
ExecStart=$BINARY_PATH
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload || true
  sc enable hipf-panel
  sc restart hipf-panel
  ok "systemd 服务已配置并启动"
}

show_access_info() {
  local raw_ip show_ip
  raw_ip="$(curl -s4 ifconfig.me/ip || curl -s6 ifconfig.me/ip || hostname -I | awk '{print $1}')"
  if [[ "$raw_ip" == *:* ]]; then
    show_ip="[$raw_ip]"
  else
    show_ip="$raw_ip"
  fi

  echo -e ""
  echo -e "${GREEN}==========================================${RESET}"
  echo -e "${GREEN}      ✅ HiaPortFusion 面板部署成功        ${RESET}"
  echo -e "${GREEN}==========================================${RESET}"
  echo -e "访问地址 : ${YELLOW}http://${show_ip}:${PANEL_PORT}${RESET}"
  echo -e "当前用户 : ${YELLOW}${DEFAULT_USER}${RESET}"
  echo -e "当前密码 : ${YELLOW}${DEFAULT_PASS}${RESET}"
  echo -e "${GREEN}==========================================${RESET}"
}

# =================主逻辑=================
need_root

echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}    HiaPortFusion 面板 (Binary Release)   ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

restore_old_config_if_any

DOWNLOAD_URL="$(detect_arch_and_url)"
log "下载链接: $DOWNLOAD_URL"

install_deps
install_gost_and_copy
download_and_install_panel "$DOWNLOAD_URL"
write_systemd_service

# 给你一个明确的状态输出（别再“静默”）
echo
systemctl --no-pager --full status hipf-panel || true

show_access_info
