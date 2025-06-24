#!/bin/bash

# 加载环境变量
if [ -f "$(dirname "$0")/.sync-env" ]; then
    source "$(dirname "$0")/.sync-env"
fi

# 本地客户端不需要详细日志，只在远程服务器记录

# 导入YAML解析库
if ! command -v yq >/dev/null 2>&1; then
    echo "错误: 需要安装 yq 工具来解析YAML配置"
    echo "安装命令: sudo apt install yq 或 sudo yum install yq"
    exit 1
fi

# 防止重复加载配置函数
if [ -n "$SYNC_CONFIG_LOADED" ]; then
    return 0 2>/dev/null || true
fi
SYNC_CONFIG_LOADED=true

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误: 配置文件不存在: $CONFIG_FILE"
    exit 1
fi

# 当前配置变量
REMOTE_HOST=""
REMOTE_PORT=""
REMOTE_DIR=""
REMOTE_OS=""
REFRESH_INTERVAL=""
LOCAL_DIRS=()
EXCLUDE_PATTERNS=()

# 缓存变量
CONFIG_TIMESTAMP=""
CONFIG_CACHE_FILE="/tmp/sync_config_cache"
CONFIG_CHECK_INTERVAL=10  # 检查配置文件更新的间隔（秒）
LAST_CONFIG_CHECK=0  # 上次检查配置文件的时间戳

# 远程脚本配置
REMOTE_SCRIPT_NAME="remote-sync-helper.sh"
REMOTE_SCRIPT_PATH="/tmp/sync/$REMOTE_SCRIPT_NAME"
LOCAL_SCRIPT_PATH="./remote-sync-helper.sh"
REMOTE_SCRIPT_UPLOADED=false

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m'

# 全局变量
LOOP_COUNTER=0
ERROR_COUNTER=0
MAX_ERRORS=10
MAX_LOOPS=86400

# 锁机制配置
LOCK_FILE="/tmp/sync/sync-files.lock"
LOCK_TIMEOUT=100  # 5分钟锁超时

# 调试模式配置
DEBUG_MODE=false  # 默认不开启调试模式，可在配置文件中设置 debug_mode: true 开启

# 日志配置
BASE_LOG_DIR="/tmp/sync"  # 基础日志目录
LOG_DIR="$BASE_LOG_DIR/default"  # 默认日志目录
INFO_LOG="$LOG_DIR/sync-info.log"
ERROR_LOG="$LOG_DIR/sync-error.log"
DEBUG_LOG="$LOG_DIR/sync-debug.log"
LOG_MAX_DAYS=7  # 日志文件保留天数
LOG_MAX_SIZE=10  # 日志文件最大大小（MB）

# 日志函数
function ensure_log_dir() {
    # 如果LOG_DIR为空，设置为默认值
    if [ -z "$LOG_DIR" ]; then
        LOG_DIR="$BASE_LOG_DIR"
        INFO_LOG="$LOG_DIR/sync-info.log"
        ERROR_LOG="$LOG_DIR/sync-error.log"
        DEBUG_LOG="$LOG_DIR/sync-debug.log"
    fi

    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
        if [ $? -ne 0 ]; then
            echo "错误: 无法创建日志目录 $LOG_DIR"
            exit 1
        fi
    fi
    
    # 确保日志文件存在
    [ ! -f "$INFO_LOG" ] && touch "$INFO_LOG" 2>/dev/null
    [ ! -f "$ERROR_LOG" ] && touch "$ERROR_LOG" 2>/dev/null
    [ ! -f "$DEBUG_LOG" ] && touch "$DEBUG_LOG" 2>/dev/null
    
    return 0
}

function log_info() {
    local message="$1"
    local component="${2:-SYNC}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] [INFO] [$component] $message"
    
    # 输出到控制台
    echo "$log_entry"
    
    # 确保日志目录存在
    ensure_log_dir || return
    
    # 写入日志文件
    echo "$log_entry" >> "$INFO_LOG"
}

function log_debug() {
    if [ "$DEBUG_MODE" = "true" ]; then
        local message="$1"
        local component="${2:-SYNC_DEBUG}"
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local log_entry="[$timestamp] [DEBUG] [$component] $message"
        
        # 输出到控制台
        echo "$log_entry"
        
        # 确保日志目录存在
        ensure_log_dir || return
        
        # 写入日志文件
        echo "$log_entry" >> "$DEBUG_LOG"
    fi
}

function log_error() {
    local message="$1"
    local component="${2:-ERROR}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] [ERROR] [$component] $message"
    
    # 输出到控制台
    echo "$log_entry" >&2
    
    # 确保日志目录存在
    ensure_log_dir || return
    
    # 写入日志文件
    echo "$log_entry" >> "$ERROR_LOG"
    # 同时写入INFO日志，便于查看完整日志
    echo "$log_entry" >> "$INFO_LOG"
}

# 状态码定义
declare -A SYNC_STATUS=(
    ["SUCCESS"]="成功"
    ["ERROR"]="错误"
    ["WARNING"]="警告"
    ["SKIPPED"]="跳过"
    ["RETRY"]="重试"
    ["TIMEOUT"]="超时"
    ["NETWORK_ERROR"]="网络错误"
    ["AUTH_ERROR"]="认证错误"
    ["SPACE_ERROR"]="空间不足"
    ["PERMISSION_ERROR"]="权限错误"
)

# 性能优化配置
PERFORMANCE_MODE="${PERFORMANCE_MODE:-true}"  # 启用性能优化模式
SSH_CONTROL_PATH="/tmp/ssh-sync-control-%h-%p-%r"  # SSH连接复用
LAST_SYNC_TIME=0  # 上次同步时间
FILE_CHANGE_CACHE=""  # 文件变更缓存

# 锁管理函数
function acquire_lock() {
    local max_wait=30  # 最多等待30秒
    local wait_count=0

    while [ $wait_count -lt $max_wait ]; do
        # 尝试创建锁文件
        if (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; then
            # 成功获取锁
            return 0
        fi

        # 检查锁文件是否过期
        if [ -f "$LOCK_FILE" ]; then
            local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
            local lock_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null)
            local current_time=$(date +%s)

            # 检查锁是否超时或进程已不存在
            if [ -n "$lock_time" ] && [ $((current_time - lock_time)) -gt $LOCK_TIMEOUT ]; then
                echo "检测到过期锁，清理中..."
                rm -f "$LOCK_FILE" 2>/dev/null
                continue
            elif [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
                echo "检测到死锁（进程$lock_pid已不存在），清理中..."
                rm -f "$LOCK_FILE" 2>/dev/null
                continue
            fi
        fi

        echo "等待其他同步任务完成... ($((wait_count + 1))/$max_wait)"
        sleep 1
        ((wait_count++))
    done

    echo "错误: 无法获取同步锁，可能有其他同步任务正在运行"
    echo "如果确认没有其他任务，请手动删除锁文件: rm -f $LOCK_FILE"
    return 1
}

function release_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$LOCK_FILE" 2>/dev/null
        fi
    fi
}

function cleanup_with_lock() {
    log_info "接收到中断信号，正在停止同步..." "CLEANUP"
    echo "接收到中断信号，正在停止同步..."
    release_lock
    rm -f /tmp/sync_*.tar.* 2>/dev/null || true
    log_info "循环统计: $LOOP_COUNTER 次迭代, $ERROR_COUNTER 个错误" "CLEANUP"
    echo "循环统计: $LOOP_COUNTER 次迭代, $ERROR_COUNTER 个错误"
    exit 0
}

# 统一的排除参数生成函数
function get_exclude_args() {
    local format="${1:-rsync}"  # rsync|tar
    local exclude_args=""
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        exclude_args+="--exclude='$pattern' "
    done
    echo "$exclude_args"
}

# SSH连接复用配置
function setup_ssh_multiplexing() {
    if [ "$PERFORMANCE_MODE" = "true" ]; then
        # 创建SSH控制连接
        ssh -o ControlMaster=yes -o ControlPath="$SSH_CONTROL_PATH" \
            -o ControlPersist=60s -p "$REMOTE_PORT" "$REMOTE_HOST" exit 2>/dev/null &
    fi
}

# 优化的SSH执行函数
function ssh_exec_fast() {
    local host="$1"
    local port="$2"
    local command="$3"

    if [ "$PERFORMANCE_MODE" = "true" ]; then
        ssh -o ControlMaster=no -o ControlPath="$SSH_CONTROL_PATH" \
            -o ConnectTimeout=5 -o ServerAliveInterval=30 \
            -p "$port" "$host" "$command"
    else
        ssh_exec "$host" "$port" "$command"
    fi
}

# 统一的状态输出函数
function output_status() {
    local status_code="$1"
    local component="$2"
    local details="$3"
    local message="${SYNC_STATUS[$status_code]:-$status_code}"

    case "$status_code" in
        "SUCCESS")
            echo "[$component] $message${details:+: $details}"
            ;;
        "ERROR"|"TIMEOUT"|"NETWORK_ERROR"|"AUTH_ERROR"|"SPACE_ERROR"|"PERMISSION_ERROR")
            echo "[$component] $message${details:+: $details}" >&2
            ;;
        "WARNING"|"SKIPPED"|"RETRY")
            echo "[$component] $message${details:+: $details}"
            ;;
    esac
}

function load_config() {
    if ! check_config_update; then
           return 1
    fi
    log_info "检测到配置文件已更新，重新加载配置" "CONFIG"
    
    LOCAL_DIRS=()
    EXCLUDE_PATTERNS=()

    # 简化的YAML解析
    local in_directories=false
    local in_exclude=false
    local in_remote=false
    local in_logs=false
    echo "$CONFIG_FILE"
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        echo "$line"
        case "$line" in
            "remote:")
                in_remote=true; in_directories=false; in_exclude=false; in_logs=false ;;
            "directories:")
                in_directories=true; in_remote=false; in_exclude=false; in_logs=false;;
            "exclude_patterns:")
                in_exclude=true; in_remote=false; in_directories=false; in_logs=false;;
            "logs:")
                in_logs=true; in_remote=false; in_directories=false; in_exclude=false ;;
            "refresh_interval:"*)
                REFRESH_INTERVAL=$(echo "$line" | sed 's/.*:[[:space:]]*//;s/["'\'']*//g')
                in_remote=false; in_directories=false; in_exclude=false; in_logs=false ;;
            "config_check_interval:"*)
                CONFIG_CHECK_INTERVAL=$(echo "$line" | sed 's/.*:[[:space:]]*//;s/["'\'']*//g')
                in_remote=false; in_directories=false; in_exclude=false; in_logs=false ;;
            "debug_mode:"*)
                local debug_value=$(echo "$line" | sed 's/.*:[[:space:]]*//;s/["'\'']*//g')
                if [ "$debug_value" = "true" ]; then
                    DEBUG_MODE="true"
                else
                    DEBUG_MODE="false"
                fi
                in_remote=false; in_directories=false; in_exclude=false; in_logs=false ;;
            *":"*)
                in_remote=false; in_directories=false; in_exclude=false; in_logs=false ;;
        esac

        if [ "$in_remote" = true ] && [[ "$line" =~ ^[a-z]+:[[:space:]]*.+ ]]; then
            local key=$(echo "$line" | cut -d: -f1)
            local value=$(echo "$line" | sed 's/.*:[[:space:]]*//;s/["'\'']*//g')
            case "$key" in
                # 配置文件优先，直接覆盖环境变量（包括空值）
                "host") REMOTE_HOST="$value" ;;
                "port") REMOTE_PORT="$value" ;;
                "dir") REMOTE_DIR="$value" ;;
                "os") REMOTE_OS="$value" ;;
            esac
        elif [ "$in_remote" = true ] && [[ "$line" =~ ^[a-z]+:[[:space:]]*$ ]]; then
            # 处理空值的remote配置（如 "host:" 后面没有值）
            local key=$(echo "$line" | cut -d: -f1)
            case "$key" in
                "host") REMOTE_HOST="" ;;
                "port") REMOTE_PORT="" ;;
                "dir") REMOTE_DIR="" ;;
                "os") REMOTE_OS="" ;;
            esac
        elif [ "$in_directories" = true ] && [[ "$line" =~ ^-[[:space:]]+ ]]; then
            local dir_path=$(echo "$line" | sed 's/^-[[:space:]]*//;s/["'\'']*//g')
            # 即使是空值也添加到数组中，保持配置文件的完整性
            LOCAL_DIRS+=("$dir_path")
        elif [ "$in_exclude" = true ] && [[ "$line" =~ ^-[[:space:]]+ ]]; then
            local pattern=$(echo "$line" | sed 's/^-[[:space:]]*//;s/["'\'']*//g')
            # 即使是空值也添加到数组中，保持配置文件的完整性
            EXCLUDE_PATTERNS+=("$pattern")
        elif [ "$in_logs" = true ] && [[ "$line" =~ ^[a-z_]+:[[:space:]]*.+ ]]; then
            local key=$(echo "$line" | cut -d: -f1)
            local value=$(echo "$line" | sed 's/.*:[[:space:]]*//;s/["'\'']*//g')
            case "$key" in
                "dir") 
                    # 展开~为$HOME
                    if [[ "$value" == "~"* ]]; then
                        value="${value/#\~/$HOME}"
                    fi
                    LOG_DIR="$value" 
                    # 更新日志文件路径
                    INFO_LOG="${LOG_DIR}/sync-info.log"
                    ERROR_LOG="${LOG_DIR}/sync-error.log"
                    DEBUG_LOG="${LOG_DIR}/sync-debug.log"
                    ;;
                "max_days") LOG_MAX_DAYS="$value" ;;
                "max_size") LOG_MAX_SIZE="$value" ;;
            esac
        fi
    done < "$CONFIG_FILE"

    save_config_cache
}


function save_config_cache() {
    {
        echo "REMOTE_HOST=$REMOTE_HOST"
        echo "REMOTE_PORT=$REMOTE_PORT"
        echo "REMOTE_DIR=$REMOTE_DIR"
        echo "REMOTE_OS=$REMOTE_OS"
        echo "REFRESH_INTERVAL=$REFRESH_INTERVAL"
        echo "CONFIG_CHECK_INTERVAL=$CONFIG_CHECK_INTERVAL"
        echo "DEBUG_MODE=$DEBUG_MODE"
        echo "LOG_DIR=$LOG_DIR"
        echo "LOG_MAX_DAYS=$LOG_MAX_DAYS"
        echo "LOG_MAX_SIZE=$LOG_MAX_SIZE"
        for dir in "${LOCAL_DIRS[@]}"; do
            echo "LOCAL_DIR=$dir"
        done
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            echo "EXCLUDE_PATTERN=$pattern"
        done
    } > "$CONFIG_CACHE_FILE"
}

function load_cached_config() {
    [ ! -f "$CONFIG_CACHE_FILE" ] && return 1

    local cached_dirs=()
    local cached_patterns=()
    local cached_timestamp=""

    while IFS= read -r line; do
        case "$line" in
            REMOTE_HOST=*) REMOTE_HOST="${line#REMOTE_HOST=}" ;;
            REMOTE_PORT=*) REMOTE_PORT="${line#REMOTE_PORT=}" ;;
            REMOTE_DIR=*) REMOTE_DIR="${line#REMOTE_DIR=}" ;;
            REMOTE_OS=*) REMOTE_OS="${line#REMOTE_OS=}" ;;
            REFRESH_INTERVAL=*) REFRESH_INTERVAL="${line#REFRESH_INTERVAL=}" ;;
            CONFIG_CHECK_INTERVAL=*) CONFIG_CHECK_INTERVAL="${line#CONFIG_CHECK_INTERVAL=}" ;;
            DEBUG_MODE=*) DEBUG_MODE="${line#DEBUG_MODE=}" ;;
            LOG_DIR=*) 
                LOG_DIR="${line#LOG_DIR=}"
                # 更新日志文件路径
                INFO_LOG="${LOG_DIR}/sync-info.log"
                ERROR_LOG="${LOG_DIR}/sync-error.log"
                DEBUG_LOG="${LOG_DIR}/sync-debug.log"
                ;;
            LOG_MAX_DAYS=*) LOG_MAX_DAYS="${line#LOG_MAX_DAYS=}" ;;
            LOG_MAX_SIZE=*) LOG_MAX_SIZE="${line#LOG_MAX_SIZE=}" ;;
            LOCAL_DIR=*) cached_dirs+=("${line#LOCAL_DIR=}") ;;
            EXCLUDE_PATTERN=*) cached_patterns+=("${line#EXCLUDE_PATTERN=}") ;;
        esac
    done < "$CONFIG_CACHE_FILE"

    if [ -f "$CONFIG_FILE" ]; then
        local current_timestamp=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null)
        if [ "$cached_timestamp" = "$current_timestamp" ] && [ ${#cached_dirs[@]} -gt 0 ]; then
            LOCAL_DIRS=("${cached_dirs[@]}")
            EXCLUDE_PATTERNS=("${cached_patterns[@]}")
            return 0
        fi
    fi
    return 1
}

# 快速文件变更检测（缓存优化）
function detect_file_changes_fast() {
    local local_dir="$1"
    local current_time=$(date +%s)

    # 如果距离上次检测不到5秒，使用缓存
    if [ "$PERFORMANCE_MODE" = "true" ] && [ $((current_time - LAST_SYNC_TIME)) -lt 5 ] && [ -n "$FILE_CHANGE_CACHE" ]; then
        echo "$FILE_CHANGE_CACHE"
        return 0
    fi

    cd "$local_dir" 2>/dev/null || return 1

    # 一次性获取所有Git状态信息
    local git_status_output=$(git status --porcelain=v1 2>/dev/null)

    # 解析git status输出，比多次调用git diff更快
    local modified_files=""
    local staged_files=""
    local untracked_files=""
    local deleted_files=""

    while IFS= read -r line; do
        if [ -n "$line" ]; then
            local index_status="${line:0:1}"    # 暂存区状态
            local work_status="${line:1:1}"     # 工作区状态
            local file="${line:3}"              # 文件路径

            # 解析各种状态组合
            case "$index_status$work_status" in
                # 暂存区状态
                "A "|"M "|"T "|"R "|"C ")  # 新增、修改、类型变更、重命名、复制（已暂存）
                    staged_files+="$file"$'\n' ;;
                "D ")  # 删除（已暂存）
                    deleted_files+="$file"$'\n' ;;

                # 工作区状态
                " M"|" T")  # 修改、类型变更（未暂存）
                    modified_files+="$file"$'\n' ;;
                " D")  # 删除（未暂存）
                    deleted_files+="$file"$'\n' ;;

                # 混合状态（暂存区和工作区都有变更）
                "MM"|"MT"|"TM"|"TT"|"AM"|"AT"|"RM"|"RT"|"CM"|"CT")
                    staged_files+="$file"$'\n'
                    modified_files+="$file"$'\n' ;;
                "MD"|"TD"|"AD"|"RD"|"CD")  # 暂存区修改，工作区删除
                    staged_files+="$file"$'\n'
                    deleted_files+="$file"$'\n' ;;
                "DM"|"DT")  # 暂存区删除，工作区修改
                    deleted_files+="$file"$'\n'
                    modified_files+="$file"$'\n' ;;

                # 未跟踪文件
                "??")
                    untracked_files+="$file"$'\n' ;;

                # 忽略的文件
                "!!")
                    # 跳过忽略的文件
                    ;;
            esac
        fi
    done <<< "$git_status_output"

    # 快速检测未推送文件（仅在有必要时）
    local unpushed_files=""
    local current_branch=$(git branch --show-current 2>/dev/null)
    local remote_branch="origin/$current_branch"

    if [ -n "$current_branch" ] && git rev-parse --verify "$remote_branch" >/dev/null 2>&1; then
        # 检查本地是否领先远程
        if ! git merge-base --is-ancestor HEAD "$remote_branch" 2>/dev/null; then
            unpushed_files=$(git diff --name-only "$remote_branch..HEAD" 2>/dev/null || echo "")
        fi
    elif [ -n "$current_branch" ]; then
        # 远程分支不存在，快速获取已跟踪文件（限制数量提升性能）
        unpushed_files=$(git ls-files --cached 2>/dev/null | head -100)
    fi

    # 处理删除文件，添加DEL:前缀
    local deleted_files_with_prefix=""
    if [ -n "$deleted_files" ]; then
        deleted_files_with_prefix=$(echo "$deleted_files" | grep -v '^$' | sed 's/^/DEL:/')
    fi

    # 合并所有文件变更
    local all_files="$modified_files"$'\n'"$staged_files"$'\n'"$untracked_files"$'\n'"$unpushed_files"$'\n'"$deleted_files_with_prefix"
    local unique_files=$(echo "$all_files" | grep -v '^$' | sort -u)

    # 缓存结果
    FILE_CHANGE_CACHE="$unique_files"
    LAST_SYNC_TIME="$current_time"

    echo "$unique_files"
}

# 优化的远程仓库更新（跳过不必要的操作）
function update_remote_repository_fast() {
    local remote_target_dir="$1"
    local dir_name="$2"
    local files_to_keep="$3"
    local local_hash="$4"
    local local_branch="$5"

    log_info "更新远程仓库: $dir_name (目标哈希: ${local_hash:0:8}, 分支: $local_branch)" "GIT_SYNC"

    local exclude_patterns=$(printf '%s\n' "${EXCLUDE_PATTERNS[@]}" | tr '\n' '|' | sed 's/|$//')
    log_info "执行远程同步脚本: $remote_target_dir" "GIT_SYNC"
    local sync_result=$(ssh_exec_fast "$REMOTE_HOST" "$REMOTE_PORT" \
        "DEBUG_MODE=\"$DEBUG_MODE\" $REMOTE_SCRIPT_PATH sync_version \"$remote_target_dir\" \"$files_to_keep\" \"$local_hash\" \"$local_branch\" \"$exclude_patterns\"")

    local sync_status=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^(HASH_MATCH|REMOTE_NEWER|PULLING_TO_LOCAL_HASH|BRANCH_DIVERGED_RESETTING|BRANCH_MISMATCH_SWITCHING|SYNC_COMPLETED|NOT_GIT_REPO|NO_REMOTE_ORIGIN|RESET_FAILED|HASH_NOT_FOUND)$ ]]; then
            sync_status="$line"
            log_info "远程同步状态: $sync_status" "GIT_SYNC"
        elif [[ "$line" =~ ^ERROR: ]]; then
            output_status "ERROR" "$dir_name"
            log_error "远程同步错误: ${line#ERROR:}" "GIT_SYNC"
            echo "${line#ERROR:}"
            return 1
        fi
    done <<< "$sync_result"

    case "$sync_status" in
        "HASH_MATCH") 
            log_debug "远程仓库已是最新版本 (${local_hash:0:8})" "GIT_SYNC"
            return 0 ;;
        "REMOTE_NEWER"|"PULLING_TO_LOCAL_HASH"|"BRANCH_DIVERGED_RESETTING"|"BRANCH_MISMATCH_SWITCHING"|"SYNC_COMPLETED")
            log_info "远程仓库更新成功: $sync_status" "GIT_SYNC"
            output_status "SUCCESS" "$dir_name" ;;
        *)
            log_info "远程仓库状态: $sync_status" "GIT_SYNC"
            output_status "$sync_status" "$dir_name" ;;
    esac
}

# 安全函数：验证路径
function validate_path() {
    local path="$1"
    [[ "$path" =~ \.\./|^\.|[\;\|\&\$\`]|//|^/etc/|^/boot/|^/sys/|^/proc/|^/dev/ ]] && return 1
    return 0
}

# 安全函数：转义shell参数
function escape_shell_arg() {
    printf '%q' "$1"
}

function perform_initial_sync() {
    local local_dir="$1"
    local remote_target_dir="$2"
    local dir_name="$3"

    log_debug "执行初始同步: $dir_name -> $remote_target_dir" "INIT_SYNC"
    validate_path "$remote_target_dir" || {
        log_error "无效的远程路径: $remote_target_dir" "INIT_SYNC"
        return 1
    }

    local dir_size=$(du -sm "$local_dir" 2>/dev/null | cut -f1)
    local file_count=$(find "$local_dir" -type f | wc -l)
    log_debug "目录大小: ${dir_size}MB, 文件数量: $file_count" "INIT_SYNC"

    local compression_mode="standard"
    [ "$file_count" -gt 10000 ] || [ "$dir_size" -gt 500 ] && compression_mode="fast"
    log_debug "使用压缩模式: $compression_mode" "INIT_SYNC"

    perform_compressed_initial_sync "$local_dir" "$remote_target_dir" "$dir_name" "$compression_mode"
}

function perform_compressed_initial_sync() {
    local local_dir="$1"
    local remote_target_dir="$2"
    local dir_name="$3"
    local compression_mode="${4:-standard}"

    log_info "开始压缩传输: $dir_name (模式: $compression_mode)" "INIT_SYNC"
    local exclude_args=$(get_exclude_args "tar")
    local temp_archive=$(mktemp --suffix=.tar.lz4)
    local compression_level="-3"
    [ "$compression_mode" = "fast" ] && compression_level="-1"

    log_debug "创建压缩归档: $temp_archive" "INIT_SYNC"
    if ! tar -cf - $exclude_args -C "$local_dir" . | lz4 $compression_level > "$temp_archive" 2>/dev/null; then
        log_error "创建压缩归档失败" "INIT_SYNC"
        rm -f "$temp_archive"
        return 1
    fi

    local escaped_remote_dir=$(escape_shell_arg "$remote_target_dir")
    log_debug "创建远程目录: $remote_target_dir" "INIT_SYNC"
    if ! ssh_exec "$REMOTE_HOST" "$REMOTE_PORT" "mkdir -p $escaped_remote_dir"; then
        log_error "创建远程目录失败: $remote_target_dir" "INIT_SYNC"
        rm -f "$temp_archive"
        return 1
    fi

    local upload_success=false
    log_debug "上传归档到远程服务器" "INIT_SYNC"
    if command -v pv >/dev/null 2>&1; then
        pv "$temp_archive" | ssh_exec "$REMOTE_HOST" "$REMOTE_PORT" "cat > $remote_target_dir/project.tar.lz4" && upload_success=true
    else
        scp -P "$REMOTE_PORT" "$temp_archive" "$REMOTE_HOST:$remote_target_dir/project.tar.lz4" 2>/dev/null && upload_success=true
    fi

    if [ "$upload_success" = true ]; then
        log_debug "解压归档到远程目录" "INIT_SYNC"
        local extract_result=$(ssh_exec "$REMOTE_HOST" "$REMOTE_PORT" "cd $(escape_shell_arg "$remote_target_dir") && lz4 -dc project.tar.lz4 | tar -xf - && rm -f project.tar.lz4 && echo 'SUCCESS'")
        rm -f "$temp_archive"
        if [ "$extract_result" = "SUCCESS" ]; then
            log_info "初始同步完成: $dir_name -> $remote_target_dir" "INIT_SYNC"
            return 0
        else
            log_error "远程解压失败" "INIT_SYNC"
        fi
    else
        log_error "上传归档失败" "INIT_SYNC"
    fi

    rm -f "$temp_archive"
    return 1
}

# 统一的SSH执行函数
function ssh_exec() {
    local host="$1"
    local port="$2"
    local command="$3"
    local timeout="${4:-10}"

    ssh -o ConnectTimeout="$timeout" -o BatchMode=yes "$host" -p "$port" "$command" 2>/dev/null
}

function sync_files() {
    # 确保默认日志目录存在
    ensure_log_dir
    
    log_info "开始文件同步" "SYNC"
    
    # 确保基础日志目录存在
    if [ ! -d "$BASE_LOG_DIR" ]; then
        mkdir -p "$BASE_LOG_DIR" 2>/dev/null || {
            echo "无法创建基础日志目录: $BASE_LOG_DIR" >&2
            exit 1
        }
    fi

    # 检查是否有配置的目录需要同步
    if [ ${#LOCAL_DIRS[@]} -eq 0 ]; then
        log_info "没有配置同步目录，等待配置更新" "SYNC_WAIT"
        echo "没有配置同步目录，等待配置更新..."
        return 0
    fi

    local exclude_args=$(get_exclude_args)

    # 启用SSH连接复用
    setup_ssh_multiplexing
    
    log_info "开始文件同步流程，共 ${#LOCAL_DIRS[@]} 个目录需要同步" "SYNC_START"

    for local_dir in "${LOCAL_DIRS[@]}"; do
        local dir_name=$(basename "$local_dir")
        local remote_target_dir="$REMOTE_DIR/$dir_name"
        
        # 设置日志路径
        setup_log_paths "$local_dir"

        log_info "开始处理目录: $dir_name" "SYNC_DIR"

        [ ! -d "$local_dir" ] && { output_status "ERROR" "$dir_name"; log_error "目录不存在: $local_dir" "SYNC_DIR"; continue; }
        [ ! -d "$local_dir/.git" ] && { log_info "跳过非Git目录: $local_dir" "SYNC_DIR"; continue; }
        cd "$local_dir" 2>/dev/null || { output_status "ERROR" "$dir_name"; log_error "无法访问目录: $local_dir" "SYNC_DIR"; continue; }

        # 直接检查远程目录是否存在
        log_info "检查远程目录: $remote_target_dir" "SYNC_DIR"
        local remote_exists=$(ssh_exec_fast "$REMOTE_HOST" "$REMOTE_PORT" "[ -d \"$remote_target_dir/.git\" ] && echo 'exists' || echo 'not_exists'")

        if [ "$remote_exists" = "not_exists" ]; then
            log_info "远程目录不存在，执行初始同步: $remote_target_dir" "SYNC_DIR"
            if perform_initial_sync "$local_dir" "$remote_target_dir" "$dir_name" 2>/dev/null; then
                output_status "SUCCESS" "$dir_name"
                log_info "初始同步成功: $dir_name -> $remote_target_dir" "SYNC_DIR"
            else
                output_status "ERROR" "$dir_name"
                log_error "初始同步失败: $dir_name" "SYNC_DIR"
                echo "初始同步失败"
            fi
            continue
        fi

        local current_branch=$(git branch --show-current 2>/dev/null)
        [ -z "$current_branch" ] && current_branch="main"
        log_info "当前分支: $current_branch" "SYNC_DIR"

        # 使用优化的文件变更检测
        log_info "检测文件变更: $dir_name" "SYNC_DIR"
        local unique_files
        if [ "$PERFORMANCE_MODE" = "true" ]; then
            unique_files=$(detect_file_changes_fast "$local_dir")
        else
            # 原有的详细检测逻辑（用于调试或特殊情况）
            local deleted_files_working=$(git diff --name-only --diff-filter=D 2>/dev/null)
            local deleted_files_staged=$(git diff --cached --name-only --diff-filter=D 2>/dev/null)
            local deleted_files="$deleted_files_working"$'\n'"$deleted_files_staged"
            deleted_files=$(echo "$deleted_files" | grep -v '^$' | sort -u)

            local modified_files=$(git diff --name-only --diff-filter=AM 2>/dev/null)
            local staged_files=$(git diff --cached --name-only --diff-filter=AM 2>/dev/null)
            local untracked_files=$(git ls-files --others --exclude-standard 2>/dev/null)

            local unpushed_files=""
            local remote_branch="origin/$current_branch"
            if git rev-parse --verify "$remote_branch" >/dev/null 2>&1; then
                if ! git merge-base --is-ancestor HEAD "$remote_branch" 2>/dev/null; then
                    unpushed_files=$(git diff --name-only "$remote_branch..HEAD" 2>/dev/null || echo "")
                fi
            else
                unpushed_files=$(git ls-files 2>/dev/null || echo "")
            fi

            local deleted_files_with_prefix=""
            if [ -n "$deleted_files" ]; then
                deleted_files_with_prefix=$(echo "$deleted_files" | sed 's/^/DEL:/')
            fi

            local all_files="$modified_files"$'\n'"$staged_files"$'\n'"$untracked_files"$'\n'"$unpushed_files"$'\n'"$deleted_files_with_prefix"
            unique_files=$(echo "$all_files" | grep -v '^$' | sort -u)
        fi

        # 调试信息（仅在非性能模式下显示）
        if [ "$PERFORMANCE_MODE" != "true" ]; then
            debug_file_changes "$dir_name" "$modified_files" "$staged_files" "$untracked_files" "$unpushed_files" "$deleted_files" "$unique_files"
        fi

        local local_hash=$(git rev-parse HEAD 2>/dev/null)
        log_info "本地Git哈希: ${local_hash:0:8}" "SYNC_DIR"

        # 正确计算文件数量
        local file_count=0
        if [ -n "$unique_files" ]; then
            file_count=$(echo "$unique_files" | wc -l)
        fi
        
        log_info "检测到 $file_count 个文件需要同步" "SYNC_DIR"

        # 性能模式下减少输出
        if [ "$PERFORMANCE_MODE" = "true" ]; then
            [ "$file_count" -gt 0 ] && echo "[$dir_name] 同步 $file_count 个文件"
        else
            echo "[$dir_name] 需要同步 $file_count 个文件"
        fi

        log_info "更新远程仓库版本: $dir_name" "SYNC_DIR"
        update_remote_repository_fast "$remote_target_dir" "$dir_name" "$unique_files" "$local_hash" "$current_branch"

        if [ -n "$unique_files" ]; then
            log_info "开始同步文件: $dir_name ($file_count 个文件)" "SYNC_DIR"
            local remote_target="${REMOTE_HOST}:${remote_target_dir}/"
            local include_args=""

            while IFS= read -r file; do
                if [ -n "$file" ] && validate_path "$file"; then
                    # 跳过删除标记的文件，这些文件将由远程脚本处理
                    if [[ "$file" =~ ^DEL: ]]; then
                        continue
                    fi
                    include_args+="--include=$(escape_shell_arg "$file") "
                    local dir_path=$(dirname "$file")
                    local depth=0
                    while [ "$dir_path" != "." ] && [ "$dir_path" != "/" ] && [ $depth -lt 20 ]; do
                        validate_path "$dir_path" && include_args+="--include=$(escape_shell_arg "$dir_path")/ "
                        dir_path=$(dirname "$dir_path")
                        ((depth++))
                    done
                fi
            done <<< "$unique_files"

            include_args+="--exclude=* "

            # 优化的rsync参数
            local rsync_args=(
                "-avz" "--compress-level=1" "--whole-file" "--partial" "--inplace"
                $include_args $exclude_args
            )

            # 使用SSH连接复用
            if [ "$PERFORMANCE_MODE" = "true" ]; then
                rsync_args+=("-e" "ssh -p $REMOTE_PORT -o ControlMaster=no -o ControlPath=$SSH_CONTROL_PATH -o Compression=no -o ConnectTimeout=5")
            else
                rsync_args+=("-e" "ssh -p $REMOTE_PORT -o Compression=no -o ConnectTimeout=10")
            fi

            rsync_args+=("$local_dir/" "$remote_target")

            log_info "执行rsync同步: $dir_name -> $remote_target" "SYNC_DIR"
            if rsync "${rsync_args[@]}" >/dev/null 2>&1; then
                output_status "SUCCESS" "$dir_name"
                log_info "文件同步成功: $dir_name" "SYNC_DIR"
            else
                output_status "ERROR" "$dir_name"
                log_error "文件同步失败: $dir_name" "SYNC_DIR"
                echo "文件同步失败"
            fi
        fi
        
        log_info "完成目录处理: $dir_name" "SYNC_DIR"
    done
    
    log_info "同步流程完成，共处理 ${#LOCAL_DIRS[@]} 个目录" "SYNC_END"
}

function show_config() {
    if [ "$LOOP_COUNTER" -eq 0 ]; then
        echo "=== Git 同步服务 ==="
        local perf_status="关闭"
        [ "$PERFORMANCE_MODE" = "true" ] && perf_status="开启"
        echo "远程: $REMOTE_HOST:$REMOTE_DIR | 间隔: ${REFRESH_INTERVAL}s | 仓库: ${#LOCAL_DIRS[@]}个 | 性能优化: $perf_status"
        echo "日志: 仅记录在远程服务器"
        echo ""
    fi
}

function cleanup() {
    # 清理SSH连接复用
    if [ "$PERFORMANCE_MODE" = "true" ] && [ -S "$SSH_CONTROL_PATH" ]; then
        ssh -o ControlPath="$SSH_CONTROL_PATH" -O exit "$REMOTE_HOST" 2>/dev/null || true
    fi
    cleanup_with_lock
}

function check_system_resources() {
    local mem_usage=$(free | awk 'NR==2{printf "%.0f", $3*100/$2}' 2>/dev/null || echo "0")
    [ "$mem_usage" -gt 90 ] && return 1

    local disk_usage=$(df / | awk 'NR==2{print $5}' | sed 's/%//' 2>/dev/null || echo "0")
    [ "$disk_usage" -gt 95 ] && return 1

    return 0
}

function check_loop_safety() {
    ((LOOP_COUNTER++))

    [ $LOOP_COUNTER -gt $MAX_LOOPS ] && { echo "达到最大循环次数，安全退出"; return 1; }
    [ $ERROR_COUNTER -gt $MAX_ERRORS ] && { echo "错误次数过多，安全退出"; return 1; }

    if [ $((LOOP_COUNTER % 100)) -eq 0 ]; then
        check_system_resources || { ((ERROR_COUNTER++)); return 1; }
    fi

    return 0
}

# 调试函数：显示检测到的文件变更详情
function debug_file_changes() {
    local dir_name="$1"
    local modified_files="$2"
    local staged_files="$3"
    local untracked_files="$4"
    local unpushed_files="$5"
    local deleted_files="$6"
    local unique_files="$7"

    if [ -n "$DEBUG_MODE" ] && [ "$DEBUG_MODE" = "true" ]; then
        echo "[$dir_name] 文件变更检测详情:"

        # 正确计算非空文件的数量
        local modified_count=0
        [ -n "$modified_files" ] && modified_count=$(echo "$modified_files" | grep -v '^$' | wc -l)

        local staged_count=0
        [ -n "$staged_files" ] && staged_count=$(echo "$staged_files" | grep -v '^$' | wc -l)

        local untracked_count=0
        [ -n "$untracked_files" ] && untracked_count=$(echo "$untracked_files" | grep -v '^$' | wc -l)

        local unpushed_count=0
        [ -n "$unpushed_files" ] && unpushed_count=$(echo "$unpushed_files" | grep -v '^$' | wc -l)

        local deleted_count=0
        [ -n "$deleted_files" ] && deleted_count=$(echo "$deleted_files" | grep -v '^$' | wc -l)

        local unique_count=0
        [ -n "$unique_files" ] && unique_count=$(echo "$unique_files" | grep -v '^$' | wc -l)

        # 只显示非零的项目
        [ "$modified_count" -gt 0 ] && echo "  工作区修改: $modified_count 个文件"
        [ "$staged_count" -gt 0 ] && echo "  暂存区文件: $staged_count 个文件"
        [ "$untracked_count" -gt 0 ] && echo "  未跟踪文件: $untracked_count 个文件"
        [ "$unpushed_count" -gt 0 ] && echo "  未推送文件: $unpushed_count 个文件"
        [ "$deleted_count" -gt 0 ] && echo "  删除文件: $deleted_count 个文件"
        [ "$unique_count" -gt 0 ] && echo "  总计需同步: $unique_count 个文件"

        # 如果有文件变更，显示具体文件列表（最多显示10个）
        if [ "$unique_count" -gt 0 ] && [ "$unique_count" -le 10 ]; then
            echo "  文件列表:"
            echo "$unique_files" | grep -v '^$' | sed 's/^/    /'
        elif [ "$unique_count" -gt 10 ]; then
            echo "  文件列表（前10个）:"
            echo "$unique_files" | grep -v '^$' | head -10 | sed 's/^/    /'
            echo "    ... 还有 $((unique_count - 10)) 个文件"
        fi
        echo ""
    fi
}

# 单次同步执行（带锁）
function run_sync_once() {
    # 获取同步锁
    if ! acquire_lock; then
        log_error "无法获取同步锁，退出" "SYNC_LOCK"
        return 1
    fi

    # 设置信号处理，确保锁被正确释放
    trap cleanup_with_lock SIGINT SIGTERM EXIT

    log_info "开始单次同步" "SYNC_MAIN"
    echo "开始单次同步..."
    echo "同步锁已获取: $LOCK_FILE (PID: $$)"
    
    # 清理日志
    cleanup_logs

    load_config

    local sync_result=0
    if sync_files; then
        log_info "单次同步完成" "SYNC_MAIN"
        echo "单次同步完成"
    else
        log_error "单次同步失败" "SYNC_MAIN"
        echo "单次同步失败"
        sync_result=1
    fi

    # 释放锁
    log_info "释放同步锁" "SYNC_LOCK"
    release_lock
    return $sync_result
}

# 检查锁状态
function check_lock_status() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        local lock_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null)
        local current_time=$(date +%s)

        echo "同步锁状态: 已锁定"
        echo "锁文件: $LOCK_FILE"
        echo "锁进程PID: $lock_pid"

        if [ -n "$lock_time" ]; then
            local lock_age=$((current_time - lock_time))
            echo "锁创建时间: $(date -d "@$lock_time" 2>/dev/null || echo "未知")"
            echo "锁持续时间: ${lock_age}秒"

            if [ $lock_age -gt $LOCK_TIMEOUT ]; then
                echo "警告: 锁已超时（超过${LOCK_TIMEOUT}秒）"
            fi
        fi

        if [ -n "$lock_pid" ]; then
            if kill -0 "$lock_pid" 2>/dev/null; then
                echo "锁进程状态: 运行中"
            else
                echo "锁进程状态: 已停止（死锁）"
            fi
        fi
    else
        echo "同步锁状态: 未锁定"
        echo "锁文件: $LOCK_FILE (不存在)"
    fi
}

# 强制清理锁
function force_unlock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        echo "强制清理同步锁..."
        echo "锁文件: $LOCK_FILE"
        echo "锁进程PID: $lock_pid"
        rm -f "$LOCK_FILE"
        echo "锁已清理"
    else
        echo "没有发现锁文件，无需清理"
    fi
}

# 日志清理函数
function cleanup_logs() {
    # 确保日志目录存在
    [ ! -d "$LOG_DIR" ] && return 0
    
    local current_date=$(date +%s)
    local days_in_seconds=$((LOG_MAX_DAYS * 24 * 60 * 60))
    local max_size_bytes=$((LOG_MAX_SIZE * 1024 * 1024))
    
    # 基于日期清理过期日志
    log_debug "检查过期日志文件" "LOG_CLEANUP"
    find "$LOG_DIR" -name "*.log" -type f -mtime +$LOG_MAX_DAYS -delete 2>/dev/null
    find "$LOG_DIR" -name "*.log.old" -type f -mtime +$LOG_MAX_DAYS -delete 2>/dev/null
    
    # 检查并轮转大小超过限制的日志文件
    for log_file in "$INFO_LOG" "$ERROR_LOG" "$DEBUG_LOG"; do
        if [ -f "$log_file" ]; then
            local file_size=$(stat -c %s "$log_file" 2>/dev/null || echo "0")
            if [ "$file_size" -gt "$max_size_bytes" ]; then
                log_debug "轮转日志文件: $log_file (大小: $((file_size / 1024 / 1024))MB)" "LOG_CLEANUP"
                # 轮转日志文件
                local timestamp=$(date '+%Y%m%d-%H%M%S')
                mv "$log_file" "$log_file.$timestamp.old" 2>/dev/null
                touch "$log_file" 2>/dev/null
            fi
        fi
    done
    
    # 清理空目录
    find "$LOG_DIR" -type d -empty -delete 2>/dev/null || true
    
    return 0
}

# 查看日志函数
function view_logs() {
    local log_type="${1:-info}"
    
    # 确保配置已加载
    load_config
    
    # 确保日志目录存在
    if [ ! -d "$LOG_DIR" ]; then
        echo "日志目录不存在: $LOG_DIR"
        return 1
    fi
    
    local log_file=""
    case "$log_type" in
        "info")
            log_file="$INFO_LOG"
            echo "查看INFO日志: $log_file"
            ;;
        "error")
            log_file="$ERROR_LOG"
            echo "查看ERROR日志: $log_file"
            ;;
        "debug")
            log_file="$DEBUG_LOG"
            echo "查看DEBUG日志: $log_file"
            ;;
        *)
            echo "未知的日志类型: $log_type"
            echo "可用的日志类型: info, error, debug"
            return 1
            ;;
    esac
    
    if [ ! -f "$log_file" ]; then
        echo "日志文件不存在: $log_file"
        return 1
    fi
    
    # 使用less查看日志文件，如果less不可用，则使用cat
    if command -v less >/dev/null 2>&1; then
        less "$log_file"
    else
        cat "$log_file"
    fi
}

# 根据目标目录设置日志路径
function setup_log_paths() {
    local target_dir="$1"
    local dir_name=$(basename "$target_dir")

    LOG_DIR="$BASE_LOG_DIR/$dir_name"
    INFO_LOG="$LOG_DIR/sync-info.log"
    ERROR_LOG="$LOG_DIR/sync-error.log"
    DEBUG_LOG="$LOG_DIR/sync-debug.log"
    
    # 确保日志目录存在
    ensure_log_dir
}

# 检查配置文件是否已更新
function check_config_update() {
    local current_time=$(date +%s)
    # 如果距离上次检查不足CONFIG_CHECK_INTERVAL秒，则跳过检查
    if [ $((current_time - LAST_CONFIG_CHECK)) -lt $CONFIG_CHECK_INTERVAL ]; then
        return 1  # 无需检查
    fi
    
    LAST_CONFIG_CHECK=$current_time
    # 检查配置文件是否存在
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1  # 配置文件不存在，无需更新
    fi
    
    local current_timestamp=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null)
    # 检查时间戳是否变化
    if [ "$CONFIG_TIMESTAMP" != "$current_timestamp" ]; then
        log_info "配置文件已更新，时间戳: $CONFIG_TIMESTAMP -> $current_timestamp" "CONFIG"
        CONFIG_TIMESTAMP="$current_timestamp"
        return 0  # 需要更新
    fi
    return 1  # 无需更新
}

# 主执行逻辑
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        "once"|"run-once")
            # 单次同步模式
            run_sync_once
            exit $?
            ;;
        "fast")
            # 快速模式（强制启用性能优化）
            export PERFORMANCE_MODE="true"
            run_sync_once
            exit $?
            ;;
        "info")
            # INFO日志模式（使用INFO级别但不开启DEBUG）
            export DEBUG_MODE="false"
            run_sync_once
            exit $?
            ;;
        "slow"|"debug")
            # 调试模式（禁用性能优化）
            export PERFORMANCE_MODE="false"
            export DEBUG_MODE="true"
            run_sync_once
            exit $?
            ;;
        "lock-status"|"status")
            # 检查锁状态
            check_lock_status
            exit 0
            ;;
        "unlock"|"force-unlock")
            # 强制清理锁
            force_unlock
            exit 0
            ;;
        "logs")
            # 查看日志
            view_logs "${2:-info}"
            exit $?
            ;;
        "clean-logs")
            # 清理日志
            load_config
            cleanup_logs
            echo "日志清理完成"
            exit 0
            ;;
        "help"|"-h"|"--help")
            echo "Git 文件同步工具"
            echo ""
            echo "用法: $0 [命令]"
            echo ""
            echo "命令:"
            echo "  (无参数)    启动持续同步服务（默认模式）"
            echo "  once        执行单次同步"
            echo "  fast        执行单次快速同步（强制性能优化）"
            echo "  info        执行单次同步（使用INFO级别日志，不开启DEBUG）"
            echo "  slow        执行单次调试同步（详细输出）"
            echo "  status      检查同步锁状态"
            echo "  unlock      强制清理同步锁"
            echo "  logs [类型] 查看日志文件 (类型: info, error, debug)"
            echo "  clean-logs  手动清理日志文件"
            echo "  help        显示此帮助信息"
            echo ""
            echo "配置说明:"
            echo "  - 默认配置文件位置: $CONFIG_FILE"
            echo "  - directories配置项被注释或为空时，系统将等待配置更新"
            echo "  - 配置文件支持热更新，修改后会自动加载"
            echo ""
            echo "性能优化说明:"
            echo "  - 默认启用性能优化模式（SSH连接复用、文件变更缓存）"
            echo "  - 使用 'slow' 命令可禁用优化以便调试"
            echo "  - 环境变量 PERFORMANCE_MODE=false 可全局禁用优化"
            echo ""
            echo "调试模式说明:"
            echo "  - 默认不开启调试模式，只使用INFO级别日志"
            echo "  - 使用 'debug' 命令可开启调试模式"
            echo "  - 在配置文件中设置 debug_mode: true 可全局开启调试模式"
            echo ""
            echo "锁机制说明:"
            echo "  - 同步时会创建锁文件防止并发执行"
            echo "  - 锁文件位置: $LOCK_FILE"
            echo "  - 锁超时时间: ${LOCK_TIMEOUT}秒"
            echo "  - 如果检测到死锁会自动清理"
            exit 0
            ;;
        "")
            # 默认持续同步模式
            ;;
        *)
            echo "错误: 未知命令 '$1'"
            echo "使用 '$0 help' 查看可用命令"
            exit 1
            ;;
    esac
    
    # 持续同步模式
    # 获取同步锁
    if ! acquire_lock; then
        log_error "无法获取同步锁，退出" "SYNC_LOCK"
        exit 1
    fi
    
    # 设置信号处理，确保锁被正确释放
    trap cleanup_with_lock SIGINT SIGTERM EXIT

    if ! load_cached_config; then
        log_info "加载配置文件" "SYNC_MAIN"
        
    fi

    show_config
    
    log_info "启动持续同步服务，间隔: ${REFRESH_INTERVAL}秒" "SYNC_SERVICE"
    echo "Git 同步已启动（静默模式）。按 Ctrl+C 停止。"
    echo "详细日志记录在远程服务器。"
    echo "同步锁已获取: $LOCK_FILE (PID: $$)"
    echo ""
    
    # 初始清理日志
    cleanup_logs
    
    # 记录上次日志清理时间
    last_log_cleanup=$(date +%s)

    while true; do
        check_loop_safety || { log_error "安全检查失败，停止同步服务" "SYNC_SERVICE"; echo "安全检查失败，停止同步服务"; break; }
        
        # 每小时清理一次日志
        current_time=$(date +%s)
        if [ $((current_time - last_log_cleanup)) -gt 3600 ]; then
            log_info "执行定期日志清理" "LOG_CLEANUP"
            cleanup_logs
            last_log_cleanup=$current_time
        fi
        
        # 检查配置文件是否已更新
        load_config

        log_info "执行第 $LOOP_COUNTER 次同步" "SYNC_SERVICE"
        
        if sync_files 2>/dev/null; then
            ERROR_COUNTER=0
            # 如果没有配置同步目录，增加等待提示
            if [ ${#LOCAL_DIRS[@]} -eq 0 ]; then
                log_info "等待配置目录更新，${REFRESH_INTERVAL} 秒后检查" "SYNC_WAIT"
                echo "等待配置目录更新，${REFRESH_INTERVAL} 秒后检查..."
            else
                log_info "同步成功，等待 ${REFRESH_INTERVAL} 秒后继续" "SYNC_SERVICE"
            fi
        else
            ((ERROR_COUNTER++))
            log_error "同步失败 (错误计数: $ERROR_COUNTER)" "SYNC_SERVICE"
            [ $ERROR_COUNTER -gt 3 ] && echo "检测到多次同步失败 (次数: $ERROR_COUNTER)"
        fi
        
        sleep "$REFRESH_INTERVAL"
    done
    
    # 正常退出时释放锁
    log_info "服务停止，释放同步锁" "SYNC_LOCK"
    release_lock
fi 