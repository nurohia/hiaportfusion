#!/bin/bash

# ================= 配置区域 =================
# 核心路径
PANEL_BIN="/usr/local/bin/hipf-panel"
GOST_BIN="/usr/local/bin/gost"
GOST_PRO_BIN="/usr/local/bin/hipf-gost-udp"
GOST_OLD_BIN="/usr/local/bin/hipf-gost-server"

DATA_DIR="/etc/hipf"
RUN_DIR="/run/hipf-gost" 

HAPROXY_DIR="/etc/haproxy"
SERVICE_FILE="/etc/systemd/system/hipf-panel.service"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# ================= 辅助函数 =================
info() { echo -e "${CYAN}>>> $1${RESET}"; }
success() { echo -e "${GREEN}✔ $1${RESET}"; }

# ================= 主逻辑 =================

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请以 root 用户运行！${RESET}"
    exit 1
fi

clear
echo -e "${RED}========================================${RESET}"
echo -e "${RED}        HiaPortFusion 彻底卸载程序        ${RESET}"
echo -e "${RED}========================================${RESET}"
echo ""
read -p "确认卸载吗？(y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "操作已取消。"
    exit 0
fi

# 1. 停止并禁用服务
info "正在停止服务和进程..."

systemctl stop hipf-panel >/dev/null 2>&1 || true
systemctl disable hipf-panel >/dev/null 2>&1 || true
# systemctl stop haproxy >/dev/null 2>&1 || true

pkill -f "$GOST_BIN" >/dev/null 2>&1 || true
pkill -f "hipf-gost-udp" >/dev/null 2>&1 || true
pkill -9 -f "hipf-gost-udp" >/dev/null 2>&1 || true

success "服务已停止"

# 2. 清理 iptables 规则
info "正在清理 iptables 防火墙规则..."
iptables -D INPUT -j HIPF_IN >/dev/null 2>&1 || true
iptables -D FORWARD -j HIPF_IN >/dev/null 2>&1 || true
iptables -D OUTPUT -j HIPF_OUT >/dev/null 2>&1 || true
iptables -D FORWARD -j HIPF_OUT >/dev/null 2>&1 || true

iptables -F HIPF_IN >/dev/null 2>&1 || true
iptables -X HIPF_IN >/dev/null 2>&1 || true
iptables -F HIPF_OUT >/dev/null 2>&1 || true
iptables -X HIPF_OUT >/dev/null 2>&1 || true

if command -v iptables-save >/dev/null 2>&1; then
    if [ -d "/etc/iptables" ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    elif [ -d "/etc/sysconfig" ]; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null
    fi
fi
success "防火墙规则已清洗"

# 3. 删除文件
info "正在删除文件残留..."
rm -f "$PANEL_BIN"
rm -f "$GOST_BIN"        
rm -f "$GOST_PRO_BIN"     
rm -f "$GOST_OLD_BIN"  
rm -f "$SERVICE_FILE"
rm -rf "$DATA_DIR"
rm -rf "$RUN_DIR"  # <--- 新增：清理 PID 目录
rm -rf "/opt/hipf_panel"
rm -rf "/opt/hipf_build"
systemctl daemon-reload
success "面板及核心文件已删除"

# 4. 交互式删除依赖
echo ""
echo -e "${YELLOW}是否卸载 HAProxy？${RESET}"
read -p "输入 y 卸载，其他键保留 [y/n]: " rm_hap
if [[ "$rm_hap" == "y" || "$rm_hap" == "Y" ]]; then
    info "正在卸载 HAProxy..."
    if [ -f /etc/debian_version ]; then
        apt-get purge -y haproxy >/dev/null 2>&1 || true
    elif [ -f /etc/redhat-release ]; then
        yum remove -y haproxy >/dev/null 2>&1 || true
    fi
    rm -rf "$HAPROXY_DIR"
    success "HAProxy 已卸载"
else
    echo "已保留 HAProxy"
fi

echo ""
echo -e "${YELLOW}是否卸载 Rust 编译环境？${RESET}"
echo -e "${CYAN}(如果您服务器上还有其他 Rust 项目，请选择 n)${RESET}"
read -p "输入 y 卸载，其他键保留 [y/n]: " rm_rust
if [[ "$rm_rust" == "y" || "$rm_rust" == "Y" ]]; then
    if command -v rustup >/dev/null 2>&1; then
        info "正在移除 Rust 环境..."
        rustup self uninstall -y >/dev/null 2>&1
        success "Rust 已移除"
    else
        echo "未检测到 Rustup，跳过。"
    fi
else
    echo "已保留 Rust 环境"
fi

echo ""
echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}      HiaPortFusion 已彻底卸载          ${RESET}"
echo -e "${GREEN}========================================${RESET}"
