#!/bin/bash

# 导入配置
source "./sync-files.sh" 2>/dev/null || {
    echo "错误: 无法加载 sync-files.sh"
    exit 1
}

SCRIPT_DIR="$(pwd)"
REMOTE_HELPER_SCRIPT="$SCRIPT_DIR/remote-sync-helper.sh"

# 状态码定义
declare -A INSTALL_STATUS=(
    ["SUCCESS"]="成功"
    ["ERROR"]="错误"
    ["WARNING"]="警告"
    ["FOUND"]="已找到"
    ["MISSING"]="未找到"
    ["INSTALLED"]="已安装"
)

# 统一的状态输出函数
function output_install_status() {
    local status_code="$1"
    local component="$2"
    local message="${INSTALL_STATUS[$status_code]:-$status_code}"
    
    case "$status_code" in
        "SUCCESS"|"FOUND"|"INSTALLED")
            echo "✓ $component: $message"
            ;;
        "ERROR"|"MISSING")
            echo "✗ $component: $message"
            ;;
        "WARNING")
            echo "⚠ $component: $message"
            ;;
    esac
}

# 初始化远程日志环境 (通过install.sh统一管理)
function init_remote_logging() {
    local remote_host="$1"
    local remote_port="$2"
    
    echo "为远程服务器初始化日志环境..."
    
    if [ -z "$remote_host" ] || [ -z "$remote_port" ]; then
        output_install_status "WARNING" "远程日志初始化"
        echo "无远程服务器配置，跳过日志环境初始化"
        return 1
    fi
    
    # 检查远程连接
    if ! ssh_exec "$remote_host" "$remote_port" "echo '连接测试'"; then
        output_install_status "WARNING" "远程连接"
        echo "无法连接到远程服务器，跳过日志环境初始化"
        return 1
    fi
    
    # 创建远程脚本内容
    local remote_setup_script
    remote_setup_script=$(cat << 'REMOTE_SCRIPT'
#!/bin/bash
# 远程服务器日志环境初始化脚本
# 统一使用 /tmp/sync/ 目录
LOG_DIR="/tmp/sync"

# 创建基础日志目录
mkdir -p "$LOG_DIR" 2>/dev/null

# 设置远程环境变量
echo "export SYNC_LOG_DIR=\"$LOG_DIR\"" > ~/.sync-env

# 创建基础日志文件
touch "$LOG_DIR/sync.log"
touch "$LOG_DIR/error.log" 
touch "$LOG_DIR/operations.log"

# 写入初始化日志条目
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] [INSTALL] 远程日志环境初始化完成" >> "$LOG_DIR/sync.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] [INSTALL] 日志目录: $LOG_DIR" >> "$LOG_DIR/sync.log"

# 创建远程日志查看脚本
cat > "$LOG_DIR/view-logs.sh" << "EOF"
#!/bin/bash
LOG_DIR="$(dirname "$0")"
case "${1:-sync}" in
    "sync") tail -f "$LOG_DIR/sync.log" 2>/dev/null || echo "同步日志不存在" ;;
    "error") tail -f "$LOG_DIR/error.log" 2>/dev/null || echo "错误日志不存在" ;;
    "operations") tail -f "$LOG_DIR/operations.log" 2>/dev/null || echo "操作日志不存在" ;;
    "recent") tail -20 "$LOG_DIR/sync.log" 2>/dev/null | grep -E "(OPERATION|ERROR)" || echo "无最近活动" ;;
    "list") ls -la "$LOG_DIR"/*.log 2>/dev/null || echo "无日志文件" ;;
    *) echo "用法: $0 {sync|error|operations|recent|list}" ;;
esac
EOF

chmod +x "$LOG_DIR/view-logs.sh"

# 设置远程日志自动清理
# 使用 remote-sync-helper.sh 的清理功能
(crontab -l 2>/dev/null; echo "0 2 * * * $LOG_DIR/remote-sync-helper.sh cleanup_logs 7 >/dev/null 2>&1") | crontab - 2>/dev/null

echo "$LOG_DIR"
REMOTE_SCRIPT
)
    
    if echo "$remote_setup_script" | ssh_exec "$remote_host" "$remote_port" "cat > /tmp/init-remote-logging.sh && chmod +x /tmp/init-remote-logging.sh && /tmp/init-remote-logging.sh && rm -f /tmp/init-remote-logging.sh"; then
        local remote_log_dir=$(ssh_exec "$remote_host" "$remote_port" "
            if [ -d /tmp/sync ]; then
                echo '/tmp/sync'
            fi
        ")
        
        if [ -n "$remote_log_dir" ]; then
            output_install_status "SUCCESS" "远程日志环境"
            echo "远程日志位置: $remote_log_dir"
            echo "查看远程日志: ssh $remote_host -p $remote_port '$remote_log_dir/view-logs.sh recent'"
            
            # 本地只保存远程日志信息，用于后续访问
            local env_file="$SCRIPT_DIR/.sync-env"
            echo "export REMOTE_LOG_DIR=\"$remote_log_dir\"" > "$env_file"
            echo "export REMOTE_HOST=\"$remote_host\"" >> "$env_file"
            echo "export REMOTE_PORT=\"$remote_port\"" >> "$env_file"
            
            return 0
        fi
    fi
    
    output_install_status "WARNING" "远程日志环境初始化失败"
    echo "远程服务器将在首次运行时自动创建日志目录"
    return 1
}

# 设置本地环境变量（不需要本地日志文件）
function setup_local_environment() {
    echo "设置本地环境变量..."
    
    # 本地客户端是轻量级调度器，不需要详细日志
    local env_file="$SCRIPT_DIR/.sync-env"
    # 环境变量文件已经在 init_remote_logging 中创建，这里不需要额外操作
    
    output_install_status "SUCCESS" "本地环境设置"
    echo "本地客户端配置为轻量级调度器模式"
}

# 检查必要文件
function check_required_files() {
    echo "检查必要文件..."
    
    local required_files=("sync-files.sh" "sync-service.sh" "remote-sync-helper.sh")
    local missing_files=()
    
    for file in "${required_files[@]}"; do
        if [ -f "$file" ]; then
            output_install_status "FOUND" "$file"
        else
            output_install_status "MISSING" "$file"
            missing_files+=("$file")
        fi
    done
    
    if [ ${#missing_files[@]} -gt 0 ]; then
        echo "错误: 缺少必要文件: ${missing_files[*]}"
        return 1
    fi
    
    output_install_status "SUCCESS" "所有必要文件"
}

# 检查系统依赖
function check_system_dependencies() {
    echo "检查系统依赖..."
    
    local required_tools=("git" "rsync" "ssh" "tar" "scp")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            output_install_status "FOUND" "$tool"
        else
            output_install_status "MISSING" "$tool"
            missing_tools+=("tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo "错误: 缺少必要工具: ${missing_tools[*]}"
        return 1
    fi
    
    # 检查systemd
    if systemctl --version >/dev/null 2>&1; then
        output_install_status "FOUND" "systemd"
    else
        output_install_status "ERROR" "systemd"
        echo "错误: 系统不支持 systemd"
        return 1
    fi
    
    output_install_status "SUCCESS" "基础依赖检查"
}

# 检查性能优化工具
function check_performance_tools() {
    echo "检查性能优化工具..."
    
    # 检查lz4
    if ! command -v lz4 >/dev/null 2>&1; then
        output_install_status "WARNING" "lz4"
        echo "将自动安装以提升传输性能"
        install_tool "lz4"
    else
        output_install_status "INSTALLED" "lz4"
    fi
    
    # 检查pv
    if ! command -v pv >/dev/null 2>&1; then
        output_install_status "WARNING" "pv"
        echo "将自动安装以显示传输进度"
        install_tool "pv"
    else
        output_install_status "INSTALLED" "pv"
    fi
    
    output_install_status "SUCCESS" "性能工具检查"
}

# 安装工具
function install_tool() {
    local tool="$1"
    
    if [ -f /etc/debian_version ]; then
        apt-get update >/dev/null 2>&1 && apt-get install -y "$tool" >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum install -y "$tool" >/dev/null 2>&1 || dnf install -y "$tool" >/dev/null 2>&1
    elif [ -f /etc/fedora-release ]; then
        dnf install -y "$tool" >/dev/null 2>&1
    else
        echo "警告: 无法自动安装 $tool，请手动安装"
        return 1
    fi
    
    if command -v "$tool" >/dev/null 2>&1; then
        output_install_status "SUCCESS" "$tool 安装"
    else
        output_install_status "WARNING" "$tool 安装失败"
    fi
}

# 检查远程工具
function check_remote_tools() {
    local remote_host="$1"
    local remote_port="$2"
    local remote_os="$3"
    
    echo "检查远程服务器工具..."
    
    if ! ssh_exec "$remote_host" "$remote_port" "echo '连接测试'"; then
        output_install_status "WARNING" "远程连接"
        echo "无法连接到远程服务器，跳过工具检查"
        return 1
    fi
    
    local remote_check_result=$(ssh_exec "$remote_host" "$remote_port" '
        lz4_status="missing"; command -v lz4 >/dev/null 2>&1 && lz4_status="installed"
        pv_status="missing"; command -v pv >/dev/null 2>&1 && pv_status="installed"
        echo "$lz4_status:$pv_status"
    ')
    
    if [ -z "$remote_check_result" ]; then
        output_install_status "WARNING" "远程工具检查"
        return 1
    fi
    
    IFS=':' read -r lz4_status pv_status <<< "$remote_check_result"
    
    local tools_to_install=()
    [ "$lz4_status" = "missing" ] && tools_to_install+=("lz4")
    [ "$pv_status" = "missing" ] && tools_to_install+=("pv")
    
    if [ ${#tools_to_install[@]} -gt 0 ]; then
        echo "远程服务器缺少工具: ${tools_to_install[*]}"
        echo "正在安装远程工具..."
        
        local install_commands=""
        case "${remote_os,,}" in
            ubuntu|debian)
                install_commands="apt-get update >/dev/null 2>&1 && apt-get install -y ${tools_to_install[*]} >/dev/null 2>&1"
                ;;
            centos|rhel|redhat)
                install_commands="yum install -y ${tools_to_install[*]} >/dev/null 2>&1"
                ;;
            fedora)
                install_commands="dnf install -y ${tools_to_install[*]} >/dev/null 2>&1"
                ;;
            *)
                output_install_status "WARNING" "未知系统类型"
                return 1
                ;;
        esac
        
        if ssh_exec "$remote_host" "$remote_port" "$install_commands"; then
            output_install_status "SUCCESS" "远程工具安装"
        else
            output_install_status "WARNING" "远程工具安装失败"
            echo "提示: 在远程服务器手动执行: $install_commands"
        fi
    else
        output_install_status "SUCCESS" "远程工具"
    fi
}

# 上传远程脚本
function upload_remote_script() {
    local remote_host="$1"
    local remote_port="$2"
    
    echo "上传远程助手脚本..."
    
    if [ ! -f "$REMOTE_HELPER_SCRIPT" ]; then
        output_install_status "ERROR" "远程助手脚本"
        echo "找不到 $REMOTE_HELPER_SCRIPT"
        return 1
    fi
    
    if ! ssh_exec "$remote_host" "$remote_port" "echo '连接测试'"; then
        output_install_status "ERROR" "远程连接"
        echo "无法连接到远程服务器"
        echo "请检查:"
        echo "  1. 服务器地址和端口是否正确"
        echo "  2. SSH密钥是否已配置"
        echo "  3. 网络连接是否正常"
        return 1
    fi
    
    local remote_script_path="/tmp/sync/remote-sync-helper.sh"
    
    # 确保远程目录存在
    if ! ssh_exec "$remote_host" "$remote_port" "mkdir -p /tmp/sync"; then
        output_install_status "ERROR" "创建远程目录失败"
        return 1
    fi
    
    if scp -P "$remote_port" "$REMOTE_HELPER_SCRIPT" "$remote_host:$remote_script_path" 2>/dev/null; then
        output_install_status "SUCCESS" "脚本上传"
        
        if ssh_exec "$remote_host" "$remote_port" "chmod +x $remote_script_path"; then
            output_install_status "SUCCESS" "脚本权限设置"
            return 0
        else
            output_install_status "ERROR" "脚本权限设置"
            return 1
        fi
    else
        output_install_status "ERROR" "脚本上传失败"
        return 1
    fi
}

# 安装服务
function install_file_sync_service() {
    echo "开始安装文件同步服务..."
    
    # 步骤1: 加载配置
    echo ""
    echo "步骤1: 加载配置文件"
    if ! load_cached_config; then
        load_config
    fi
    
    # 步骤2: 初始化远程日志环境
    echo ""
    echo "步骤2: 初始化远程日志环境"
    if [ -n "$REMOTE_HOST" ]; then
        init_remote_logging "$REMOTE_HOST" "$REMOTE_PORT"
    else
        echo "跳过远程日志初始化（无有效配置）"
    fi
    
    # 步骤3: 设置本地环境
    echo ""
    echo "步骤3: 设置本地环境"
    setup_local_environment
    
    # 步骤4: 检查远程工具
    echo ""
    echo "步骤4: 检查远程服务器工具"
    if [ -n "$REMOTE_HOST" ]; then
        check_remote_tools "$REMOTE_HOST" "$REMOTE_PORT" "$REMOTE_OS"
    else
        echo "跳过远程工具检查（无有效配置）"
    fi
    
    # 步骤5: 上传远程脚本
    echo ""
    echo "步骤5: 上传远程助手脚本"
    if [ -n "$REMOTE_HOST" ]; then
        if upload_remote_script "$REMOTE_HOST" "$REMOTE_PORT"; then
            output_install_status "SUCCESS" "远程脚本上传"
        else
            output_install_status "WARNING" "远程脚本上传失败"
            echo "服务仍可正常安装，首次运行时会自动上传远程脚本"
        fi
    else
        echo "跳过远程脚本上传（无有效配置）"
    fi
    
    # 步骤6: 创建systemd服务
    echo ""
    echo "步骤6: 创建systemd服务"
    
    local SERVICE_NAME="file-sync-service"
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    
    # 创建服务文件，本地服务主要负责调度，详细日志在远程
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=文件同步服务（客户端调度器）
After=network.target

[Service]
Type=simple
User=$SUDO_USER
Group=$SUDO_USER
WorkingDirectory=$SCRIPT_DIR
ExecStartPre=/bin/bash -c 'source $SCRIPT_DIR/.sync-env 2>/dev/null || true'
ExecStart=/bin/bash -c 'source $SCRIPT_DIR/.sync-env 2>/dev/null; $SCRIPT_DIR/sync-files.sh'
Restart=always
RestartSec=30
StandardOutput=null
StandardError=journal
KillMode=process
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
    
    output_install_status "SUCCESS" "systemd服务创建"
    
    # 显示配置预览
    echo ""
    echo "当前配置预览:"
    head -5 sync.yaml 2>/dev/null | while read line; do
        echo "  $line"
    done
    
    echo ""
    echo "开始安装服务..."
    
    if [ "$EUID" -ne 0 ]; then
        echo "需要sudo权限来安装系统服务"
        echo "请输入sudo密码..."
    fi
    
    # 设置权限并启用服务
    chmod +x "$SCRIPT_DIR/sync-files.sh"
    chmod +x "$SCRIPT_DIR/sync-service.sh"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    
    echo ""
    echo "启动服务..."
    systemctl start "$SERVICE_NAME"
    
    echo ""
    echo "检查服务状态..."
    sleep 2
    
    echo ""
    echo "=== 安装完成 ==="
    echo "服务已安装并启动，将在下次开机时自动启动"
    echo "客户端运行在静默模式，详细日志记录在远程服务器"
    echo ""
    echo "本地服务管理命令:"
    echo "  查看状态: ./sync-service.sh status"
    echo "  停止服务: ./sync-service.sh stop"
    echo "  启动服务: ./sync-service.sh start"
    echo "  重启服务: ./sync-service.sh restart"
    echo "  查看管理日志: ./sync-service.sh logs"
    echo "  实时管理日志: ./sync-service.sh logs-f"
    echo "  卸载服务: sudo ./sync-service.sh uninstall"
    echo ""
    echo "远程日志查看命令:"
    
    if [ -n "$REMOTE_HOST" ] && [ -n "$REMOTE_PORT" ]; then
        local remote_log_dir=$(ssh_exec "$REMOTE_HOST" "$REMOTE_PORT" "
            if [ -d /tmp/sync ]; then
                echo '/tmp/sync'
            fi
        " 2>/dev/null)
        
        if [ -n "$remote_log_dir" ]; then
            echo "  查看同步摘要: ssh $REMOTE_HOST -p $REMOTE_PORT '$remote_log_dir/view-logs.sh recent'"
            echo "  实时同步日志: ssh $REMOTE_HOST -p $REMOTE_PORT '$remote_log_dir/view-logs.sh sync'"
            echo "  实时错误日志: ssh $REMOTE_HOST -p $REMOTE_PORT '$remote_log_dir/view-logs.sh error'"
            echo "  操作记录日志: ssh $REMOTE_HOST -p $REMOTE_PORT '$remote_log_dir/view-logs.sh operations'"
        else
            echo "  远程日志目录未检测到，将在首次同步时自动创建"
        fi
    else
        echo "  无远程服务器配置"
    fi
    
    echo ""
    echo "日志说明:"
    echo "  - 客户端: 仅记录服务管理日志"
    echo "  - 远程服务器: 记录详细的同步操作日志"
    echo "  - 错误处理: 自动重试和故障恢复"
}

# 主执行逻辑
function main() {
    echo "=== 文件同步服务安装程序 ==="
    echo ""
    
    # 检查sudo权限
    if [ "$EUID" -ne 0 ]; then
        echo "请使用sudo权限运行此脚本"
        echo "使用: sudo $0"
        exit 1
    fi
    
    # 基础检查
    check_required_files || exit 1
    echo ""
    
    check_system_dependencies || exit 1
    echo ""
    
    check_performance_tools
    echo ""
    
    # 安装服务
    install_file_sync_service
}

# 执行主函数
main "$@" 