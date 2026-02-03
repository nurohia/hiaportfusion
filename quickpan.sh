#!/bin/bash
set -e

# =================配置区域=================
URL_AMD=""
URL_ARM=""

# 默认配置
PANEL_PORT="4796"
DEFAULT_USER="admin"
DEFAULT_PASS="123456"

# 核心路径
BINARY_PATH="/usr/local/bin/hipf-panel"
SERVICE_FILE="/etc/systemd/system/hipf-panel.service"
DATA_FILE="/etc/hipf/panel_data.json"
GOST_BIN="/usr/local/bin/gost"

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}    HiaPortFusion 面板 (HAProxy+GOST)     ${RESET}"
echo -e "${GREEN}==========================================${RESET}"

# 1. 历史配置保留检测
if [ -f "$DATA_FILE" ] && [ -f "$SERVICE_FILE" ]; then
    echo -e "${CYAN}>>> 检测到历史安装信息...${RESET}"
    
    # 尝试从 JSON 或 Service 文件中提取旧配置
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
    echo -e "${RED} [错误] 下载链接未配置！请编辑脚本填入 URL_AMD/URL_ARM。${RESET}"
    exit 1
fi

# 3. 依赖检测与安装 (核心逻辑)
check_and_install_deps() {
    local NEED_UPDATE=0
    
    # 检测 HAProxy
    if ! command -v haproxy >/dev/null 2>&1; then
        echo -e "${YELLOW}>>> 未检测到 HAProxy，准备安装...${RESET}"
        NEED_UPDATE=1
    fi

    # 检测常用工具
    if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
        NEED_UPDATE=1
    fi

    if [ $NEED_UPDATE -eq 1 ]; then
        if [ -f /etc/debian_version ]; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y haproxy curl wget tar iptables >/dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            yum install -y haproxy curl wget tar iptables-services >/dev/null 2>&1
        fi
        echo -e "${GREEN}>>> HAProxy 及基础依赖安装完成${RESET}"
    else
        echo -e "${GREEN}>>> HAProxy 已存在，跳过安装${RESET}"
    fi

    # 检测 GOST
    if [ ! -f "$GOST_BIN" ]; then
        echo -e "${YELLOW}>>> 未检测到 GOST，准备安装...${RESET}"
        local G_URL=""
        case $ARCH in
            x86_64) G_URL="https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_amd64.tar.gz" ;;
            aarch64) G_URL="https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_arm64.tar.gz" ;;
        esac
        
        wget -O /tmp/gost.tar.gz "$G_URL" >/dev/null 2>&1
        tar -xf /tmp/gost.tar.gz -C /tmp
        mv /tmp/gost "$GOST_BIN"
        chmod +x "$GOST_BIN"
        rm -f /tmp/gost.tar.gz
        echo -e "${GREEN}>>> GOST 安装完成${RESET}"
    else
        echo -e "${GREEN}>>> GOST 已存在，跳过安装${RESET}"
    fi
    
    # 初始化配置文件夹
    mkdir -p /etc/hipf
    mkdir -p /etc/haproxy
    
    # 确保 HAProxy 默认配置存在 (防止报错)
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
}

check_and_install_deps

# 4. 下载面板
echo -n ">>> 正在下载面板程序..."
rm -f /tmp/hipf-panel.tar.gz
curl -L "$DOWNLOAD_URL" -o /tmp/hipf-panel.tar.gz >/dev/null 2>&1

# 简单检测文件大小，防止下载了 404 页面
FILE_SIZE=$(stat -c%s "/tmp/hipf-panel.tar.gz" 2>/dev/null || echo 0)
if [ "$FILE_SIZE" -lt 100000 ]; then
    echo -e "${RED} [失败]${RESET}"
    echo -e "${RED}下载失败或文件无效，请检查 URL 配置。${RESET}"
    rm -f /tmp/hipf-panel.tar.gz
    exit 1
fi

systemctl stop hipf-panel >/dev/null 2>&1

tar -xzvf /tmp/hipf-panel.tar.gz -C /usr/local/bin/ >/dev/null 2>&1

chmod +x "$BINARY_PATH"
rm -f /tmp/hipf-panel.tar.gz
echo -e "${GREEN} [完成]${RESET}"

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

systemctl daemon-reload
systemctl enable hipf-panel >/dev/null 2>&1
systemctl restart hipf-panel >/dev/null 2>&1

# 6. 显示结果
IP=$(curl -s4 ifconfig.me || hostname -I | awk '{print $1}')
echo -e ""
echo -e "${GREEN}==========================================${RESET}"
echo -e "${GREEN}     ✅ HiaPortFusion 面板部署成功            ${RESET}"
echo -e "${GREEN}==========================================${RESET}"
echo -e "访问地址 : ${YELLOW}http://${IP}:${PANEL_PORT}${RESET}"
echo -e "当前用户 : ${YELLOW}${DEFAULT_USER}${RESET}"
echo -e "当前密码 : ${YELLOW}${DEFAULT_PASS}${RESET}"
echo -e "${GREEN}==========================================${RESET}"
