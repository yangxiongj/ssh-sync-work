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
LOG_DIR=""  # 将根据目标目录动态设置
SYNC_LOG=""
ERROR_LOG=""
OPERATIONS_LOG=""

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
    
    # 根据目标目录设置日志路径
    setup_log_paths "$target_dir"
    
    # 清理过期日志（保留7天）
    cleanup_old_logs "$LOG_DIR" 7
    
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
    
    if [ "$remote_hash" = "$local_hash" ]; then
            # 即使哈希相同，也需要处理工作区文件同步
            smart_rollback_without_delete "$files_to_keep" "$exclude_patterns"
            handle_file_deletions "$files_to_keep"
            
            log_git_status "$target_dir" "同步后状态"
            log_operation "版本同步" "$target_dir" "哈希匹配，仅处理工作区文件 ${local_hash:0:8}" "SUCCESS"
            return 0
    fi
    
    # 先进行常规文件回滚（不包括删除操作）
    smart_rollback_without_delete "$files_to_keep" "$exclude_patterns"
    
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
    
    # 版本同步完成后，处理删除文件
    handle_file_deletions "$files_to_keep"
    
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

# 处理文件删除（在Git重置之后）
function handle_file_deletions() {
    local keep_files="$1"
    
    write_log "INFO" "开始处理文件删除" "DELETE"
    
    local deleted_count=0
    if [ -n "$keep_files" ]; then
        while IFS= read -r file_entry; do
            if [[ "$file_entry" =~ ^DEL: ]]; then
                local file_to_delete="${file_entry#DEL:}"
                if [[ "$file_to_delete" != /* ]] && [[ "$file_to_delete" != ../* ]] && [ -f "$file_to_delete" ]; then
                    if rm -f "$file_to_delete" 2>/dev/null; then
                        write_log "INFO" "删除文件: $file_to_delete" "DELETE"
                        ((deleted_count++))
                    else
                        write_log "WARN" "删除文件失败: $file_to_delete" "DELETE"
                    fi
                else
                    write_log "WARN" "跳过删除不安全路径: $file_to_delete" "DELETE"
                fi
            fi
        done <<< "$keep_files"
    fi
    
    write_log "INFO" "文件删除完成。删除: $deleted_count 个文件" "DELETE"
}

# 智能文件回滚（基于同步文件列表）
function smart_rollback_without_delete() {
    local keep_files="$1"
    local exclude_patterns="$2"
    
    write_log "INFO" "开始智能文件回滚（基于同步文件列表）" "ROLLBACK"
    
    # 提取非删除标记的同步文件列表
    local sync_files=""
    if [ -n "$keep_files" ]; then
        sync_files=$(echo "$keep_files" | grep -v "^DEL:" | grep -v "^$")
    fi
    
    local rollback_count=0
    local kept_count=0
    local deleted_count=0
    
    # 处理已跟踪文件的变更：回滚那些不在同步列表中的文件
    # 包括修改的文件和删除的文件（这些文件需要被恢复）
    local modified_files=$(git diff --name-only 2>/dev/null)
    if [ -n "$modified_files" ]; then
        while IFS= read -r file; do
            local should_keep=false
            
            # 检查文件是否在同步文件列表中
            if [ -n "$sync_files" ] && echo "$sync_files" | grep -q "^$file$"; then
                should_keep=true
            fi
            
            # 检查排除模式
            if [ -n "$exclude_patterns" ] && echo "$file" | grep -E "$exclude_patterns" >/dev/null 2>&1; then
                should_keep=true
            fi
            
            if [ "$should_keep" = false ]; then
                if git checkout HEAD -- "$file" 2>/dev/null; then
                    write_log "INFO" "回滚文件到HEAD版本: $file" "ROLLBACK"
                    ((rollback_count++))
                fi
            else
                ((kept_count++))
            fi
        done <<< "$modified_files"
    fi
    
    # 处理未跟踪文件：删除那些不在同步文件列表中的文件
    local all_untracked=$(git ls-files --others --exclude-standard 2>/dev/null)
    if [ -n "$all_untracked" ]; then
        while IFS= read -r file; do
            local should_keep=false
            
            # 检查文件是否在同步文件列表中
            if [ -n "$sync_files" ] && echo "$sync_files" | grep -q "^$file$"; then
                should_keep=true
            fi
            
            # 检查排除模式
            if [ -n "$exclude_patterns" ] && echo "$file" | grep -E "$exclude_patterns" >/dev/null 2>&1; then
                should_keep=true
            fi
            
            if [ "$should_keep" = false ]; then
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
        done <<< "$all_untracked"
    fi
    
    write_log "INFO" "智能回滚完成。回滚: $rollback_count 个文件，删除未跟踪: $deleted_count 个文件，保留: $kept_count 个文件" "ROLLBACK"
}

# 检查Git仓库
function check_git_repo() {
    local target_dir="$1"
    
    # 设置日志路径（即使仓库不存在也需要记录日志）
    setup_log_paths "$target_dir"

    if [ -d "$target_dir" ] && [ -d "$target_dir/.git" ]; then
        echo 'exists'
    else
        write_log "ERROR" "Git仓库不存在: $target_dir" "CHECK"
        echo 'not_exists'
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
    "check_repo")
        check_git_repo "$2"
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
        echo "用法: $0 {sync_version|check_repo|rotate_logs|cleanup_logs|show_logs}"
        echo ""
        echo "命令说明:"
        echo "  sync_version <target_dir> <files> <hash> <branch> <exclude> - 同步版本"
        echo "  check_repo <target_dir>                                     - 检查仓库"
        echo "  rotate_logs [target_dir]                                    - 轮转日志"
        echo "  cleanup_logs [days]                                         - 清理过期日志(默认7天)"
        echo "  show_logs list                                              - 列出所有仓库日志"
        echo "  show_logs recent                                            - 显示所有仓库最近活动"
        echo "  show_logs <type> <repo> [lines]                            - 显示指定仓库日志"
        echo "    类型: sync, error, operations, recent"
        exit 1
        ;;
esac 