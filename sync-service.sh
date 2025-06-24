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
CONFIG_FILE="/mnt/d/sync.yaml"  # 全局定义配置文件路径

# 导入配置处理函数
source "$SYNC_SCRIPT"

# 服务状态码定义
declare -A SERVICE_STATUS=(
    ["SUCCESS"]="成功"
    ["ERROR"]="错误"
    ["WARNING"]="警告"
    ["RUNNING"]="运行中"
    ["WAITING"]="等待配置"
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
        ssh -o ConnectTimeout=5 -p "$remote_port" "$remote_host" "rm -f /tmp/sync/*" 2>/dev/null || true
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
    
    # 显示配置文件状态
    echo ""
    echo "配置文件状态:"
    if [ -f "$CONFIG_FILE" ]; then
        local config_timestamp=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null)
        local config_size=$(stat -c %s "$CONFIG_FILE" 2>/dev/null)
        local config_date=$(date -d "@$config_timestamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
        echo "  配置文件: $CONFIG_FILE"
        echo "  文件大小: ${config_size} 字节"
        echo "  修改时间: $config_date"
        
        # 尝试加载配置显示摘要信息
        if load_cached_config || load_config; then
            echo "  远程主机: ${REMOTE_HOST}:${REMOTE_PORT}"
            echo "  本地目录: ${#LOCAL_DIRS[@]} 个"
        else
            echo "  配置状态: 解析失败"
        fi
    else
        echo "  配置文件: 不存在 ($CONFIG_FILE)"
    fi
    
    if [ "$status" = "RUNNING" ]; then
        echo ""
        echo "进程信息:"
        systemctl status "$SERVICE_NAME" --no-pager -l | head -10
        
        # 检查是否在等待配置更新
        local waiting_config=false
        if journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null | grep -q "等待配置目录更新"; then
            echo ""
            echo "当前状态: ${SERVICE_STATUS["WAITING"]}"
            echo "服务正在等待directories配置项更新"
            echo "请在sync.yaml中配置至少一个目录后服务将自动开始同步"
            waiting_config=true
        fi
        
        if [ "$waiting_config" = false ]; then
            # 显示同步的目录数量
            local sync_dirs=$(journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null | grep -o "共 [0-9]* 个目录需要同步" | tail -1 | grep -o "[0-9]*")
            if [ -n "$sync_dirs" ]; then
                echo ""
                echo "当前同步: $sync_dirs 个目录"
            fi
        fi
    fi
    
    # 检查服务是否开机自启
    if systemctl is-enabled --quiet "$SERVICE_NAME"; then
        echo "开机自启: ${SERVICE_STATUS["ENABLED"]}"
    else
        echo "开机自启: ${SERVICE_STATUS["DISABLED"]}"
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
    
    # 在启动服务前检查和初始化配置缓存
    log_service "INFO" "检查配置文件"
    if ! init_config_cache; then
        log_service "WARNING" "配置文件检查失败，服务仍将启动但可能使用默认配置"
    fi
    
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
    
    # 尝试从配置缓存获取远程配置信息以便清理
    local remote_host="$REMOTE_HOST"
    local remote_port="$REMOTE_PORT"
    
    systemctl stop "$SERVICE_NAME"
    
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

        # 步骤4: 清理远程脚本
    echo "步骤1: 读取配置"
        # 加载配置以获取远程服务器信息
    load_config

    # 步骤1: 停止服务
    echo "步骤2: 停止服务"
    stop_service
    
    # 步骤2: 禁用服务
    echo "步骤3: 禁用服务"
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    
    # 步骤3: 删除服务文件
    echo "步骤4: 删除systemd服务文件"
    if [ -f "$SERVICE_FILE" ]; then
        rm -f "$SERVICE_FILE"
        log_service "SUCCESS" "已删除服务文件: $SERVICE_FILE"
    fi
    #清除远程服务器脚本
    cleanup_remote "$REMOTE_HOST" "$REMOTE_PORT"

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
    echo "CONFIG_FILE: $CONFIG_FILE"
    # 检查是否有sudo权限
    if [ "$EUID" -ne 0 ]; then
        echo "需要sudo权限来安装系统服务"
        echo "正在调用: sudo $install_script \"$CONFIG_FILE\""
        exec sudo "$install_script" "$CONFIG_FILE"
    else
        # 已经是root权限，直接执行
        exec "$install_script" "$CONFIG_FILE"
    fi
}

# 显示帮助信息
function show_help() {
    echo "文件同步服务管理"
    echo "用法: $0 {install|start|stop|restart|status|config|refresh-config|logs-f|uninstall}"
    echo ""
    echo "服务管理命令:"
    echo "  install         安装服务并设置开机自启 (需要sudo)"
    echo "  start           启动服务"
    echo "  stop            停止服务"
    echo "  restart         重启服务"
    echo "  status          查看服务状态"
    echo "  logs-f          实时查看systemd服务日志"
    echo "  uninstall       卸载服务 (需要sudo)"
    echo ""
    echo "配置管理命令:"
    echo "  config          显示当前配置信息"
    echo "  refresh-config  强制刷新配置缓存"
    echo ""
    echo "当前配置文件: ${CONFIG_FILE:-未设置}"
    echo ""
    echo "注意: 详细的同步日志记录在远程服务器上"
    echo "      install命令会自动调用 ./install.sh"
    echo "      配置文件路径在安装时指定: sudo ./install.sh [CONFIG_FILE]"
    echo ""
    echo "示例:"
    echo "  sudo ./install.sh                     # 使用默认配置文件安装"
    echo "  sudo ./install.sh /path/to/sync.yaml  # 使用指定配置文件安装"
    echo "  $0 start                              # 启动服务"
    echo "  $0 status                             # 查看状态"
    echo "  $0 config                             # 查看配置"
    echo "  $0 refresh-config                     # 刷新配置"
    echo "  $0 logs-f                             # 实时查看systemd日志"
    echo "  sudo $0 uninstall                     # 卸载服务"
}

# 初始化配置缓存
function init_config_cache() {
    log_service "INFO" "初始化配置缓存"
    
    # 尝试加载缓存的配置
    if ! load_cached_config; then
        log_service "INFO" "缓存配置无效或不存在，重新加载配置文件"
        load_config
        if [ $? -eq 0 ]; then
            log_service "SUCCESS" "配置加载成功"
            log_service "INFO" "远程主机: ${REMOTE_HOST}:${REMOTE_PORT}"
            log_service "INFO" "远程目录: ${REMOTE_DIR}"
            log_service "INFO" "本地目录数量: ${#LOCAL_DIRS[@]}"
        else
            log_service "ERROR" "配置加载失败"
            return 1
        fi
    else
        log_service "SUCCESS" "使用缓存配置"
        log_service "INFO" "远程主机: ${REMOTE_HOST}:${REMOTE_PORT}"
        log_service "INFO" "远程目录: ${REMOTE_DIR}"
        log_service "INFO" "本地目录数量: ${#LOCAL_DIRS[@]}"
    fi
    
    return 0
}

# 刷新配置缓存
function refresh_config_cache() {
    log_service "INFO" "刷新配置缓存"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_service "ERROR" "配置文件不存在: $CONFIG_FILE"
        return 1
    fi
    
    # 强制重新加载配置
    load_config
    if [ $? -eq 0 ]; then
        log_service "SUCCESS" "配置刷新成功"
        return 0
    else
        log_service "ERROR" "配置刷新失败"
        return 1
    fi
}

# 显示当前配置
function show_config() {
    echo "当前配置信息:"
    echo "  配置文件: $CONFIG_FILE"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "  状态: 文件不存在"
        return 1
    fi
    
    # 尝试加载配置
    if ! load_cached_config; then
        load_config
    fi
    
    if [ -n "$REMOTE_HOST" ]; then
        echo "  远程主机: $REMOTE_HOST"
        echo "  远程端口: $REMOTE_PORT"
        echo "  远程目录: $REMOTE_DIR"
        echo "  远程系统: $REMOTE_OS"
    else
        echo "  远程配置: 未配置"
    fi
    
    echo "  刷新间隔: ${REFRESH_INTERVAL}秒"
    echo "  调试模式: $DEBUG_MODE"
    
    if [ ${#LOCAL_DIRS[@]} -gt 0 ]; then
        echo "  本地目录:"
        for dir in "${LOCAL_DIRS[@]}"; do
            echo "    - $dir"
        done
    else
        echo "  本地目录: 未配置"
    fi
    
    if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
        echo "  排除模式:"
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            echo "    - $pattern"
        done
    fi
    
    echo "  日志目录: $LOG_DIR"
    echo "  配置时间戳: $CONFIG_TIMESTAMP"
}

# 在脚本启动时初始化配置
if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ $# -gt 0 ]; then
    init_config_cache >/dev/null 2>&1 || true
fi

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
        "logs-f"|"follow")
            follow_logs
            ;;
        "uninstall")
            uninstall_service
            ;;
        "config")
            show_config
            ;;
        "refresh-config")
            refresh_config_cache
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@" 
