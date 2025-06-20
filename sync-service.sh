#!/bin/bash

# 文件同步服务管理脚本 - 支持systemd服务管理
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="file-sync-service"
MAIN_SCRIPT="$SCRIPT_DIR/sync-files.sh"
LOG_FILE="$SCRIPT_DIR/service.log"
PID_FILE="$SCRIPT_DIR/service.pid"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
REMOTE_HELPER_SCRIPT="$SCRIPT_DIR/remote-sync-helper.sh"

# 导入配置处理函数
source "$MAIN_SCRIPT"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

function write_service_log() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local log_entry="[$timestamp] $message"
    echo -e "$log_entry"
    echo "$log_entry" >> "$LOG_FILE"
}

# 上传远程脚本函数
function upload_remote_script() {
    local remote_host="$1"
    local remote_port="$2"
    local remote_script_path="/tmp/remote-sync-helper.sh"
    
    echo -e "${CYAN}上传远程助手脚本到 $remote_host:$remote_port...${NC}"
    
    # 检查本地远程脚本是否存在
    if [ ! -f "$REMOTE_HELPER_SCRIPT" ]; then
        echo -e "${RED}错误: 找不到远程助手脚本 $REMOTE_HELPER_SCRIPT${NC}"
        return 1
    fi
    
    # 测试SSH连接
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$remote_host" -p "$remote_port" "echo 'SSH连接测试成功'" 2>/dev/null; then
        echo -e "${RED}错误: 无法连接到远程服务器 $remote_host:$remote_port${NC}"
        echo -e "${YELLOW}请检查:${NC}"
        echo -e "${WHITE}  1. 服务器地址和端口是否正确${NC}"
        echo -e "${WHITE}  2. SSH密钥是否已配置${NC}"
        echo -e "${WHITE}  3. 网络连接是否正常${NC}"
        return 1
    fi
    
    # 上传脚本
    if scp -P "$remote_port" "$REMOTE_HELPER_SCRIPT" "$remote_host:$remote_script_path" 2>/dev/null; then
        # 设置执行权限
        if ssh "$remote_host" -p "$remote_port" "chmod +x $remote_script_path" 2>/dev/null; then
            echo -e "${GREEN}✓ 远程助手脚本上传成功${NC}"
            return 0
        else
            echo -e "${RED}错误: 无法设置远程脚本执行权限${NC}"
            return 1
        fi
    else
        echo -e "${RED}错误: 远程脚本上传失败${NC}"
        return 1
    fi
}

function install_sync_service() {
    write_service_log "开始安装文件同步服务..."
    
    # 检查是否有sudo权限
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 需要sudo权限来安装systemd服务${NC}"
        echo "请使用: sudo $0 install"
        exit 1
    fi
    
    # 步骤1: 加载配置
    echo ""
    echo -e "${CYAN}步骤1: 加载配置文件${NC}"
    
    # 使用导入的配置函数
    if ! load_cached_config; then
        load_config
    fi
    
    # 步骤2: 上传远程助手脚本
    echo ""
    echo -e "${CYAN}步骤2: 上传远程助手脚本${NC}"
    
    if [ -n "$REMOTE_HOST" ]; then
        if upload_remote_script "$REMOTE_HOST" "$REMOTE_PORT"; then
            echo -e "${GREEN}✓ 远程脚本上传完成${NC}"
        else
            echo -e "${YELLOW}警告: 远程脚本上传失败，服务仍可正常安装${NC}"
            echo -e "${YELLOW}首次运行时会自动上传远程脚本${NC}"
        fi
    else
        echo -e "${YELLOW}跳过远程脚本上传（无有效配置）${NC}"
    fi
    
    # 步骤3: 创建systemd服务
    echo ""
    echo -e "${CYAN}步骤3: 创建systemd服务${NC}"
    
    # 创建systemd服务文件
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=File Sync Service
After=network.target

[Service]
Type=simple
User=$SUDO_USER
Group=$SUDO_USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=$MAIN_SCRIPT
Restart=always
RestartSec=10
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF
    
    # 设置脚本执行权限
    chmod +x "$MAIN_SCRIPT"
    
    # 重新加载systemd配置
    systemctl daemon-reload
    
    # 启用服务开机自启
    systemctl enable "$SERVICE_NAME"
    
    write_service_log "服务安装成功！已创建开机自启动服务。"
    write_service_log "服务名称: $SERVICE_NAME"
    write_service_log "服务文件: $SERVICE_FILE"
}

function uninstall_sync_service() {
    write_service_log "开始卸载文件同步服务..."
    
    # 检查是否有sudo权限
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 需要sudo权限来卸载systemd服务${NC}"
        echo "请使用: sudo $0 uninstall"
        exit 1
    fi
    
    # 停止服务
    stop_sync_service
    
    # 禁用服务
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    
    # 删除服务文件
    if [ -f "$SERVICE_FILE" ]; then
        rm -f "$SERVICE_FILE"
    fi
    
    # 重新加载systemd配置
    systemctl daemon-reload
    
    write_service_log "服务卸载完成。"
}

function start_sync_service() {
    write_service_log "启动文件同步服务..."
    
    # 检查服务是否已安装
    if [ ! -f "$SERVICE_FILE" ]; then
        echo -e "${RED}错误: 服务未安装，请先运行安装命令${NC}"
        echo "使用: sudo $0 install"
        exit 1
    fi
    
    # 启动服务
    systemctl start "$SERVICE_NAME"
    
    if [ $? -eq 0 ]; then
        write_service_log "服务启动成功"
    else
        write_service_log "服务启动失败"
        exit 1
    fi
}

function stop_sync_service() {
    write_service_log "停止文件同步服务..."
    
    # 停止systemd服务
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    
    # 清理PID文件
    if [ -f "$PID_FILE" ]; then
        rm -f "$PID_FILE"
    fi
    
    write_service_log "服务已停止"
}

function restart_sync_service() {
    write_service_log "重启文件同步服务..."
    
    systemctl restart "$SERVICE_NAME"
    
    if [ $? -eq 0 ]; then
        write_service_log "服务重启成功"
    else
        write_service_log "服务重启失败"
        exit 1
    fi
}

function get_service_status() {
    write_service_log "检查服务状态..."
    
    # 检查systemd服务状态
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}服务运行中${NC}"
        systemctl status "$SERVICE_NAME" --no-pager -l
    else
        echo -e "${RED}服务未运行${NC}"
    fi
    
    # 检查服务是否开机自启
    if systemctl is-enabled --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}开机自启: 已启用${NC}"
    else
        echo -e "${YELLOW}开机自启: 未启用${NC}"
    fi
    
    # 显示最近的日志
    echo -e "\n${CYAN}最近的服务日志:${NC}"
    if [ -f "$LOG_FILE" ]; then
        tail -n 10 "$LOG_FILE"
    else
        echo "暂无日志文件"
    fi
}

function show_logs() {
    if [ -f "$LOG_FILE" ]; then
        echo -e "${CYAN}服务日志内容:${NC}"
        if [ "$1" = "follow" ]; then
            tail -f "$LOG_FILE"
        else
            tail -n 50 "$LOG_FILE"
        fi
    else
        echo -e "${YELLOW}日志文件不存在${NC}"
    fi
}

function show_usage() {
    echo -e "${CYAN}文件同步服务管理脚本${NC}"
    echo ""
    echo "用法: $0 [命令]"
    echo ""
    echo "命令:"
    echo "  install     安装服务并设置开机自启 (需要sudo)"
    echo "  uninstall   卸载服务 (需要sudo)"
    echo "  start       启动服务"
    echo "  stop        停止服务"
    echo "  restart     重启服务"
    echo "  status      查看服务状态"
    echo "  logs        查看服务日志"
    echo "  logs-f      实时查看服务日志"
    echo ""
    echo "示例:"
    echo "  sudo $0 install     # 安装服务"
    echo "  $0 start           # 启动服务"
    echo "  $0 status          # 查看状态"
    echo "  $0 logs-f          # 实时查看日志"
}

# 主逻辑
case "$1" in
    install)
        install_sync_service
        ;;
    uninstall)
        uninstall_sync_service
        ;;
    start)
        start_sync_service
        ;;
    stop)
        stop_sync_service
        ;;
    restart)
        restart_sync_service
        ;;
    status)
        get_service_status
        ;;
    logs)
        show_logs
        ;;
    logs-f)
        show_logs follow
        ;;
    *)
        show_usage
        exit 1
        ;;
esac 