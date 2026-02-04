#!/bin/bash

# ================= 配置区域 =================
SERVICE_NAME="hipf-panel"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PANEL_BIN="/usr/local/bin/hipf-panel"
DATA_FILE="/etc/hipf/panel_data.json"

# 备份相关配置
BACKUP_DIR="/etc/hipf/backups"
DEFAULT_BACKUP_FILE="$BACKUP_DIR/hipf-backup.tar.gz" 
CRON_FILE="/etc/cron.d/hipf-backup"
EXPORT_HELPER="/usr/local/bin/hipf-export.sh"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# ================= 辅助函数 =================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：请以 root 用户运行此脚本！${RESET}"
        exit 1
    fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo -e "${RED}缺少依赖命令：$1，请先安装。${RESET}"
        return 1
    }
}

get_ip() {
    local IP=$(curl -s4 ifconfig.me/ip || curl -s6 ifconfig.me/ip || hostname -I | awk '{print $1}')
    if [[ "$IP" == *:* ]]; then echo "[$IP]"; else echo "$IP"; fi
}

# ================= 核心功能逻辑 =================

update_panel_port() {
    if [ ! -f "$SERVICE_FILE" ]; then
        echo -e "${RED}错误：检测到面板尚未安装，请先执行安装！${RESET}"
        read -p "按回车键返回..."
        return
    fi

    local CURRENT_PORT=""
    CURRENT_PORT=$(systemctl show "$SERVICE_NAME" --property=Environment 2>/dev/null \
        | sed -n 's/.*PANEL_PORT=\([0-9]\+\).*/\1/p' | head -n1)

    if [ -z "$CURRENT_PORT" ]; then
        CURRENT_PORT=$(sed -n 's/.*PANEL_PORT=\([0-9]\+\).*/\1/p' "$SERVICE_FILE" 2>/dev/null | head -n1)
    fi
    [ -z "$CURRENT_PORT" ] && CURRENT_PORT="(未知)"

    echo -e "--------------------"
    echo -e "修改 Web 面板访问端口"
    echo -e "当前端口: ${GREEN}${CURRENT_PORT}${RESET}"
    echo -e "--------------------"

    read -p "请输入新的端口号 (1-65535): " new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}输入无效，端口必须是 1 到 65535 之间的数字。${RESET}"
        read -p "按回车键返回..."
        return
    fi

    if command -v ss >/dev/null 2>&1; then
        if ss -lntu | awk '{print $5}' | grep -Eq "[:.]${new_port}$"; then
            echo -e "${RED}错误：端口 $new_port 似乎已被系统其他程序占用。${RESET}"
            read -p "按回车键返回..."
            return
        fi
    fi

    echo -e "${YELLOW}正在更新配置...${RESET}"

    if ! grep -qE 'Environment="PANEL_PORT=' "$SERVICE_FILE"; then
        awk -v np="$new_port" '<
            BEGIN{added=0}
            /^\[Service\]/{print; if(!added){print "Environment=\"PANEL_PORT="np"\""; added=1; next}}
            {print}
            END{if(!added) print "Environment=\"PANEL_PORT="np"\""}
        ' "$SERVICE_FILE" > /tmp/hipf-panel.service.tmp && mv /tmp/hipf-panel.service.tmp "$SERVICE_FILE"
    else
        sed -i -E 's/(Environment="PANEL_PORT=)[0-9]+(")/\1'"$new_port"'\2/' "$SERVICE_FILE"
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true

    if systemctl restart "$SERVICE_NAME" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ 端口修改成功！面板已重启。${RESET}"
        local SHOW_IP=""
        if command -v get_ip >/dev/null 2>&1; then
            SHOW_IP="$(get_ip)"
        else
            SHOW_IP="$(curl -s4 ifconfig.me/ip || curl -s6 ifconfig.me/ip || hostname -I | awk '{print $1}')"
        fi
        if [[ "$SHOW_IP" == *:* ]]; then SHOW_IP="[$SHOW_IP]"; fi
        echo -e "新的访问地址: ${YELLOW}http://${SHOW_IP}:${new_port}${RESET}"
    else
        echo -e "${RED}❌ 修改失败，请检查日志。${RESET}"
    fi
    read -p "按回车键返回..."
}

check_status() {
    echo -e "--------------------"
    
    local READ_PORT=""
    if [ -f "$SERVICE_FILE" ]; then
        READ_PORT=$(grep -oE 'PANEL_PORT=[0-9]+' "$SERVICE_FILE" | awk -F'=' '{print $2}' | head -n1)
    fi
    
    if [ -z "$READ_PORT" ]; then
        READ_PORT=$(systemctl show "$SERVICE_NAME" --property=Environment 2>/dev/null | grep -oE 'PANEL_PORT=[0-9]+' | awk -F'=' '{print $2}' | head -n1)
    fi

    [ -z "$READ_PORT" ] && READ_PORT="(未知)"

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "运行状态: ${GREEN}运行中 (Active)${RESET}"
        echo -e "监听端口: ${CYAN}${READ_PORT}${RESET}"
        echo -e "访问地址: ${YELLOW}http://$(get_ip):${READ_PORT}${RESET}"
    else
        echo -e "运行状态: ${RED}未运行${RESET}"
        echo -e "配置端口: ${CYAN}${READ_PORT}${RESET}"
    fi
    echo -e "--------------------"
    read -p "按回车键返回..."
}
view_logs() {
    echo -e "${YELLOW}正在打开日志 (按 Ctrl+C 退出)...${RESET}"
    journalctl -u "$SERVICE_NAME" -f
}

service_control() {
    local action=$1
    echo -e "${YELLOW}正在执行 $action ...${RESET}"
    systemctl "$action" "$SERVICE_NAME"
    echo -e "${GREEN}执行完成${RESET}"
    sleep 1
}

# ================= 备份与恢复逻辑 =================

has_cron() {
    command -v crontab >/dev/null 2>&1 && return 0
    command -v cron >/dev/null 2>&1 && return 0
    command -v crond >/dev/null 2>&1 && return 0
    return 1
}

install_cron() {
    echo -e "${YELLOW}系统未检测到 cron/crond。${RESET}"
    read -p "是否尝试自动安装 cron？[y/N]: " ANS
    case "$ANS" in y|Y) ;; *) return 1 ;; esac

    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y cron
        systemctl enable cron && systemctl start cron
    elif [ -f /etc/redhat-release ]; then
        yum install -y cronie
        systemctl enable crond && systemctl start crond
    elif [ -f /etc/alpine-release ]; then
        apk add cronie
        rc-update add crond default && rc-service crond start
    else
        echo -e "${RED}无法识别系统，请手动安装 cron。${RESET}"
        return 1
    fi
}

ensure_cron_ready() {
    if has_cron; then return 0; fi
    install_cron || { echo -e "${RED}Cron 安装失败或取消。${RESET}"; return 1; }
    return 0
}

write_export_helper() {
    mkdir -p "$BACKUP_DIR"
    cat > "$EXPORT_HELPER" <<EOF
#!/bin/bash
set -e
DATA_FILE="/etc/hipf/panel_data.json"
BACKUP_DIR="${BACKUP_DIR}"
OUT="${DEFAULT_BACKUP_FILE}"
mkdir -p "\$BACKUP_DIR"
if [ -f "\$DATA_FILE" ]; then
    tar -czf "\$OUT" -C "\$(dirname "\$DATA_FILE")" "\$(basename "\$DATA_FILE")" 2>/dev/null
fi
EOF
    chmod +x "$EXPORT_HELPER"
}

manual_backup() {
    mkdir -p "$BACKUP_DIR"
    if [ ! -f "$DATA_FILE" ]; then
        echo -e "${RED}错误：未找到数据文件 $DATA_FILE，无法备份。${RESET}"
        read -p "按回车键返回..."
        return
    fi
    echo -e "${CYAN}正在备份数据...${RESET}"
    local OUT="$DEFAULT_BACKUP_FILE"
    tar -czf "$OUT" -C "$(dirname "$DATA_FILE")" "$(basename "$DATA_FILE")"
    if [ -s "$OUT" ]; then
        echo -e "${GREEN}✅ 备份成功 (已覆盖旧备份)！${RESET}"
        echo -e "文件路径: ${YELLOW}$OUT${RESET}"
    else
        echo -e "${RED}❌ 备份文件生成失败。${RESET}"
    fi
    read -p "按回车键返回..."
}

manual_restore() {
    echo -e "${CYAN}--- 恢复备份 ---${RESET}"
    echo -e "默认备份路径: $DEFAULT_BACKUP_FILE"
    read -p "请输入备份文件路径 (直接回车使用默认): " IN
    IN="${IN:-$DEFAULT_BACKUP_FILE}"
    if [ ! -f "$IN" ]; then
        echo -e "${RED}错误：文件不存在: $IN${RESET}"
        read -p "按回车键返回..."
        return
    fi
    echo -e "${YELLOW}⚠️  警告：此操作将覆盖当前的面板数据！${RESET}"
    read -p "确认恢复吗？[y/N]: " ANS
    case "$ANS" in y|Y) ;; *) return ;; esac
    echo -e "${CYAN}正在恢复...${RESET}"
    tar -xzf "$IN" -C "$(dirname "$DATA_FILE")"
    echo -e "${CYAN}重启面板服务...${RESET}"
    systemctl restart "$SERVICE_NAME"
    echo -e "${GREEN}✅ 恢复完成！${RESET}"
    read -p "按回车键返回..."
}

install_ftp(){
    clear
    echo -e "${GREEN}📂 FTP/SFTP 远程备份工具...${RESET}"
    echo -e "${YELLOW}提示：HiaPortFusion 默认备份文件路径：${DEFAULT_BACKUP_FILE}${RESET}"
    echo -e "${CYAN}正在拉取第三方备份脚本...${RESET}"
    need_cmd curl
    bash <(curl -sL https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    echo -e "${GREEN}工具执行结束。${RESET}"
    read -p "按回车键返回..."
}

cron_manager() {
    while true; do
        clear
        echo -e "${CYAN}--- 定时备份管理 ---${RESET}"
        if [ -f "$CRON_FILE" ]; then
            echo -e "当前状态: ${GREEN}已启用${RESET}"
        else
            echo -e "当前状态: ${YELLOW}未启用${RESET}"
        fi
        echo -e "--------------------"
        echo -e "1. 添加/更新 定时任务"
        echo -e "2. 删除 定时任务"
        echo -e "0. 返回上级"
        echo -e "--------------------"
        read -p "请选择: " OPT
        case "$OPT" in
            1)
                ensure_cron_ready || break
                write_export_helper
                echo -e "\n请选择备份频率："
                echo "1. 每天"
                echo "2. 每周"
                read -p "选择 [1-2]: " FREQ
                local D="*"
                if [ "$FREQ" = "2" ]; then
                    read -p "周几备份 (1-7, 7=周日): " WD
                    case "$WD" in
                         1) D="1" ;; 2) D="2" ;; 3) D="3" ;; 4) D="4" ;;
                         5) D="5" ;; 6) D="6" ;; 7) D="0" ;;
                         *) echo -e "${RED}无效输入${RESET}"; sleep 1; continue ;;
                    esac
                fi
                read -p "几点备份 (0-23): " HH
                read -p "几分备份 (0-59): " MM
                cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
$MM $HH * * $D root $EXPORT_HELPER >/dev/null 2>&1
EOF
                echo -e "${GREEN}✅ 定时任务已添加！${RESET}"
                sleep 2
                ;;
            2)
                rm -f "$CRON_FILE"
                rm -f "$EXPORT_HELPER"
                echo -e "${GREEN}✅ 定时任务已删除。${RESET}"
                sleep 1
                ;;
            0) return ;;
            *) ;;
        esac
    done
}

backup_menu() {
    while true; do
        clear
        echo -e "${GREEN}==========================================${RESET}"
        echo -e "${GREEN}       备份与恢复管理 (HiaPortFusion)     ${RESET}"
        echo -e "${GREEN}==========================================${RESET}"
        echo -e "1. 手动一键备份"
        echo -e "2. 手动恢复备份"
        echo -e "3. 定时自动备份"
        echo -e "4. FTP/SFTP 远程备份工具"
        echo -e "0. 返回主菜单"
        echo -e "------------------------------------------"
        read -p "请选择 [0-4]: " OPT
        case "$OPT" in
            1) manual_backup ;;
            2) manual_restore ;;
            3) cron_manager ;;
            4) install_ftp ;;
            0) return ;;
            *) echo -e "${RED}无效输入${RESET}"; sleep 1 ;;
        esac
    done
}

# ================= 主菜单逻辑 =================

manage_panel() {
    clear
    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}    HiaPortFusion 面板管理菜单            ${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
    
    if [ -f "$SERVICE_FILE" ]; then
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            echo -e "状态: ${GREEN}运行中${RESET}"
        else
            echo -e "状态: ${RED}已停止${RESET}"
        fi
    else
        echo -e "状态: ${YELLOW}未安装${RESET}"
    fi
    
    echo -e "------------------------------------------"
    echo -e "1. 安装面板"
    echo -e "2. 卸载面板"
    echo -e "3. 修改端口"
    echo -e "------------------------------------------"
    echo -e "4. 查看状态"
    echo -e "5. 查看日志"
    echo -e "6. 重启服务"
    echo -e "7. 停止服务"
    echo -e "8. 启动服务"
    echo -e "------------------------------------------"
    echo -e "9. 备份与恢复管理"
    echo -e "0. 退出脚本"
    echo -e "${GREEN}------------------------------------------${RESET}"
    
    read -p "请选择 [0-9]: " OPT
    
    case "$OPT" in
        1)
            clear
            echo -e "${CYAN}--- 安装向导 ---${RESET}"
            echo -e "1. 快速安装部署"
            echo -e "2. 自编译部署"
            echo -e "0. 返回上级"
            read -p "请选择: " INST_OPT
            case "$INST_OPT" in
                1) 
                    bash <(curl -fsSL https://raw.githubusercontent.com/nurohia/hiaportfusion/main/quickpan.sh) 
                    read -p "按回车键继续..." 
                    ;;
                2) 
                    # 1. 检测是否有安装
                    if [ -f "$SERVICE_FILE" ] || [ -f "$PANEL_BIN" ]; then
                        echo -e "${RED}⚠️  检测到 HiaPortFusion 面板已安装！${RESET}"
                        echo -e "------------------------------------------------"
                        read -p "输入 'y' 卸载当前版本并继续安装，其他键取消: " UN_ACT
                        
                        if [[ "$UN_ACT" == "y" || "$UN_ACT" == "Y" ]]; then
                            echo -e "${CYAN}>>> 正在启动卸载程序...${RESET}"
                            bash <(curl -fsSL https://raw.githubusercontent.com/nurohia/hiaportfusion/main/uninstall.sh)
                            
                            echo -e "${GREEN}✅ 卸载流程结束。${RESET}"
                            echo -e "${CYAN}>>> 正在自动启动自编译安装...${RESET}"
                            sleep 2
                        else
                            echo -e "${RED}操作已取消。${RESET}"
                            read -p "按回车键返回..."
                            return
                        fi
                    fi
                    
                    echo -e "${YELLOW}>>> 开始执行自编译安装脚本...${RESET}"
                    bash <(curl -fsSL https://raw.githubusercontent.com/nurohia/hiaportfusion/main/panel.sh) 
                    
                    read -p "按回车键继续..." 
                    ;;
                *) ;;
            esac
            ;;
        2)
            bash <(curl -fsSL https://raw.githubusercontent.com/nurohia/hiaportfusion/main/uninstall.sh)
            read -p "按回车键继续..."
            ;;
        3) update_panel_port ;;
        4) check_status ;;
        5) view_logs ;;
        6) service_control "restart" ;;
        7) service_control "stop" ;;
        8) service_control "start" ;;
        9) backup_menu ;;
        0) exit 0 ;;
        *) 
            echo -e "${RED}无效输入${RESET}" 
            sleep 1 
            ;;
    esac
}

# ================= 脚本入口 =================

check_root

while true; do
    manage_panel
done
