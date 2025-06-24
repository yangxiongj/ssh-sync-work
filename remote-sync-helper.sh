#!/bin/bash

# 远程同步辅助脚本
# 此脚本将在远程服务器上执行，减少网络传输并提供详细的服务器端日志记录

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m'

# 日志配置 - 统一使用 /tmp/sync/ 目录
BASE_LOG_DIR="/tmp/sync"
LOG_DIR="$BASE_LOG_DIR/default"  # 默认日志目录
SYNC_LOG="$LOG_DIR/sync.log"
ERROR_LOG="$LOG_DIR/error.log"
OPERATIONS_LOG="$LOG_DIR/operations.log"

# 调试模式配置
DEBUG_MODE="${DEBUG_MODE:-false}"  # 默认不开启调试模式

# 状态码定义
declare -A SYNC_STATUS=(
    ["SUCCESS"]="成功"
    ["ERROR"]="错误"
    ["HASH_MATCH"]="版本匹配"
    ["REMOTE_NEWER"]="远程较新"
    ["PULLING_TO_LOCAL_HASH"]="拉取到本地版本"
    ["BRANCH_DIVERGED_RESETTING"]="分支分歧重置"
    ["BRANCH_MISMATCH_SWITCHING"]="分支不匹配切换"
    ["NOT_GIT_REPO"]="非Git仓库"
    ["NO_REMOTE_ORIGIN"]="无远程源"
    ["RESET_FAILED"]="重置失败"
    ["HASH_NOT_FOUND"]="哈希未找到"
)


# Git状态全局缓存（单次同步周期内有效）
GIT_STATUS_OUTPUT=""
GIT_STATUS_FETCHED=false

# Git信息全局缓存（从git status中提取）
GIT_BRANCH_CACHE=""
GIT_HASH_CACHE=""
GIT_INFO_FETCHED=false

# 获取Git信息（分支、哈希、状态）并缓存
function fetch_git_info_once() {
    local target_dir="${1:-.}"

    # 如果已经获取过，直接返回
    if [ "$GIT_INFO_FETCHED" = true ]; then
        return 0
    fi

    cd "$target_dir" 2>/dev/null || return 1

    # 使用git status v2格式一次性获取所有信息
    local git_status_v2=$(git status --porcelain=v2 -b 2>/dev/null)

    # 提取分支信息
    GIT_BRANCH_CACHE=$(echo "$git_status_v2" | grep "^# branch.head " | cut -d' ' -f3)
    [ -z "$GIT_BRANCH_CACHE" ] && GIT_BRANCH_CACHE="unknown"

    # 提取哈希信息
    GIT_HASH_CACHE=$(echo "$git_status_v2" | grep "^# branch.oid " | cut -d' ' -f3)
    [ -z "$GIT_HASH_CACHE" ] && GIT_HASH_CACHE="unknown"

    # 直接保存原始的git status输出，不做格式转换
    # 这样在后续处理中可以根据实际格式进行解析
    GIT_STATUS_OUTPUT=$(echo "$git_status_v2" | grep -v "^#")

    GIT_STATUS_FETCHED=true
    GIT_INFO_FETCHED=true

    return 0
}

# 重置Git信息缓存
function reset_git_info_cache() {
    GIT_BRANCH_CACHE=""
    GIT_HASH_CACHE=""
    GIT_INFO_FETCHED=false
}

# 重置所有Git缓存
function reset_all_git_cache() {
    reset_git_status_cache
    reset_git_info_cache
}

# 获取缓存的Git分支
function get_git_branch_cached() {
    fetch_git_info_once "."
    echo "$GIT_BRANCH_CACHE"
}

# 获取缓存的Git哈希
function get_git_hash_cached() {
    fetch_git_info_once "."
    echo "$GIT_HASH_CACHE"
}

# 兼容函数：获取Git状态（实际调用统一的信息获取函数）
function fetch_git_status_once() {
    local target_dir="${1:-.}"
    fetch_git_info_once "$target_dir"
}

# 重置Git状态缓存
function reset_git_status_cache() {
    GIT_STATUS_OUTPUT=""
    GIT_STATUS_FETCHED=false
}

# 从全局缓存中提取修改文件
function get_modified_files_from_cache() {
    local modified_files=""

    while IFS= read -r line; do
        if [ -n "$line" ]; then
            # 检查行是否以 "1 .M" 开头，这是已修改文件的标识
            if [[ "$line" =~ ^1\ \.M ]]; then
                # 提取纯文件路径，去除状态码和哈希信息
                local pure_file=$(echo "$line" | awk '{print $NF}')
                modified_files+="$pure_file"$'\n'
            fi
        fi
    done <<< "$GIT_STATUS_OUTPUT"

    echo "$modified_files"
}

# 从全局缓存中提取未跟踪文件
function get_untracked_files_from_cache() {
    local untracked_files=""

    while IFS= read -r line; do
        if [ -n "$line" ]; then
            # 检查行是否以 "?" 开头，这是未跟踪文件的标识
            if [[ "$line" =~ ^\?\? ]]; then
                # 提取纯文件路径，去除状态码
                local pure_file=$(echo "$line" | cut -d' ' -f2-)
                untracked_files+="$pure_file"$'\n'
            fi
        fi
    done <<< "$GIT_STATUS_OUTPUT"

    echo "$untracked_files"
}

# 检查是否有工作区变更（兼容版本，优先使用缓存）
function has_working_changes() {
    local target_dir="${1:-.}"

    # 优先使用全局缓存
    if [ "$GIT_STATUS_FETCHED" = true ]; then
        [ -n "$GIT_STATUS_OUTPUT" ]
        return $?
    fi

    # 如果没有缓存，获取一次并缓存
    fetch_git_status_once "$target_dir"
    [ -n "$GIT_STATUS_OUTPUT" ]
}

# 根据目标目录设置日志路径
function setup_log_paths() {
    local target_dir="$1"
    local dir_name=$(basename "$target_dir")

    LOG_DIR="$BASE_LOG_DIR/$dir_name"
    SYNC_LOG="$LOG_DIR/sync.log"
    ERROR_LOG="$LOG_DIR/error.log"
    OPERATIONS_LOG="$LOG_DIR/operations.log"
}

# 确保日志目录和文件存在
function ensure_log_dir() {
    # 如果LOG_DIR为空，设置为默认值
    if [ -z "$LOG_DIR" ]; then
        LOG_DIR="$BASE_LOG_DIR/default"
        SYNC_LOG="$LOG_DIR/sync.log"
        ERROR_LOG="$LOG_DIR/error.log"
        OPERATIONS_LOG="$LOG_DIR/operations.log"
    fi

    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null
    fi

    # 确保基础日志文件存在
    [ ! -f "$SYNC_LOG" ] && touch "$SYNC_LOG" 2>/dev/null
    [ ! -f "$ERROR_LOG" ] && touch "$ERROR_LOG" 2>/dev/null
    [ ! -f "$OPERATIONS_LOG" ] && touch "$OPERATIONS_LOG" 2>/dev/null
}

# 清理过期日志文件
function cleanup_old_logs() {
    local log_dir="$1"
    local days_to_keep="${2:-7}"  # 默认保留7天的日志

    if [ -d "$log_dir" ]; then
        # 删除超过指定天数的日志文件
        find "$log_dir" -name "*.log" -type f -mtime +$days_to_keep -delete 2>/dev/null || true
        find "$log_dir" -name "*.log.old" -type f -mtime +$days_to_keep -delete 2>/dev/null || true

        # 如果目录为空，也删除目录
        rmdir "$log_dir" 2>/dev/null || true
    fi
}

# 统一的日志记录函数
function write_log() {
    local level="$1"
    local message="$2"
    local category="${3:-GENERAL}"
    
    # 如果是DEBUG类别的日志且DEBUG_MODE未开启，则不记录
    if [[ "$category" == *"DEBUG"* ]] && [ "$DEBUG_MODE" != "true" ]; then
        return 0
    fi
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] [$level] [$category] $message"

    ensure_log_dir

    case "$level" in
        "ERROR")
            echo "$log_entry" >> "$ERROR_LOG" 2>/dev/null
            echo "$log_entry" >> "$SYNC_LOG" 2>/dev/null
            ;;
        "OPERATION")
            echo "$log_entry" >> "$OPERATIONS_LOG" 2>/dev/null
            echo "$log_entry" >> "$SYNC_LOG" 2>/dev/null
            ;;
        *)
            echo "$log_entry" >> "$SYNC_LOG" 2>/dev/null
            ;;
    esac
}

# 记录操作
function log_operation() {
    local operation="$1"
    local target_dir="$2"
    local details="$3"
    local status="${4:-SUCCESS}"

    write_log "OPERATION" "操作: $operation | 目标: $target_dir | 详情: $details | 状态: $status" "OPERATION"
}

# 记录Git状态信息（用于调试）
function log_git_status() {
    local target_dir="$1"
    local context="${2:-状态检查}"

    # 使用缓存的Git信息（避免重复调用）
    local current_branch=$(get_git_branch_cached)
    local current_hash=$(get_git_hash_cached)

    # 检查工作区变更（使用缓存）
    local has_changes="否"
    if [ -n "$GIT_STATUS_OUTPUT" ]; then
        has_changes="是"
    fi

    write_log "INFO" "$context - 分支:$current_branch 哈希:${current_hash:0:8} 变更:$has_changes" "GIT_STATUS"
}

# 验证Git哈希格式
function validate_git_hash() {
    local hash="$1"
    [[ "$hash" =~ ^[a-f0-9]{7,40}$ ]] || {
        write_log "ERROR" "无效的Git哈希格式: $hash" "VALIDATION"
        return 1
    }
    return 0
}

# Git状态信息获取（使用全局缓存）
function get_git_status_cached() {
    local target_dir="$1"

    cd "$target_dir" 2>/dev/null || return 1

    # 直接使用全局缓存的Git信息
    local current_branch=$(get_git_branch_cached)
    local current_hash=$(get_git_hash_cached)
    local status_info="$current_branch:$current_hash"

    echo "$status_info"
}


# 错误时记录详细状态（仅异常情况）
function log_detailed_status_on_error() {
    local target_dir="$1"
    local error_context="$2"

    cd "$target_dir" 2>/dev/null || {
        write_log "ERROR" "无法访问目录进行状态记录: $target_dir" "ERROR"
        return 1
    }

    # 使用缓存的Git信息（避免重复调用）
    local current_branch=$(get_git_branch_cached)
    local current_hash=$(get_git_hash_cached)

    # 统计工作区变更（使用全局缓存）
    local status_count=0
    if [ "$GIT_STATUS_FETCHED" = true ]; then
        status_count=$(echo "$GIT_STATUS_OUTPUT" | grep -c . 2>/dev/null || echo "0")
    fi

    write_log "ERROR" "$error_context | 分支:$current_branch | 哈希:${current_hash:0:8} | 变更文件:$status_count" "ERROR_DETAIL"
}

# 智能版本同步（大幅优化）
function sync_version() {
    local target_dir="$1"
    local files_to_keep="$2"
    local local_hash="$3"
    local local_branch="$4"
    local exclude_patterns="$5"

    # 确保默认日志目录存在
    ensure_log_dir
    
    # 根据目标目录设置日志路径
    setup_log_paths "$target_dir"

    # 记录入参信息
    write_log "INFO" "开始同步 - 目标目录: $target_dir, 本地分支: $local_branch, 本地哈希: $local_hash, 排除模式: $exclude_patterns" "SYNC"
    if [ -n "$files_to_keep" ]; then
        write_log "INFO" "同步文件列表: $files_to_keep" "SYNC"
    fi

    # 异步清理过期日志（不阻塞主流程）
    cleanup_old_logs "$LOG_DIR" 7 &

    # 初始化Git状态
    cd "$target_dir" 2>/dev/null || {
        write_log "ERROR" "无法访问目录: $target_dir" "SYNC"
        echo 'ERROR: 无法访问目录'
        exit 1
    }

    # 检查是否为Git仓库
    [ ! -d ".git" ] && {
        write_log "ERROR" "不是Git仓库: $target_dir" "SYNC"
        echo 'NOT_GIT_REPO'
        exit 0
    }

    # 验证Git哈希
    validate_git_hash "$local_hash" || {
        write_log "ERROR" "无效的Git哈希: $local_hash" "SYNC"
        echo 'ERROR: 无效的Git哈希'
        exit 1
    }

    # 重置所有Git缓存，准备新的同步周期
    reset_all_git_cache

    # 一次性获取所有Git信息（状态、分支、哈希）
    fetch_git_info_once "$target_dir"

    # 获取远程哈希和分支
    local remote_hash=$(get_git_hash_cached)
    local git_status_info=$(get_git_status_cached "$target_dir")
    local remote_branch=$(echo "$git_status_info" | cut -d: -f1)

    # 记录远程状态
    write_log "INFO" "远程状态 - 分支: $remote_branch, 哈希: ${remote_hash:0:8}" "SYNC"
    echo "REMOTE_STATUS:$remote_branch:$remote_hash"

    # 提取同步文件列表（排除删除标记）
    local sync_files=""
    if [ -n "$files_to_keep" ]; then
        sync_files=$(echo "$files_to_keep" | grep -v "^DEL:" | grep -v "^$")
    fi

    # 处理哈希匹配情况
    if [ "$remote_hash" = "$local_hash" ]; then
        write_log "INFO" "哈希匹配: ${remote_hash:0:8}" "SYNC"
        
        # 检查工作区变更是否需要处理
        if  ! need_to_process_changes "$sync_files" "$exclude_patterns"; then
            write_log "INFO" "服务器工作区变更与客户端同步列表一致，跳过处理" "SYNC"
            echo "HASH_MATCH"
            log_operation "快速版本同步" "$target_dir" "哈希匹配，工作区变更与同步列表一致" "SUCCESS"
            return 0
        fi
        
        # 处理工作区文件
        write_log "INFO" "处理服务器工作区变更文件" "SYNC"
        process_working_changes "$files_to_keep" "$exclude_patterns"
        echo "HASH_MATCH"
        log_operation "快速版本同步" "$target_dir" "哈希匹配，处理服务器工作区文件" "SUCCESS"
        return 0
    fi

    # 哈希不匹配，需要完整同步
    write_log "INFO" "哈希不匹配: ${remote_hash:0:8} -> ${local_hash:0:8}" "SYNC"
    
    # 分支匹配检查
    if [ "$remote_branch" = "$local_branch" ]; then
        write_log "INFO" "分支匹配，重置到目标版本" "SYNC"
        simple_reset_to_hash "$target_dir"
    else
        write_log "INFO" "分支不匹配: $remote_branch -> $local_branch，切换分支" "SYNC"
        echo 'BRANCH_MISMATCH_SWITCHING'
        simple_reset_to_hash "$target_dir"
    fi
    
    # 处理文件删除
    handle_file_deletions "$files_to_keep"
    
    # 记录同步完成
    log_operation "版本同步" "$target_dir" "完成同步到 ${local_hash:0:8}" "SUCCESS"
}

# 检查是否需要处理工作区变更
function need_to_process_changes() {
    local sync_files="$1"
    local exclude_patterns="$2"
    
    # 记录参数到日志
    write_log "DEBUG" "检查是否需要处理工作区变更 - 同步文件列表: $sync_files" "SYNC_DEBUG"
    write_log "DEBUG" "检查是否需要处理工作区变更 - 排除模式: $exclude_patterns" "SYNC_DEBUG"
    write_log "DEBUG" "检查是否需要处理工作区变更 - GIT_STATUS_OUTPUT: $GIT_STATUS_OUTPUT" "SYNC_DEBUG"
    
    # 获取已修改和未跟踪文件
    local modified_files=$(get_modified_files_from_cache)
    local untracked_files=$(get_untracked_files_from_cache)
    
    write_log "DEBUG" "检查是否需要处理工作区变更 - 已修改文件: $modified_files" "SYNC_DEBUG"
    write_log "DEBUG" "检查是否需要处理工作区变更 - 未跟踪文件: $untracked_files" "SYNC_DEBUG"
    
    # 检查已修改文件
    if [ -n "$modified_files" ]; then
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                write_log "DEBUG" "检查已修改文件: $file" "SYNC_DEBUG"
                
                # 检查文件是否在同步列表中
                local in_sync_list=false
                if [ -n "$sync_files" ]; then
                    # 逐行检查同步文件列表
                    while IFS= read -r sync_file; do
                        if [ -n "$sync_file" ] && [ "$sync_file" = "$file" ]; then
                            in_sync_list=true
                            write_log "INFO" "已修改文件在同步列表中: $file = $sync_file" "SYNC_DEBUG"
                            break
                        fi
                    done <<< "$sync_files"
                fi
                
                # 检查排除模式
                local is_excluded=false
                if [ -n "$exclude_patterns" ] && echo "$file" | grep -E "$exclude_patterns" >/dev/null 2>&1; then
                    is_excluded=true
                    write_log "DEBUG" "已修改文件匹配排除模式: $file" "SYNC_DEBUG"
                fi
                
                # 如果文件不在同步列表中且不匹配排除模式，需要处理
                if [ "$in_sync_list" = false ] && [ "$is_excluded" = false ]; then
                    write_log "DEBUG" "需要处理的已修改文件: $file" "SYNC"
                    return 0  # 需要处理
                fi
            fi
        done <<< "$modified_files"
    fi
    
    # 检查未跟踪文件
    if [ -n "$untracked_files" ]; then
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                write_log "DEBUG" "检查未跟踪文件: $file" "SYNC_DEBUG"
                
                # 检查文件是否在同步文件列表中
                local in_sync_list=false
                if [ -n "$sync_files" ]; then
                    # 逐行检查同步文件列表
                    while IFS= read -r sync_file; do
                        if [ -n "$sync_file" ] && [ "$sync_file" = "$file" ]; then
                            in_sync_list=true
                            write_log "DEBUG" "未跟踪文件在同步列表中: $file = $sync_file" "SYNC_DEBUG"
                            break
                        fi
                    done <<< "$sync_files"
                fi
                
                # 检查排除模式
                local is_excluded=false
                if [ -n "$exclude_patterns" ] && echo "$file" | grep -E "$exclude_patterns" >/dev/null 2>&1; then
                    is_excluded=true
                    write_log "DEBUG" "未跟踪文件匹配排除模式: $file" "SYNC_DEBUG"
                fi
                
                # 如果文件不在同步列表中且不匹配排除模式，需要处理
                if [ "$in_sync_list" = false ] && [ "$is_excluded" = false ]; then
                    write_log "DEBUG" "需要处理的未跟踪文件: $file" "SYNC"
                    return 0  # 需要处理
                fi
            fi
        done <<< "$untracked_files"
    fi
    
    write_log "INFO" "无需处理工作区变更" "SYNC_DEBUG"
    return 1  # 不需要处理
}

# 处理工作区变更
function process_working_changes() {
    local files_to_keep="$1"
    local exclude_patterns="$2"
    
    smart_rollback_without_delete "$files_to_keep" "$exclude_patterns"

    handle_file_deletions "$files_to_keep"
}


# 重置到指定哈希（性能优化版本）
function simple_reset_to_hash() {
    local target_hash="$1"

    # 最简单的重置尝试，完全不保留工作区文件
    if git reset --hard "$target_hash" 2>/dev/null; then
        write_log "INFO" "重置成功到 ${target_hash:0:8}" "RESET"
        return 0
    elif git fetch 2>/dev/null; then
        if  git reset --hard "$target_hash" 2>/dev/null; then
            write_log "INFO" "重置成功到 ${target_hash:0:8}" "RESET"
            return 0
        fi
    fi

    # 失败则返回，让调用者决定是否进行复杂处理
    return 1
}

# 处理文件删除（在Git重置之后）
function handle_file_deletions() {
    local keep_files="$1"

    # 快速检查是否有删除文件
    if [ -z "$keep_files" ] || ! echo "$keep_files" | grep -q "^DEL:"; then
        return 0
    fi

    local deleted_count=0
    local deletion_list=""

    # 收集要删除的文件
    while IFS= read -r file_entry; do
        if [[ "$file_entry" =~ ^DEL: ]]; then
            local file_to_delete="${file_entry#DEL:}"
            if [[ "$file_to_delete" != /* ]] && [[ "$file_to_delete" != ../* ]] && [ -f "$file_to_delete" ]; then
                deletion_list+="$file_to_delete"$'\n'
                write_log "WARN" "跳过删除不安全路径: $file_to_delete" "DELETE"
            fi
        fi
    done <<< "$keep_files"

    # 批量删除文件
    if [ -n "$deletion_list" ]; then
        while IFS= read -r file_to_delete; do
            if [ -n "$file_to_delete" ] && rm -f "$file_to_delete" 2>/dev/null; then
                ((deleted_count++))
                write_log "INFO" "删除文件: $file_to_delete" "DELETE"
            else
                write_log "WARN" "删除文件失败: $file_to_delete" "DELETE"
            fi
        done <<< "$deletion_list"
    fi

     [ "$deleted_count" -gt 0 ] && write_log "INFO" "删除 $deleted_count 个文件" "DELETE"
}

# 智能文件回滚（基于同步文件列表）
function smart_rollback_without_delete() {
    local keep_files="$1"
    local exclude_patterns="$2"

    # 详细模式：使用全局缓存的git status数据
    write_log "INFO" "开始智能文件回滚（基于同步文件列表）" "ROLLBACK"

    # 提取非删除标记的同步文件列表
    local sync_files=""
    if [ -n "$keep_files" ]; then
        sync_files=$(echo "$keep_files" | grep -v "^DEL:" | grep -v "^$")
    fi

    # 从全局缓存中获取文件状态（避免重复调用git status）
    local modified_files=$(get_modified_files_from_cache)
    local untracked_files=$(get_untracked_files_from_cache)

    local rollback_count=0
    local kept_count=0
    local deleted_count=0

    # 处理已跟踪文件的变更：回滚那些不在同步文件列表中的文件
    if [ -n "$modified_files" ]; then
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                local should_rollback=true

                # 检查文件是否在同步文件列表中
                if [ -n "$sync_files" ] && echo "$sync_files" | grep -q "^$file$"; then
                    should_rollback=false
                fi

                # 检查排除模式
                if [ -n "$exclude_patterns" ] && echo "$file" | grep -E "$exclude_patterns" >/dev/null 2>&1; then
                    should_rollback=false
                fi

                if [ "$should_rollback" = true ]; then
                    if git checkout HEAD -- "$file" 2>/dev/null; then
                        write_log "INFO" "回滚文件到HEAD版本: $file" "ROLLBACK"
                        ((rollback_count++))
                    fi
                else
                    ((kept_count++))
                fi
            fi
        done <<< "$modified_files"
    fi

    # 处理未跟踪文件：删除那些不在同步文件列表中的文件
    if [ -n "$untracked_files" ]; then
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                local should_delete=true

                # 检查文件是否在同步文件列表中
                if [ -n "$sync_files" ] && echo "$sync_files" | grep -q "^$file$"; then
                    should_delete=false
                fi

                # 检查排除模式
                if [ -n "$exclude_patterns" ] && echo "$file" | grep -E "$exclude_patterns" >/dev/null 2>&1; then
                    should_delete=false
                fi

                if [ "$should_delete" = true ]; then
                    # 确保文件在Git工作区内且是相对路径
                    if [[ "$file" != /* ]] && [ -f "$file" ] && [[ "$file" != ../* ]]; then
                        if rm -f "$file" 2>/dev/null; then
                            write_log "INFO" "删除未同步的未跟踪文件: $file" "ROLLBACK"
                            ((deleted_count++))
                        fi
                    else
                        write_log "WARN" "跳过删除工作区外文件: $file" "ROLLBACK"
                    fi
                else
                    ((kept_count++))
                fi
            fi
        done <<< "$untracked_files"
    fi

    write_log "INFO" "智能回滚完成。回滚: $rollback_count 个文件，删除未跟踪: $deleted_count 个文件，保留: $kept_count 个文件" "ROLLBACK"
}

# 快速回滚（性能优化版本）
function smart_rollback_fast() {
    local keep_files="$1"
    local exclude_patterns="$2"

    # 使用全局缓存检查是否有工作区变更
    if [ -z "$GIT_STATUS_OUTPUT" ]; then
        write_log "INFO" "没有工作区变更，跳过回滚" "ROLLBACK_DEBUG"
        return 0
    fi

    write_log "INFO" "开始快速文件回滚" "ROLLBACK_DEBUG"

    # 提取同步文件列表
    local sync_files=""
    if [ -n "$keep_files" ]; then
        sync_files=$(echo "$keep_files" | grep -v "^DEL:" | grep -v "^$")
        write_log "INFO" "同步文件列表: $sync_files" "ROLLBACK_DEBUG"
    else
        write_log "INFO" "同步文件列表为空" "ROLLBACK_DEBUG"
    fi

    # 记录排除模式
    if [ -n "$exclude_patterns" ]; then
        write_log "INFO" "排除模式: $exclude_patterns" "ROLLBACK_DEBUG"
    fi

    local rollback_count=0
    local delete_count=0

    # 使用全局缓存的git status数据（限制处理数量）
    local line_count=0
    while IFS= read -r line && [ $line_count -lt 100 ]; do
        if [ -n "$line" ]; then
            local index_status="${line:0:1}"    # 暂存区状态
            local work_status="${line:1:1}"     # 工作区状态
            local file="${line:3}"              # 文件路径

            # 跳过空文件名
            [ -z "$file" ] && continue

            write_log "INFO" "处理文件: [$index_status$work_status] $file" "ROLLBACK_DEBUG"

            # 检查文件是否在同步列表中
            local in_sync_list=false
            if [ -n "$sync_files" ] && echo "$sync_files" | grep -q "^$file$"; then
                in_sync_list=true
                write_log "INFO" "文件在同步列表中: $file" "ROLLBACK_DEBUG"
            fi

            # 检查排除模式
            local is_excluded=false
            if [ -n "$exclude_patterns" ] && echo "$file" | grep -E "$exclude_patterns" >/dev/null 2>&1; then
                is_excluded=true
                write_log "INFO" "文件匹配排除模式: $file" "ROLLBACK_DEBUG"
            fi

            # 处理已跟踪文件（工作区有修改）
            if [ "$work_status" = "M" ] || [ "$work_status" = "T" ] || [ "$work_status" = "D" ]; then
                if [ "$in_sync_list" = false ] && [ "$is_excluded" = false ]; then
                    # 不在同步列表且不在排除模式中，回滚
                    write_log "INFO" "尝试回滚文件: $file" "ROLLBACK_DEBUG"
                    if git checkout HEAD -- "$file" 2>/dev/null; then
                        write_log "INFO" "成功回滚文件: $file" "ROLLBACK_DEBUG"
                        ((rollback_count++))
                    else
                        write_log "WARN" "回滚文件失败: $file" "ROLLBACK_DEBUG"
                    fi
                fi
            # 处理未跟踪文件
            elif [ "$index_status$work_status" = "??" ]; then
                if [ "$in_sync_list" = false ] && [ "$is_excluded" = false ]; then
                    # 不在同步列表且不在排除模式中，删除
                    # 确保文件在Git工作区内且是相对路径
                    write_log "INFO" "尝试删除未跟踪文件: $file" "ROLLBACK_DEBUG"
                    if [[ "$file" != /* ]] && [ -f "$file" ] && [[ "$file" != ../* ]]; then
                        if rm -f "$file" 2>/dev/null; then
                            write_log "INFO" "成功删除未跟踪文件: $file" "ROLLBACK_DEBUG"
                            ((delete_count++))
                        else
                            write_log "WARN" "删除未跟踪文件失败: $file" "ROLLBACK_DEBUG"
                        fi
                    else
                        write_log "WARN" "跳过删除工作区外文件: $file (存在: $([ -f "$file" ] && echo "是" || echo "否"))" "ROLLBACK_DEBUG"
                    fi
                fi
            fi
            ((line_count++))
        fi
    done <<< "$GIT_STATUS_OUTPUT"

    # 记录处理结果
    write_log "INFO" "快速回滚处理完成：回滚 $rollback_count 个文件，删除 $delete_count 个未跟踪文件" "ROLLBACK"
    
    # 调试：输出当前目录下的文件列表
    if [ -n "$GIT_STATUS_OUTPUT" ]; then
        write_log "INFO" "当前Git状态输出: $GIT_STATUS_OUTPUT" "ROLLBACK_DEBUG"
    fi
}

# 日志轮转
function rotate_logs() {
    local target_dir="${1:-}"

    if [ -n "$target_dir" ]; then
        # 轮转指定仓库的日志
        setup_log_paths "$target_dir"
        ensure_log_dir

        for log_file in "$SYNC_LOG" "$ERROR_LOG" "$OPERATIONS_LOG"; do
            if [ -f "$log_file" ] && [ $(stat -c%s "$log_file" 2>/dev/null || echo 0) -gt 10485760 ]; then
                mv "$log_file" "${log_file}.old" 2>/dev/null
                touch "$log_file" 2>/dev/null
                write_log "INFO" "日志轮转: $(basename "$log_file")" "SYSTEM"
            fi
        done
    else
        # 轮转所有仓库的日志
        if [ -d "$BASE_LOG_DIR" ]; then
            for repo_dir in "$BASE_LOG_DIR"/*; do
                if [ -d "$repo_dir" ]; then
                    local repo_name=$(basename "$repo_dir")
                    LOG_DIR="$repo_dir"
                    SYNC_LOG="$LOG_DIR/sync.log"
                    ERROR_LOG="$LOG_DIR/error.log"
                    OPERATIONS_LOG="$LOG_DIR/operations.log"

                    for log_file in "$SYNC_LOG" "$ERROR_LOG" "$OPERATIONS_LOG"; do
                        if [ -f "$log_file" ] && [ $(stat -c%s "$log_file" 2>/dev/null || echo 0) -gt 10485760 ]; then
                            mv "$log_file" "${log_file}.old" 2>/dev/null
                            touch "$log_file" 2>/dev/null
                            echo "日志轮转: $repo_name/$(basename "$log_file")"
                        fi
                    done
                fi
            done
        fi
    fi
}

# 清理所有仓库的过期日志
function cleanup_all_logs() {
    local days_to_keep="${1:-7}"

    if [ -d "$BASE_LOG_DIR" ]; then
        echo "开始清理 $BASE_LOG_DIR 中超过 $days_to_keep 天的日志文件..."

        for repo_dir in "$BASE_LOG_DIR"/*; do
            if [ -d "$repo_dir" ]; then
                local repo_name=$(basename "$repo_dir")
                echo "清理仓库: $repo_name"
                cleanup_old_logs "$repo_dir" "$days_to_keep"
            fi
        done

        # 清理空的基础目录
        rmdir "$BASE_LOG_DIR" 2>/dev/null || true
        echo "日志清理完成"
    else
        echo "日志目录不存在: $BASE_LOG_DIR"
    fi
}

# 查看日志
function show_logs() {
    local log_type="${1:-sync}"
    local repo_name="${2:-}"
    local lines="${3:-50}"

    if [ -n "$repo_name" ]; then
        # 查看指定仓库的日志
        LOG_DIR="$BASE_LOG_DIR/$repo_name"
        SYNC_LOG="$LOG_DIR/sync.log"
        ERROR_LOG="$LOG_DIR/error.log"
        OPERATIONS_LOG="$LOG_DIR/operations.log"

        case "$log_type" in
            "sync")
                [ -f "$SYNC_LOG" ] && tail -n "$lines" "$SYNC_LOG" || echo "[$repo_name] 同步日志不存在"
                ;;
            "error")
                [ -f "$ERROR_LOG" ] && tail -n "$lines" "$ERROR_LOG" || echo "[$repo_name] 错误日志不存在"
                ;;
            "operations")
                [ -f "$OPERATIONS_LOG" ] && tail -n "$lines" "$OPERATIONS_LOG" || echo "[$repo_name] 操作日志不存在"
                ;;
            "recent")
                echo "=== [$repo_name] 最近的同步活动 ==="
                [ -f "$SYNC_LOG" ] && tail -n 20 "$SYNC_LOG" | grep -E "(OPERATION|ERROR)" || echo "无最近活动"
                ;;
            *)
                echo "用法: show_logs {sync|error|operations|recent} [仓库名] [行数]"
                ;;
        esac
    else
        # 查看所有仓库的日志概览
        case "$log_type" in
            "list")
                echo "=== 所有仓库日志概览 ==="
                if [ -d "$BASE_LOG_DIR" ]; then
                    for repo_dir in "$BASE_LOG_DIR"/*; do
                        if [ -d "$repo_dir" ]; then
                            local repo_name=$(basename "$repo_dir")
                            echo "仓库: $repo_name"
                            ls -la "$repo_dir"/*.log 2>/dev/null || echo "  无日志文件"
                            echo ""
                        fi
                    done
                else
                    echo "日志目录不存在: $BASE_LOG_DIR"
                fi
                ;;
            "recent")
                echo "=== 所有仓库最近活动 ==="
                if [ -d "$BASE_LOG_DIR" ]; then
                    for repo_dir in "$BASE_LOG_DIR"/*; do
                        if [ -d "$repo_dir" ]; then
                            local repo_name=$(basename "$repo_dir")
                            local sync_log="$repo_dir/sync.log"
                            if [ -f "$sync_log" ]; then
                                echo "[$repo_name]:"
                                tail -n 5 "$sync_log" | grep -E "(OPERATION|ERROR)" || echo "  无最近活动"
                                echo ""
                            fi
                        fi
                    done
                else
                    echo "日志目录不存在: $BASE_LOG_DIR"
                fi
                ;;
            *)
                echo "用法: show_logs {list|recent} 或 show_logs {sync|error|operations|recent} [仓库名] [行数]"
                ;;
        esac
    fi
}

# 主执行逻辑
case "${1:-}" in
    "sync_version")
        sync_version "$2" "$3" "$4" "$5" "$6"
        ;;
    "rotate_logs")
        rotate_logs "$2"  # 可选的目标目录参数
        ;;
    "cleanup_logs")
        cleanup_all_logs "$2"  # 可选的保留天数参数
        ;;
    "show_logs")
        show_logs "$2" "$3" "$4"  # log_type repo_name lines
        ;;
    *)
        echo "远程同步助手 - 统一使用 /tmp/sync/ 目录"
        echo "用法: $0 {sync_version|rotate_logs|cleanup_logs|show_logs}"
        echo ""
        echo "命令说明:"
        echo "  sync_version <target_dir> <files> <hash> <branch> <exclude> - 同步版本"
        echo "  rotate_logs [target_dir]                                    - 轮转日志"
        echo "  cleanup_logs [days]                                         - 清理过期日志(默认7天)"
        echo "  show_logs list                                              - 列出所有仓库日志"
        echo "  show_logs recent                                            - 显示所有仓库最近活动"
        echo "  show_logs <type> <repo> [lines]                            - 显示指定仓库日志"
        echo "    类型: sync, error, operations, recent"
        exit 1
        ;;
esac 