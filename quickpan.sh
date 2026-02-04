#!/bin/bash
set -e

# =================配置区域=================
URL_AMD="https://github.com/nurohia/hiaportfusion/releases/download/hipf-panel/hipf-panel-amd.tar.gz"
URL_ARM="https://github.com/nurohia/hiaportfusion/releases/download/hipf-panel/hipf-panel-arm.tar.gz"

# 默认配置
PANEL_PORT="4796"
DEFAULT_USER="admin"
DEFAULT_PASS="123456"

# 核心路径
BINARY_PATH="/usr/local/bin/hipf-panel"
SERVICE_FILE="/etc/systemd/system/hipf-panel.service"
DATA_FILE="/etc/hipf/panel_data.json"
GOST_BIN="/usr/local/bin/gost"
GOST_PRO_BIN="/usr/local/bin/hipf-gost-udp"
PID_DIR="/run/hipf-gost"

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}            HiaPortFusion 面板            ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

# 必须 root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[错误] 请以 root 用户运行${RESET}"
  exit 1
fi

# 保留历史账号/端口
if [ -f "$DATA_FILE" ] && [ -f "$SERVICE_FILE" ]; then
    echo -e "${CYAN}>>> 检测到历史安装信息...${RESET}"

    OLD_USER=$(grep '"username":' "$DATA_FILE" 2>/dev/null | awk -F'"' '{print $4}')
    OLD_PASS=$(grep '"pass_hash":' "$DATA_FILE" 2>/dev/null | awk -F'"' '{print $4}')
    OLD_PORT=$(grep "PANEL_PORT=" "$SERVICE_FILE" 2>/dev/null | sed 's/.*PANEL_PORT=\([0-9]*\).*/\1/')

    if [ -n "$OLD_USER" ] && [ -n "$OLD_PASS" ]; then
        DEFAULT_USER="$OLD_USER"
        DEFAULT_PASS="$OLD_PASS"
        echo -e "    已保留账号: ${GREEN}$DEFAULT_USER${RESET}"
    fi

    if [ -n "$OLD_PORT" ]; then
        PANEL_PORT="$OLD_PORT"
        echo -e "    已保留端口: ${GREEN}$PANEL_PORT${RESET}"
    fi
fi

# 2. 架构检测
ARCH=$(uname -m)
DOWNLOAD_URL=""

if [ "$ARCH" == "x86_64" ]; then
    echo -e ">>> 检测到系统架构: ${CYAN}AMD64 (x86_64)${RESET}"
    DOWNLOAD_URL=$URL_AMD
elif [ "$ARCH" == "aarch64" ]; then
    echo -e ">>> 检测到系统架构: ${CYAN}ARM64 (aarch64)${RESET}"
    DOWNLOAD_URL=$URL_ARM
else
    echo -e "${RED} [错误] 不支持的系统架构: $ARCH${RESET}"
    exit 1
fi

if [ -z "$DOWNLOAD_URL" ]; then
    echo -e "${RED} [错误] 下载链接未配置！${RESET}"
    exit 1
fi

# 3. 依赖检测与安装
check_and_install_deps() {
    local NEED_UPDATE=0

    for cmd in haproxy curl wget tar gzip iptables; do
        if ! command -v $cmd >/dev/null 2>&1; then
            NEED_UPDATE=1
            break
        fi
    done

    if [ $NEED_UPDATE -eq 1 ]; then
        echo -e "${CYAN}>>> 正在安装系统依赖...${RESET}"
        if [ -f /etc/debian_version ]; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y haproxy curl wget tar gzip iptables ca-certificates >/dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            yum install -y haproxy curl wget tar gzip iptables-services ca-certificates >/dev/null 2>&1
        fi
    fi

    if [ ! -f "$GOST_BIN" ]; then
        echo -e "${YELLOW}>>> 正在安装 GOST...${RESET}"
        local G_URL=""
        case $ARCH in
            x86_64)  G_URL="https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_amd64.tar.gz" ;;
            aarch64) G_URL="https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_arm64.tar.gz" ;;
        esac

        rm -f /tmp/gost.tar.gz
        curl -fL --retry 3 --retry-delay 1 -o /tmp/gost.tar.gz "$G_URL" >/dev/null 2>&1
        tar -xzf /tmp/gost.tar.gz -C /tmp
        mv /tmp/gost "$GOST_BIN"
        chmod +x "$GOST_BIN"
        rm -f /tmp/gost.tar.gz
    fi

    if [ -f "$GOST_BIN" ]; then
        cp -f "$GOST_BIN" "$GOST_PRO_BIN"
        chmod +x "$GOST_PRO_BIN"
        echo -e "${GREEN}>>> GOST 及专用进程副本配置完成${RESET}"
    else
        echo -e "${RED}>>> [错误] GOST 安装失败${RESET}"
        exit 1
    fi

    mkdir -p /etc/hipf
    mkdir -p /etc/haproxy

    if [ ! -f "/etc/haproxy/haproxy.cfg" ] || [ ! -s "/etc/haproxy/haproxy.cfg" ]; then
        cat > "/etc/haproxy/haproxy.cfg" <<EOF
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

    systemctl enable haproxy >/dev/null 2>&1 || true
    systemctl restart haproxy >/dev/null 2>&1 || true
}

check_and_install_deps

# 4. 下载面板
echo -e "${CYAN}>>> 正在下载面板程序...${RESET}"
systemctl stop hipf-panel >/dev/null 2>&1 || true
rm -f /tmp/hipf-panel.tar.gz

curl -fL --retry 3 --retry-delay 1 -o /tmp/hipf-panel.tar.gz "$DOWNLOAD_URL"

FILE_SIZE=$(stat -c%s "/tmp/hipf-panel.tar.gz" 2>/dev/null || echo 0)
if [ "$FILE_SIZE" -lt 100000 ]; then
    echo -e "${RED} [失败]${RESET}"
    echo -e "${RED}文件下载失败 (Size: $FILE_SIZE bytes)。请检查 URL 或网络。${RESET}"
    rm -f /tmp/hipf-panel.tar.gz
    exit 1
fi

rm -rf /tmp/hipf_unpkg
mkdir -p /tmp/hipf_unpkg
tar -xzf /tmp/hipf-panel.tar.gz -C /tmp/hipf_unpkg >/dev/null 2>&1

if [ ! -f "/tmp/hipf_unpkg/hipf-panel" ]; then
  echo -e "${RED}[错误] 解压后未找到 /tmp/hipf_unpkg/hipf-panel${RESET}"
  echo -e "${YELLOW}当前解压内容：${RESET}"
  ls -lah /tmp/hipf_unpkg || true
  exit 1
fi

install -m 755 /tmp/hipf_unpkg/hipf-panel "$BINARY_PATH"

rm -rf /tmp/hipf_unpkg
rm -f /tmp/hipf-panel.tar.gz

echo -e "${GREEN}>>> 面板安装完成: $BINARY_PATH${RESET}"

# 5. 配置 Systemd
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

# ==========================================
if [ -d "$PID_DIR" ]; then
    echo -e "${YELLOW}>>> 清理旧的 PID 状态文件...${RESET}"
    rm -rf "$PID_DIR"
fi
# ==========================================

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable hipf-panel >/dev/null 2>&1 || true
systemctl restart hipf-panel >/dev/null 2>&1 || true

RAW_IP=$(curl -s4 ifconfig.me/ip || curl -s6 ifconfig.me/ip || hostname -I | awk '{print $1}')
if [[ "$RAW_IP" == *:* ]]; then
    SHOW_IP="[$RAW_IP]"
else
    SHOW_IP="$RAW_IP"
fi

echo -e ""
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}      ✅ HiaPortFusion 面板部署成功         ${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${SHOW_IP}:${PANEL_PORT}${RESET}"
echo -e "当前用户 : ${YELLOW}${DEFAULT_USER}${RESET}"
echo -e "当前密码 : ${YELLOW}${DEFAULT_PASS}${RESET}"
echo -e "${GREEN}==========================================${RESET}"
