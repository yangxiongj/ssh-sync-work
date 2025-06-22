#!/bin/bash

# 加载环境变量
if [ -f "$(dirname "$0")/.sync-env" ]; then
    source "$(dirname "$0")/.sync-env"
fi

# 服务配置
SERVICE_NAME="file-sync-service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-files.sh"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
REMOTE_HELPER_SCRIPT="$SCRIPT_DIR/remote-sync-helper.sh"

# 导入配置处理函数
source "$SYNC_SCRIPT"

# 服务状态码定义
declare -A SERVICE_STATUS=(
    ["SUCCESS"]="成功"
    ["ERROR"]="错误"
    ["WARNING"]="警告"
    ["RUNNING"]="运行中"
    ["STOPPED"]="已停止"
    ["ENABLED"]="已启用"
    ["DISABLED"]="未启用"
)

# 统一的状态输出函数（只输出到命令行，不写文件）
function log_service() {
    local level="$1"
    local message="$2"
    
    case "$level" in
        "ERROR")
            echo "✗ $message" >&2
            ;;
        "SUCCESS")
            echo "✓ $message"
            ;;
        "INFO")
            echo "ℹ $message"
            ;;
        "WARNING")
            echo "⚠ $message"
            ;;
    esac
}

# 远程清理函数
function cleanup_remote() {
    local remote_host="$1"
    local remote_port="$2"
    
    if [ -n "$remote_host" ] && [ -n "$remote_port" ]; then
        log_service "INFO" "清理远程临时文件"
        ssh -o ConnectTimeout=5 -p "$remote_port" "$remote_host" "rm -f /tmp/remote-sync-helper.sh" 2>/dev/null || true
    fi
}

# 获取服务状态
function get_service_status() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "RUNNING"
    elif systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "STOPPED"
    elif systemctl list-unit-files | grep -q "^$SERVICE_NAME"; then
        echo "DISABLED"
    else
        echo "NOT_FOUND"
    fi
}

# 显示服务状态
function show_service_status() {
    local status=$(get_service_status)
    local status_msg="${SERVICE_STATUS[$status]:-$status}"
    
    echo "检查服务状态..."
    echo "服务状态: $status_msg"
    
    if [ "$status" = "RUNNING" ]; then
        echo ""
        echo "进程信息:"
        systemctl status "$SERVICE_NAME" --no-pager -l | head -10
    fi
    
    # 检查服务是否开机自启
    if systemctl is-enabled --quiet "$SERVICE_NAME"; then
        echo "开机自启: ${SERVICE_STATUS["ENABLED"]}"
    else
        echo "开机自启: ${SERVICE_STATUS["DISABLED"]}"
    fi
    
    # 显示远程服务器日志状态
    echo ""
    echo "远程服务器日志状态:"
    if [ -n "$REMOTE_HOST" ]; then
        local remote_log_info=$(ssh "$REMOTE_HOST" -p "$REMOTE_PORT" "
            if [ -d /var/log/sync-service ]; then 
                echo "系统日志: $(ls -la /var/log/sync-service/*.log 2>/dev/null | wc -l) 个文件"
                echo "最新日志: $(ls -t /var/log/sync-service/*.log 2>/dev/null | head -1)"
            elif [ -d ~/sync-logs ]; then
                echo "用户日志: $(ls -la ~/sync-logs/*.log 2>/dev/null | wc -l) 个文件"
                echo "最新日志: $(ls -t ~/sync-logs/*.log 2>/dev/null | head -1)"
            else
                echo "无远程日志目录"
            fi
        " 2>/dev/null)
        echo "$remote_log_info"
    else
        echo "无远程服务器配置"
    fi
}

# 启动服务
function start_service() {
    local status=$(get_service_status)
    
    case "$status" in
        "RUNNING")
            log_service "INFO" "服务已在运行"
            return 0
            ;;
        "NOT_FOUND")
            log_service "ERROR" "服务未安装，请先运行 sudo ./install.sh"
            return 1
            ;;
    esac
    
    log_service "INFO" "启动文件同步服务"
    
    if systemctl start "$SERVICE_NAME" 2>/dev/null; then
        sleep 2
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            log_service "SUCCESS" "服务启动成功"
            return 0
        fi
    fi
    
    log_service "ERROR" "服务启动失败"
    return 1
}

# 停止服务
function stop_service() {
    local status=$(get_service_status)
    
    if [ "$status" = "NOT_FOUND" ]; then
        log_service "ERROR" "服务未安装"
        return 1
    fi
    
    if [ "$status" = "STOPPED" ]; then
        log_service "INFO" "服务已停止"
        return 0
    fi
    
    log_service "INFO" "停止文件同步服务"
    
    # 获取远程配置以便清理
    local remote_config=$(grep -E "^(REMOTE_HOST|REMOTE_PORT)=" "$SCRIPT_DIR/.sync_cache" 2>/dev/null | tr '\n' ' ')
    local remote_host=$(echo "$remote_config" | grep -o 'REMOTE_HOST=[^[:space:]]*' | cut -d= -f2)
    local remote_port=$(echo "$remote_config" | grep -o 'REMOTE_PORT=[^[:space:]]*' | cut -d= -f2)
    
    if systemctl stop "$SERVICE_NAME" 2>/dev/null; then
        cleanup_remote "$remote_host" "$remote_port"
        log_service "SUCCESS" "服务已停止"
        return 0
    fi
    
    log_service "ERROR" "服务停止失败"
    return 1
}

# 重启服务
function restart_service() {
    log_service "INFO" "重启文件同步服务"
    stop_service
    sleep 1
    start_service
}

# 查看日志（远程日志访问提示）
function show_logs() {
    echo "本地客户端不保存详细日志，所有同步日志记录在远程服务器上"
    echo ""
    echo "查看远程同步日志:"
    
    if [ -n "$REMOTE_HOST" ] && [ -n "$REMOTE_PORT" ]; then
        if [ -n "$REMOTE_LOG_DIR" ]; then
            echo "  最近活动: ssh $REMOTE_HOST -p $REMOTE_PORT '$REMOTE_LOG_DIR/view-logs.sh recent'"
            echo "  实时同步: ssh $REMOTE_HOST -p $REMOTE_PORT '$REMOTE_LOG_DIR/view-logs.sh sync'"
            echo "  错误日志: ssh $REMOTE_HOST -p $REMOTE_PORT '$REMOTE_LOG_DIR/view-logs.sh error'"
            echo "  操作记录: ssh $REMOTE_HOST -p $REMOTE_PORT '$REMOTE_LOG_DIR/view-logs.sh operations'"
        else
            echo "  实时同步: ssh $REMOTE_HOST -p $REMOTE_PORT 'tail -f ~/sync-logs/sync.log'"
            echo "  错误日志: ssh $REMOTE_HOST -p $REMOTE_PORT 'tail -f ~/sync-logs/error.log'"
        fi
    else
        echo "  无远程服务器配置，请先安装服务"
    fi
    
    echo ""
    echo "systemd服务日志:"
    echo "  journalctl -u $SERVICE_NAME -f"
}

# 实时查看systemd日志
function follow_logs() {
    echo "实时查看systemd服务日志 (Ctrl+C 退出)..."
    journalctl -u "$SERVICE_NAME" -f --no-pager 2>/dev/null || {
        echo "无法获取systemd日志，可能需要sudo权限"
        echo "尝试: sudo journalctl -u $SERVICE_NAME -f"
    }
}

# 卸载服务
function uninstall_service() {
    if [ "$EUID" -ne 0 ]; then
        log_service "ERROR" "需要sudo权限来卸载服务"
        return 1
    fi
    
    log_service "INFO" "开始卸载文件同步服务"
    
    # 步骤1: 停止服务
    echo "步骤1: 停止服务"
    stop_service
    
    # 步骤2: 禁用服务
    echo "步骤2: 禁用服务"
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    
    # 步骤3: 删除服务文件
    echo "步骤3: 删除systemd服务文件"
    if [ -f "$SERVICE_FILE" ]; then
        rm -f "$SERVICE_FILE"
        log_service "SUCCESS" "已删除服务文件: $SERVICE_FILE"
    fi
    
    # 步骤4: 清理远程脚本
    echo "步骤4: 清理远程服务器脚本"
    
    # 加载配置以获取远程服务器信息
    if ! load_cached_config; then
        load_config
    fi
    
    if [ -n "$REMOTE_HOST" ]; then
        local remote_script_path="/tmp/remote-sync-helper.sh"
        echo "正在清理远程服务器脚本..."
        
        # 删除远程脚本
        if ssh "$REMOTE_HOST" -p "$REMOTE_PORT" "rm -f $remote_script_path" 2>/dev/null; then
            log_service "SUCCESS" "已删除远程脚本: $REMOTE_HOST:$remote_script_path"
        else
            log_service "WARNING" "无法删除远程脚本或脚本不存在"
        fi
        
        # 清理远程日志目录
        echo "正在清理远程服务器日志..."
        if ssh "$REMOTE_HOST" -p "$REMOTE_PORT" "rm -rf /var/log/sync-service 2>/dev/null || rm -rf ~/sync-logs 2>/dev/null" 2>/dev/null; then
            log_service "SUCCESS" "已清理远程日志目录"
        fi
    else
        log_service "WARNING" "跳过远程脚本清理（无有效配置）"
    fi
    
    # 步骤5: 清理本地缓存
    echo "步骤5: 清理本地缓存文件"
    
    # 删除配置缓存文件
    rm -f "$SCRIPT_DIR/.sync_cache" 2>/dev/null && log_service "SUCCESS" "已删除配置缓存"
    rm -f "$SCRIPT_DIR/.sync-env" 2>/dev/null && log_service "SUCCESS" "已删除环境变量文件"
    
    # 步骤6: 重新加载systemd配置
    echo "步骤6: 重新加载systemd配置"
    systemctl daemon-reload
    
    echo ""
    echo "=== 卸载完成 ==="
    echo "已清理以下组件:"
    echo "  ✓ systemd服务文件"
    echo "  ✓ 远程助手脚本"
    echo "  ✓ 远程日志目录"
    echo "  ✓ 配置缓存文件"
    
    log_service "SUCCESS" "服务卸载完成，已清理所有相关文件"
}

# 安装服务函数（调用install.sh）
function install_service() {
    echo "调用统一安装脚本..."
    
    # 检查install.sh是否存在
    local install_script="$SCRIPT_DIR/install.sh"
    if [ ! -f "$install_script" ]; then
        log_service "ERROR" "找不到安装脚本 $install_script"
        exit 1
    fi
    
    # 检查是否有sudo权限
    if [ "$EUID" -ne 0 ]; then
        echo "需要sudo权限来安装系统服务"
        echo "正在调用: sudo $install_script"
        exec sudo "$install_script"
    else
        # 已经是root权限，直接执行
        exec "$install_script"
    fi
}

# 显示帮助信息
function show_help() {
    echo "文件同步服务管理"
    echo "用法: $0 {install|start|stop|restart|status|logs|logs-f|uninstall}"
    echo ""
    echo "命令:"
    echo "  install     安装服务并设置开机自启 (需要sudo)"
    echo "  start       启动服务"
    echo "  stop        停止服务"
    echo "  restart     重启服务"
    echo "  status      查看服务状态"
    echo "  logs        查看日志访问提示"
    echo "  logs-f      实时查看systemd服务日志"
    echo "  uninstall   卸载服务 (需要sudo)"
    echo ""
    echo "注意: 详细的同步日志记录在远程服务器上"
    echo "      install命令会自动调用 ./install.sh"
    echo ""
    echo "示例:"
    echo "  sudo $0 install    # 安装服务"
    echo "  $0 start           # 启动服务"
    echo "  $0 status          # 查看状态"
    echo "  $0 logs            # 查看日志访问提示"
    echo "  $0 logs-f          # 实时查看systemd日志"
    echo "  sudo $0 uninstall  # 卸载服务"
}

# 主执行逻辑
function main() {
    case "${1:-status}" in
        "install")
            install_service
            ;;
        "start")
            start_service
            ;;
        "stop")
            stop_service
            ;;
        "restart")
            restart_service
            ;;
        "status")
            show_service_status
            ;;
        "logs")
            show_logs
            ;;
        "logs-f"|"follow")
            follow_logs
            ;;
        "uninstall")
            uninstall_service
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@" 
