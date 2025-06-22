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

# 日志配置 - 由install.sh预设
LOG_DIR="${SYNC_LOG_DIR:-/tmp/sync-logs}"
SYNC_LOG="$LOG_DIR/sync.log"
ERROR_LOG="$LOG_DIR/error.log"
OPERATIONS_LOG="$LOG_DIR/operations.log"

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

# 确保日志目录和文件存在
function ensure_log_dir() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null
    fi
    
    # 确保基础日志文件存在
    [ ! -f "$SYNC_LOG" ] && touch "$SYNC_LOG" 2>/dev/null
    [ ! -f "$ERROR_LOG" ] && touch "$ERROR_LOG" 2>/dev/null
    [ ! -f "$OPERATIONS_LOG" ] && touch "$OPERATIONS_LOG" 2>/dev/null
}

# 统一的日志记录函数
function write_log() {
    local level="$1"
    local message="$2"
    local category="${3:-GENERAL}"
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

# 记录Git状态
function log_git_status() {
    local target_dir="$1"
    local prefix="$2"
    
    if [ -d "$target_dir/.git" ]; then
        cd "$target_dir" 2>/dev/null || return 1
        
        local current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
        local current_hash=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        local status_summary=$(git status --porcelain 2>/dev/null | wc -l)
        local remote_url=$(git remote get-url origin 2>/dev/null || echo "no-remote")
        
        write_log "INFO" "$prefix 分支: $current_branch | 哈希: ${current_hash:0:8} | 修改文件: $status_summary | 远程: $remote_url" "GIT"
    fi
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

# 创建安全备份
function create_safety_backup() {
    local target_dir="$1"
    local backup_dir="$target_dir/.git/sync-backup-$(date +%s)"
    
    cd "$target_dir" 2>/dev/null || return 1
    
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        mkdir -p "$backup_dir"
        if git stash push -u -m "sync-backup-$(date)" 2>/dev/null; then
            write_log "INFO" "创建安全备份: $backup_dir" "BACKUP"
            echo "BACKUP_CREATED:$backup_dir"
        else
            write_log "WARN" "创建安全备份失败" "BACKUP"
        fi
    fi
}

# 智能版本同步
function sync_version() {
    local target_dir="$1"
    local files_to_keep="$2"
    local local_hash="$3"
    local local_branch="$4"
    local exclude_patterns="$5"
    
    log_operation "版本同步" "$target_dir" "开始同步到本地版本 ${local_hash:0:8}"
    
    cd "$target_dir" 2>/dev/null || {
        write_log "ERROR" "无法访问目录: $target_dir" "SYNC"
        echo 'ERROR: 无法访问目录'
        exit 1
    }
    
    [ ! -d ".git" ] && {
        write_log "ERROR" "不是Git仓库: $target_dir" "SYNC"
        echo 'NOT_GIT_REPO'
        exit 0
    }
    
    validate_git_hash "$local_hash" || {
        echo 'ERROR: 无效的Git哈希'
        exit 1
    }
    
    log_git_status "$target_dir" "同步前状态"
    
    local remote_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    local remote_hash=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    
    echo "REMOTE_STATUS:$remote_branch:$remote_hash"
    
    write_log "INFO" "开始同步。远程: ${remote_hash:0:8}, 本地: ${local_hash:0:8}" "SYNC"
    
    # 智能文件回滚
    smart_rollback "$files_to_keep" "$exclude_patterns"

    if [ "$remote_hash" = "$local_hash" ]; then
            write_log "INFO" "哈希相同，无需处理。远程: ${remote_hash:0:8}, 本地: ${local_hash:0:8}" "SYNC"
            echo 'HASH_MATCH'
            return 0
    fi
    
    # 版本同步逻辑
    if [ "$remote_branch" = "$local_branch" ]; then
        write_log "INFO" "分支匹配 ($local_branch)，检查哈希关系" "SYNC"
        
        if git merge-base --is-ancestor "$local_hash" "$remote_hash" 2>/dev/null; then
            write_log "INFO" "本地哈希是远程祖先，重置到本地版本" "SYNC"
            echo 'REMOTE_NEWER'
            force_reset_to_hash "$local_hash"
        elif git merge-base --is-ancestor "$remote_hash" "$local_hash" 2>/dev/null; then
            write_log "INFO" "远程哈希是本地祖先，拉取到本地版本" "SYNC"
            echo 'PULLING_TO_LOCAL_HASH'
            force_reset_to_hash "$local_hash"
        else
            write_log "INFO" "分支分歧，重置到本地版本" "SYNC"
            echo 'BRANCH_DIVERGED_RESETTING'
            force_reset_to_hash "$local_hash"
        fi
    else
        write_log "INFO" "分支不匹配，从 $remote_branch 切换到 $local_branch" "SYNC"
        echo 'BRANCH_MISMATCH_SWITCHING'
        force_reset_to_hash "$local_hash"
    fi
    
    log_git_status "$target_dir" "同步后状态"
    log_operation "版本同步" "$target_dir" "完成同步到 ${local_hash:0:8}" "SUCCESS"
}

# 强制重置到指定哈希
function force_reset_to_hash() {
    local target_hash="$1"
    
    write_log "INFO" "开始强制重置到 ${target_hash:0:8}" "RESET"
    
    # 清理Git状态
    git merge --abort 2>/dev/null || true
    git rebase --abort 2>/dev/null || true
    git cherry-pick --abort 2>/dev/null || true
    git reset HEAD . 2>/dev/null || true
    git checkout --force . 2>/dev/null || true
    git clean -fdx 2>/dev/null || true
    
    # 尝试标准重置
    if git reset --hard "$target_hash" 2>/dev/null; then
        write_log "INFO" "标准重置成功到 ${target_hash:0:8}" "RESET"
        return 0
    fi
    
    write_log "WARN" "标准重置失败，尝试激进重置" "RESET"
    
    # 激进重置
    rm -f .git/index 2>/dev/null || true
    if git checkout --force "$target_hash" 2>/dev/null; then
        local current_branch=$(git branch --show-current 2>/dev/null)
        if [ -z "$current_branch" ]; then
            git checkout -B main "$target_hash" 2>/dev/null || true
        fi
        write_log "INFO" "激进重置成功到 ${target_hash:0:8}" "RESET"
        return 0
    fi
    
    write_log "ERROR" "重置失败到 ${target_hash:0:8}" "RESET"
    echo 'RESET_FAILED'
    return 1
}

# 智能文件回滚
function smart_rollback() {
    local keep_files="$1"
    local exclude_patterns="$2"
    
    write_log "INFO" "开始智能文件回滚" "ROLLBACK"
    
    local all_files=$(git ls-files 2>/dev/null)
    local all_untracked=$(git ls-files --others --exclude-standard 2>/dev/null)
    local rollback_count=0
    local kept_count=0
    
    # 处理已跟踪文件
    if [ -n "$all_files" ]; then
        while IFS= read -r file; do
            local should_keep=false
            
            # 检查保留列表
            if echo "$keep_files" | grep -q "^$file$"; then
                should_keep=true
            fi
            
            # 检查排除模式
            if [ -n "$exclude_patterns" ] && echo "$file" | grep -E "$exclude_patterns" >/dev/null 2>&1; then
                should_keep=true
            fi
            
            if [ "$should_keep" = false ]; then
                if git checkout HEAD -- "$file" 2>/dev/null; then
                    ((rollback_count++))
                fi
            else
                ((kept_count++))
            fi
        done <<< "$all_files"
    fi
    
    # 处理未跟踪文件
    if [ -n "$all_untracked" ]; then
        while IFS= read -r file; do
            local should_keep=false
            
            if echo "$keep_files" | grep -q "^$file$"; then
                should_keep=true
            fi
            
            if [ -n "$exclude_patterns" ] && echo "$file" | grep -E "$exclude_patterns" >/dev/null 2>&1; then
                should_keep=true
            fi
            
            if [ "$should_keep" = false ]; then
                # 确保文件在Git工作区内且是相对路径
                if [[ "$file" != /* ]] && [ -f "$file" ] && [[ "$file" != ../* ]]; then
                    if rm -f "$file" 2>/dev/null; then
                        ((rollback_count++))
                    fi
                else
                    write_log "WARN" "跳过删除工作区外文件: $file" "ROLLBACK"
                fi
            else
                ((kept_count++))
            fi
        done <<< "$all_untracked"
    fi
    
    write_log "INFO" "智能回滚完成。回滚: $rollback_count 个文件，保留: $kept_count 个文件" "ROLLBACK"
}

# 检查Git仓库
function check_git_repo() {
    local target_dir="$1"
    
    write_log "INFO" "检查Git仓库: $target_dir" "CHECK"
    
    if [ -d "$target_dir" ] && [ -d "$target_dir/.git" ]; then
        write_log "INFO" "Git仓库存在: $target_dir" "CHECK"
        echo 'exists'
    else
        write_log "INFO" "Git仓库不存在: $target_dir" "CHECK"
        echo 'not_exists'
    fi
}

# 日志轮转
function rotate_logs() {
    ensure_log_dir
    
    for log_file in "$SYNC_LOG" "$ERROR_LOG" "$OPERATIONS_LOG"; do
        if [ -f "$log_file" ] && [ $(stat -c%s "$log_file" 2>/dev/null || echo 0) -gt 10485760 ]; then
            mv "$log_file" "${log_file}.old" 2>/dev/null
            touch "$log_file" 2>/dev/null
            write_log "INFO" "日志轮转: $(basename "$log_file")" "SYSTEM"
        fi
    done
}

# 查看日志
function show_logs() {
    local log_type="${1:-sync}"
    local lines="${2:-50}"
    
    ensure_log_dir
    
    case "$log_type" in
        "sync")
            [ -f "$SYNC_LOG" ] && tail -n "$lines" "$SYNC_LOG" || echo "同步日志不存在"
            ;;
        "error")
            [ -f "$ERROR_LOG" ] && tail -n "$lines" "$ERROR_LOG" || echo "错误日志不存在"
            ;;
        "operations")
            [ -f "$OPERATIONS_LOG" ] && tail -n "$lines" "$OPERATIONS_LOG" || echo "操作日志不存在"
            ;;
        "recent")
            echo "=== 最近的同步活动 ==="
            [ -f "$SYNC_LOG" ] && tail -n 20 "$SYNC_LOG" | grep -E "(OPERATION|ERROR)" || echo "无最近活动"
            ;;
        *)
            echo "用法: show_logs {sync|error|operations|recent} [行数]"
            ;;
    esac
}

# 主执行逻辑
case "${1:-}" in
    "sync_version")
        sync_version "$2" "$3" "$4" "$5" "$6"
        ;;
    "rotate_logs")
        rotate_logs
        ;;
    "show_logs")
        show_logs "$2" "$3"
        ;;
    *)
        echo "远程同步助手"
        echo "用法: $0 {sync_version|rotate_logs|show_logs}"
        exit 1
        ;;
esac 