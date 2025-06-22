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

# 配置文件路径
CONFIG_FILE="/mnt/d/sync.yaml"

# 默认配置
DEFAULT_REMOTE_HOST="34.68.158.244"
DEFAULT_REMOTE_PORT="22"
DEFAULT_REMOTE_DIR="/root/work"
DEFAULT_REMOTE_OS="ubuntu"
DEFAULT_REFRESH_INTERVAL=60
DEFAULT_LOCAL_DIRS=()
DEFAULT_EXCLUDE_PATTERNS=(
    '.git' '.gitignore' '.idea' '.vscode' '.log' '.vs'
    '__pycache__' 'build' 'target' 'node_modules'
)

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
LOCK_FILE="/tmp/sync-files.lock"
LOCK_TIMEOUT=100  # 5分钟锁超时

#debug 
DEBUG_MODE=false
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
    echo "接收到中断信号，正在停止同步..."
    release_lock
    rm -f /tmp/sync_*.tar.* 2>/dev/null || true
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

# 统一的SSH执行函数
function ssh_exec() {
    local host="$1"
    local port="$2"
    local command="$3"
    local timeout="${4:-10}"
    
    ssh -o ConnectTimeout="$timeout" -o BatchMode=yes "$host" -p "$port" "$command" 2>/dev/null
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
    if [ ! -f "$CONFIG_FILE" ]; then
        output_status "WARNING" "CONFIG" 
        echo "配置文件未找到，使用默认配置"
        load_default_config
        return
    fi
    
    local current_timestamp=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null)
    
    if [ -f "$CONFIG_CACHE_FILE" ] && [ "$CONFIG_TIMESTAMP" = "$current_timestamp" ] && [ ${#LOCAL_DIRS[@]} -gt 0 ]; then
        return  # 使用缓存
    fi
    
    load_default_config
    LOCAL_DIRS=()
    EXCLUDE_PATTERNS=()
    
    # 简化的YAML解析
    local in_directories=false
    local in_exclude=false
    local in_remote=false
    
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        case "$line" in
            "remote:")
                in_remote=true; in_directories=false; in_exclude=false ;;
            "directories:")
                in_directories=true; in_remote=false; in_exclude=false ;;
            "exclude_patterns:")
                in_exclude=true; in_remote=false; in_directories=false ;;
            "refresh_interval:"*)
                REFRESH_INTERVAL=$(echo "$line" | sed 's/.*:[[:space:]]*//;s/["'\'']*//g')
                in_remote=false; in_directories=false; in_exclude=false ;;
            *":"*)
                in_remote=false; in_directories=false; in_exclude=false ;;
        esac
        
        if [ "$in_remote" = true ] && [[ "$line" =~ ^[a-z]+:[[:space:]]*.+ ]]; then
            local key=$(echo "$line" | cut -d: -f1)
            local value=$(echo "$line" | sed 's/.*:[[:space:]]*//;s/["'\'']*//g')
            case "$key" in
                "host") REMOTE_HOST="$value" ;;
                "port") REMOTE_PORT="$value" ;;
                "dir") REMOTE_DIR="$value" ;;
                "os") REMOTE_OS="$value" ;;
            esac
        elif [ "$in_directories" = true ] && [[ "$line" =~ ^-[[:space:]]+ ]]; then
            local dir_path=$(echo "$line" | sed 's/^-[[:space:]]*//;s/["'\'']*//g')
            [ -n "$dir_path" ] && LOCAL_DIRS+=("$dir_path")
        elif [ "$in_exclude" = true ] && [[ "$line" =~ ^-[[:space:]]+ ]]; then
            local pattern=$(echo "$line" | sed 's/^-[[:space:]]*//;s/["'\'']*//g')
            [ -n "$pattern" ] && EXCLUDE_PATTERNS+=("$pattern")
        fi
    done < "$CONFIG_FILE"
    
    CONFIG_TIMESTAMP="$current_timestamp"
    save_config_cache
    validate_config
}

function load_default_config() {
    REMOTE_HOST="$DEFAULT_REMOTE_HOST"
    REMOTE_PORT="$DEFAULT_REMOTE_PORT"
    REMOTE_DIR="$DEFAULT_REMOTE_DIR"
    REMOTE_OS="$DEFAULT_REMOTE_OS"
    REFRESH_INTERVAL="$DEFAULT_REFRESH_INTERVAL"
    LOCAL_DIRS=("${DEFAULT_LOCAL_DIRS[@]}")
    EXCLUDE_PATTERNS=("${DEFAULT_EXCLUDE_PATTERNS[@]}")
}

function validate_config() {
    [ -z "$REMOTE_HOST" ] && REMOTE_HOST="$DEFAULT_REMOTE_HOST"
    [ -z "$REMOTE_PORT" ] && REMOTE_PORT="$DEFAULT_REMOTE_PORT"
    [ -z "$REMOTE_DIR" ] && REMOTE_DIR="$DEFAULT_REMOTE_DIR"
    [ -z "$REMOTE_OS" ] && REMOTE_OS="$DEFAULT_REMOTE_OS"
    [ -z "$REFRESH_INTERVAL" ] && REFRESH_INTERVAL="$DEFAULT_REFRESH_INTERVAL"
    
    if [ ${#LOCAL_DIRS[@]} -eq 0 ]; then
        LOCAL_DIRS=("${DEFAULT_LOCAL_DIRS[@]}")
    fi
    
    if [ ${#EXCLUDE_PATTERNS[@]} -eq 0 ]; then
        EXCLUDE_PATTERNS=("${DEFAULT_EXCLUDE_PATTERNS[@]}")
    fi
}

function save_config_cache() {
    {
        echo "CONFIG_TIMESTAMP=$CONFIG_TIMESTAMP"
        echo "REMOTE_HOST=$REMOTE_HOST"
        echo "REMOTE_PORT=$REMOTE_PORT"
        echo "REMOTE_DIR=$REMOTE_DIR"
        echo "REMOTE_OS=$REMOTE_OS"
        echo "REFRESH_INTERVAL=$REFRESH_INTERVAL"
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
            CONFIG_TIMESTAMP=*) cached_timestamp="${line#CONFIG_TIMESTAMP=}" ;;
            REMOTE_HOST=*) REMOTE_HOST="${line#REMOTE_HOST=}" ;;
            REMOTE_PORT=*) REMOTE_PORT="${line#REMOTE_PORT=}" ;;
            REMOTE_DIR=*) REMOTE_DIR="${line#REMOTE_DIR=}" ;;
            REMOTE_OS=*) REMOTE_OS="${line#REMOTE_OS=}" ;;
            REFRESH_INTERVAL=*) REFRESH_INTERVAL="${line#REFRESH_INTERVAL=}" ;;
            LOCAL_DIR=*) cached_dirs+=("${line#LOCAL_DIR=}") ;;
            EXCLUDE_PATTERN=*) cached_patterns+=("${line#EXCLUDE_PATTERN=}") ;;
        esac
    done < "$CONFIG_CACHE_FILE"
    
    if [ -f "$CONFIG_FILE" ]; then
        local current_timestamp=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null)
        if [ "$cached_timestamp" = "$current_timestamp" ] && [ ${#cached_dirs[@]} -gt 0 ]; then
            LOCAL_DIRS=("${cached_dirs[@]}")
            EXCLUDE_PATTERNS=("${cached_patterns[@]}")
            CONFIG_TIMESTAMP="$cached_timestamp"
            return 0
        fi
    fi
    return 1
}



function update_remote_repository() {
    local remote_target_dir="$1"
    local dir_name="$2"
    local files_to_keep="$3"
    local local_hash="$4"
    local local_branch="$5"
    
    local exclude_patterns=$(printf '%s\n' "${EXCLUDE_PATTERNS[@]}" | tr '\n' '|' | sed 's/|$//')
    local sync_result=$(ssh_exec "$REMOTE_HOST" "$REMOTE_PORT" \
        "$REMOTE_SCRIPT_PATH sync_version \"$remote_target_dir\" \"$files_to_keep\" \"$local_hash\" \"$local_branch\" \"$exclude_patterns\"")
    
    local sync_status=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^(HASH_MATCH|REMOTE_NEWER|PULLING_TO_LOCAL_HASH|BRANCH_DIVERGED_RESETTING|BRANCH_MISMATCH_SWITCHING|SYNC_COMPLETED|NOT_GIT_REPO|NO_REMOTE_ORIGIN|RESET_FAILED|HASH_NOT_FOUND)$ ]]; then
            sync_status="$line"
        elif [[ "$line" =~ ^ERROR: ]]; then
            output_status "ERROR" "$dir_name"
            echo "${line#ERROR:}"
            return 1
        fi
    done <<< "$sync_result"
    
    case "$sync_status" in
        "HASH_MATCH") return 0 ;;
        "REMOTE_NEWER"|"PULLING_TO_LOCAL_HASH"|"BRANCH_DIVERGED_RESETTING"|"BRANCH_MISMATCH_SWITCHING"|"SYNC_COMPLETED")
            output_status "SUCCESS" "$dir_name" ;;
        *)
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
    
    validate_path "$remote_target_dir" || return 1
    
    local dir_size=$(du -sm "$local_dir" 2>/dev/null | cut -f1)
    local file_count=$(find "$local_dir" -type f | wc -l)
    
    local compression_mode="standard"
    [ "$file_count" -gt 10000 ] || [ "$dir_size" -gt 500 ] && compression_mode="fast"
    
    perform_compressed_initial_sync "$local_dir" "$remote_target_dir" "$dir_name" "$compression_mode"
}

function perform_compressed_initial_sync() {
    local local_dir="$1"
    local remote_target_dir="$2"
    local dir_name="$3"
    local compression_mode="${4:-standard}"
    
    local exclude_args=$(get_exclude_args "tar")
    local temp_archive=$(mktemp --suffix=.tar.lz4)
    local compression_level="-3"
    [ "$compression_mode" = "fast" ] && compression_level="-1"
    
    if ! tar -cf - $exclude_args -C "$local_dir" . | lz4 $compression_level > "$temp_archive" 2>/dev/null; then
        rm -f "$temp_archive"
        return 1
    fi
    
    local escaped_remote_dir=$(escape_shell_arg "$remote_target_dir")
    if ! ssh_exec "$REMOTE_HOST" "$REMOTE_PORT" "mkdir -p $escaped_remote_dir"; then
        rm -f "$temp_archive"
        return 1
    fi
    
    local upload_success=false
    if command -v pv >/dev/null 2>&1; then
        pv "$temp_archive" | ssh_exec "$REMOTE_HOST" "$REMOTE_PORT" "cat > $remote_target_dir/project.tar.lz4" && upload_success=true
    else
        scp -P "$REMOTE_PORT" "$temp_archive" "$REMOTE_HOST:$remote_target_dir/project.tar.lz4" 2>/dev/null && upload_success=true
    fi
    
    if [ "$upload_success" = true ]; then
        local extract_result=$(ssh_exec "$REMOTE_HOST" "$REMOTE_PORT" "cd $(escape_shell_arg "$remote_target_dir") && lz4 -dc project.tar.lz4 | tar -xf - && rm -f project.tar.lz4 && echo 'SUCCESS'")
        rm -f "$temp_archive"
        [ "$extract_result" = "SUCCESS" ] && return 0
    fi
    
    rm -f "$temp_archive"
    return 1
}

function sync_files() {
    local exclude_args=$(get_exclude_args)
    
    for local_dir in "${LOCAL_DIRS[@]}"; do
        local dir_name=$(basename "$local_dir")
        local remote_target_dir="$REMOTE_DIR/$dir_name"
        
        [ ! -d "$local_dir" ] && { output_status "ERROR" "$dir_name"; echo "目录不存在"; continue; }
        [ ! -d "$local_dir/.git" ] && continue
        cd "$local_dir" 2>/dev/null || { output_status "ERROR" "$dir_name"; echo "无法访问目录"; continue; }
                
        local remote_exists=$(ssh_exec "$REMOTE_HOST" "$REMOTE_PORT" "$REMOTE_SCRIPT_PATH check_repo \"$remote_target_dir\"")
        
        if [ "$remote_exists" = "not_exists" ]; then
            if perform_initial_sync "$local_dir" "$remote_target_dir" "$dir_name" 2>/dev/null; then
                output_status "SUCCESS" "$dir_name"
            else
                output_status "ERROR" "$dir_name"
                echo "初始同步失败"
            fi
            continue
        fi
        
        local current_branch=$(git branch --show-current 2>/dev/null)
        [ -z "$current_branch" ] && current_branch="main"
        
        # 分别获取各种状态的文件，确保删除文件不会被重复归类
        local deleted_files_working=$(git diff --name-only --diff-filter=D 2>/dev/null)
        local deleted_files_staged=$(git diff --cached --name-only --diff-filter=D 2>/dev/null)
        local deleted_files="$deleted_files_working"$'\n'"$deleted_files_staged"
        deleted_files=$(echo "$deleted_files" | grep -v '^$' | sort -u)
        
        # 获取非删除的文件
        local modified_files=$(git diff --name-only --diff-filter=AM 2>/dev/null)
        local staged_files=$(git diff --cached --name-only --diff-filter=AM 2>/dev/null)
        local untracked_files=$(git ls-files --others --exclude-standard 2>/dev/null)
        
        local unpushed_files=""
        local remote_branch="origin/$current_branch"
        if git rev-parse --verify "$remote_branch" >/dev/null 2>&1; then
            # 检查是否有未推送的提交
            if ! git merge-base --is-ancestor HEAD "$remote_branch" 2>/dev/null; then
                # 本地有远程没有的提交，获取这些提交中的文件
                unpushed_files=$(git diff --name-only "$remote_branch..HEAD" 2>/dev/null || echo "")
            fi
        else
            # 远程分支不存在，获取当前分支的所有文件
            unpushed_files=$(git ls-files 2>/dev/null || echo "")
        fi
        
        # 处理删除文件，添加DEL:前缀
        local deleted_files_with_prefix=""
        if [ -n "$deleted_files" ]; then
            deleted_files_with_prefix=$(echo "$deleted_files" | sed 's/^/DEL:/')
        fi
        
        local all_files="$modified_files"$'\n'"$staged_files"$'\n'"$untracked_files"$'\n'"$unpushed_files"$'\n'"$deleted_files_with_prefix"
        local unique_files=$(echo "$all_files" | grep -v '^$' | sort -u)
        
        # 调试信息
        debug_file_changes "$dir_name" "$modified_files" "$staged_files" "$untracked_files" "$unpushed_files" "$deleted_files" "$unique_files"
        
        local local_hash=$(git rev-parse HEAD 2>/dev/null)
        
        # 正确计算文件数量
        local file_count=0
        if [ -n "$unique_files" ]; then
            file_count=$(echo "$unique_files" | wc -l)
        fi

        echo "[$dir_name] 需要同步 $file_count 个文件"
        
        # 如果没有文件变更，只更新远程仓库版本，跳过文件同步
        if [ -z "$unique_files" ]; then
            update_remote_repository "$remote_target_dir" "$dir_name" "$unique_files" "$local_hash" "$current_branch"
            continue
        fi
        
        # 有文件变更时，先更新远程仓库版本，再进行文件同步
        update_remote_repository "$remote_target_dir" "$dir_name" "$unique_files" "$local_hash" "$current_branch"
        
        if [ -n "$unique_files" ]; then
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
            
            local rsync_args=(
                "-avz" "--compress-level=1" "--whole-file" "--partial"
                $include_args $exclude_args
                "-e" "ssh -p $REMOTE_PORT -o Compression=no -o ConnectTimeout=10"
                "$local_dir/" "$remote_target"
            )
            
            if rsync "${rsync_args[@]}" >/dev/null 2>&1; then
                output_status "SUCCESS" "$dir_name"
            else
                output_status "ERROR" "$dir_name"
                echo "文件同步失败"
            fi
        fi
    done
}

function show_config() {
    if [ "$LOOP_COUNTER" -eq 0 ]; then
        echo "=== Git 同步服务 ==="
        echo "远程: $REMOTE_HOST:$REMOTE_DIR | 间隔: ${REFRESH_INTERVAL}s | 仓库: ${#LOCAL_DIRS[@]}个"
        echo "日志: 仅记录在远程服务器"
        echo ""
    fi
}

function cleanup() {
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
        [ -n "$modified_files" ] && echo "  工作区修改: $(echo "$modified_files" | wc -l) 个文件"
        [ -n "$staged_files" ] && echo "  暂存区文件: $(echo "$staged_files" | wc -l) 个文件"
        [ -n "$untracked_files" ] && echo "  未跟踪文件: $(echo "$untracked_files" | wc -l) 个文件"
        [ -n "$unpushed_files" ] && echo "  未推送文件: $(echo "$unpushed_files" | wc -l) 个文件"
        [ -n "$deleted_files" ] && echo "  删除文件: $(echo "$deleted_files" | wc -l) 个文件"
        [ -n "$unique_files" ] && echo "  总计需同步: $(echo "$unique_files" | wc -l) 个文件"
        echo ""
    fi
}

# 单次同步执行（带锁）
function run_sync_once() {
    # 获取同步锁
    if ! acquire_lock; then
        return 1
    fi
    
    # 设置信号处理，确保锁被正确释放
    trap cleanup_with_lock SIGINT SIGTERM EXIT
    
    echo "开始单次同步..."
    echo "同步锁已获取: $LOCK_FILE (PID: $$)"
    
    if ! load_cached_config; then
        load_config
    fi
    
    local sync_result=0
    if sync_files; then
        echo "单次同步完成"
    else
        echo "单次同步失败"
        sync_result=1
    fi
    
    # 释放锁
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

# 主执行逻辑
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        "once"|"run-once")
            # 单次同步模式
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
        "help"|"-h"|"--help")
            echo "Git 文件同步工具"
            echo ""
            echo "用法: $0 [命令]"
            echo ""
            echo "命令:"
            echo "  (无参数)    启动持续同步服务（默认模式）"
            echo "  once        执行单次同步"
            echo "  status      检查同步锁状态"
            echo "  unlock      强制清理同步锁"
            echo "  help        显示此帮助信息"
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
        exit 1
    fi
    
    # 设置信号处理，确保锁被正确释放
    trap cleanup_with_lock SIGINT SIGTERM EXIT

    if ! load_cached_config; then
        load_config
    fi

    show_config

    echo "Git 同步已启动（静默模式）。按 Ctrl+C 停止。"
    echo "详细日志记录在远程服务器。"
    echo "同步锁已获取: $LOCK_FILE (PID: $$)"
    echo ""

    while true; do
        check_loop_safety || { echo "安全检查失败，停止同步服务"; break; }
        
        load_config >/dev/null 2>&1 || ((ERROR_COUNTER++))
        
        if sync_files 2>/dev/null; then
            ERROR_COUNTER=0
        else
            ((ERROR_COUNTER++))
            [ $ERROR_COUNTER -gt 3 ] && echo "检测到多次同步失败 (次数: $ERROR_COUNTER)"
        fi
        
        sleep "$REFRESH_INTERVAL"
    done
    
    # 正常退出时释放锁
    release_lock
fi 