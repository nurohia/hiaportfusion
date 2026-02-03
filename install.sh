#!/bin/bash

# ================= 配置区域 =================
# 仓库根路径 (指向你的 main 分支)
REPO_URL="https://raw.githubusercontent.com/nurohia/hiaportfusion/main"

# 核心系统路径 (适配 HiaPortFusion v1.0.8+)
SERVICE_NAME="hipf-panel"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PANEL_BIN="/usr/local/bin/hipf-panel"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# ================= 辅助函数 =================

# 1. 检查 Root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：请以 root 用户运行此脚本！${RESET}"
        exit 1
    fi
}

# 2. 获取服务器 IP (智能识别 IPv6 加括号)
get_ip() {
    local IP=$(curl -s4 ifconfig.me/ip || curl -s6 ifconfig.me/ip || hostname -I | awk '{print $1}')
    if [[ "$IP" == *:* ]]; then echo "[$IP]"; else echo "$IP"; fi
}

# ================= 核心功能逻辑 =================

# 3. 修改面板端口 (带安全校验)
update_panel_port() {
    if [ ! -f "$SERVICE_FILE" ]; then
        echo -e "${RED}错误：检测到面板尚未安装，请先执行安装！${RESET}"
        read -p "按回车键返回..."
        return
    fi

    # 提取当前端口
    local CURRENT_PORT=$(grep "PANEL_PORT=" "$SERVICE_FILE" | cut -d'=' -f2 | tr -d '"')
    
    echo -e "--------------------"
    echo -e "修改 Web 面板访问端口"
    echo -e "当前端口: ${GREEN}${CURRENT_PORT}${RESET}"
    echo -e "--------------------"
    
    read -p "请输入新的端口号 (1-65535): " new_port
    
    # 合法性校验 (纯数字且在范围内)
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}输入无效，端口必须是 1 到 65535 之间的数字。${RESET}"
        read -p "按回车键返回..."
        return
    fi

    # 端口占用检测 (如果系统有 ss 命令)
    if command -v ss >/dev/null 2>&1; then
        if ss -lntu | grep -q ":${new_port} "; then
            echo -e "${RED}错误：端口 $new_port 似乎已被系统其他程序占用，请更换。${RESET}"
            read -p "按回车键返回..."
            return
        fi
    fi

    echo -e "${YELLOW}正在更新配置...${RESET}"
    
    # 精确修改 Systemd 配置中的环境变量
    sed -i "s|Environment=\"PANEL_PORT=.*\"|Environment=\"PANEL_PORT=$new_port\"|g" "$SERVICE_FILE"
    
    systemctl daemon-reload
    
    if systemctl restart "$SERVICE_NAME"; then
        echo -e "${GREEN}✅ 端口修改成功！面板已重启。${RESET}"
        echo -e "新的访问地址: ${YELLOW}http://$(get_ip):${new_port}${RESET}"
    else
        echo -e "${RED}❌ 修改失败，面板服务无法重启，请检查日志。${RESET}"
        # 自动展示最后 20 行日志帮助排错
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager
    fi
    read -p "按回车键返回..."
}

# 4. 查看详细状态
check_status() {
    echo -e "--------------------"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "运行状态: ${GREEN}运行中 (Active)${RESET}"
        
        # 尝试读取 PID
        local PID=$(pgrep -f "$PANEL_BIN")
        [ -n "$PID" ] && echo -e "进程 PID: ${CYAN}$PID${RESET}"
        
        # 提取端口
        local PORT=$(grep "PANEL_PORT=" "$SERVICE_FILE" | cut -d'=' -f2 | tr -d '"')
        echo -e "监听端口: ${CYAN}$PORT${RESET}"
        echo -e "访问地址: ${YELLOW}http://$(get_ip):$PORT${RESET}"
    else
        echo -e "运行状态: ${RED}未运行 (Inactive/Dead)${RESET}"
    fi
    echo -e "--------------------"
    read -p "按回车键返回..."
}

# 5. 查看实时日志
view_logs() {
    echo -e "${YELLOW}正在打开日志 (按 Ctrl+C 退出)...${RESET}"
    journalctl -u "$SERVICE_NAME" -f
}

# 6. 服务启停控制
service_control() {
    local action=$1
    echo -e "${YELLOW}正在执行 $action ...${RESET}"
    systemctl "$action" "$SERVICE_NAME"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}执行成功！${RESET}"
    else
        echo -e "${RED}执行失败！${RESET}"
    fi
    sleep 1
}

# ================= 主菜单逻辑 =================

manage_panel() {
    clear
    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}    HiaPortFusion 面板管理菜单            ${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
    
    # 顶部状态栏
    if [ -f "$SERVICE_FILE" ]; then
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            echo -e "当前状态: ${GREEN}● 运行中${RESET}"
        else
            echo -e "当前状态: ${RED}● 已停止${RESET}"
        fi
    else
        echo -e "当前状态: ${YELLOW}○ 未安装${RESET}"
    fi
    
    echo -e "------------------------------------------"
    echo -e "1. 安装面板 (Install)"
    echo -e "2. 卸载面板 (Uninstall)"
    echo -e "3. 修改端口 (Change Port)"
    echo -e "------------------------------------------"
    echo -e "4. 查看详细状态 (Status)"
    echo -e "5. 查看实时日志 (Logs)"
    echo -e "6. 重启服务 (Restart)"
    echo -e "7. 停止服务 (Stop)"
    echo -e "8. 启动服务 (Start)"
    echo -e "------------------------------------------"
    echo -e "0. 退出脚本"
    echo -e "${GREEN}------------------------------------------${RESET}"
    
    read -p "请选择 [0-8]: " OPT
    
    case "$OPT" in
        1)
            clear
            echo -e "${CYAN}--- 安装向导 ---${RESET}"
            echo -e "1. 快速安装部署 (下载 v1.0.8+ 二进制，推荐)"
            echo -e "2. 自编译部署 (从源码编译，耗时较长)"
            echo -e "0. 返回上级"
            read -p "请选择: " INST_OPT
            case "$INST_OPT" in
                1) 
                    # 运行 quickpan.sh
                    bash <(curl -fsSL ${REPO_URL}/quickpan.sh) 
                    read -p "按回车键继续..." 
                    ;;
                2) 
                    # 运行 panel.sh
                    bash <(curl -fsSL ${REPO_URL}/panel.sh) 
                    read -p "按回车键继续..." 
                    ;;
                *) ;;
            esac
            ;;
        2)
            # 运行 uninstall.sh
            bash <(curl -fsSL ${REPO_URL}/uninstall.sh)
            read -p "按回车键继续..."
            ;;
        3) update_panel_port ;;
        4) check_status ;;
        5) view_logs ;;
        6) service_control "restart" ;;
        7) service_control "stop" ;;
        8) service_control "start" ;;
        0) exit 0 ;;
        *) 
            echo -e "${RED}无效输入，请重试。${RESET}" 
            sleep 1 
            ;;
    esac
}

# ================= 脚本入口 =================

check_root

# 循环显示菜单，直到用户选择退出
while true; do
    manage_panel
done
