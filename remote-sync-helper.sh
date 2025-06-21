#!/bin/bash

# 远程同步辅助脚本
# 此脚本将在远程服务器上执行，减少网络传输

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
GRAY='\033[0;37m'
NC='\033[0m'

# 安全函数：验证Git哈希格式
function validate_git_hash() {
    local hash="$1"
    if [[ ! "$hash" =~ ^[a-f0-9]{7,40}$ ]]; then
        return 1
    fi
    return 0
}

# 安全函数：创建数据备份
function create_safety_backup() {
    local backup_dir=".git/sync-backup-$(date +%s)"
    
    # 备份当前状态
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        mkdir -p "$backup_dir"
        git stash push -u -m "sync-backup-$(date)" 2>/dev/null || true
        echo "BACKUP_CREATED:$backup_dir"
    fi
}

# 功能：智能版本同步
function smart_version_sync() {
    local target_dir="$1"
    local files_to_keep="$2"
    local local_hash="$3"
    local local_branch="$4"
    local exclude_patterns="$5"
    
    cd "$target_dir" 2>/dev/null || {
        echo "ERROR:Cannot access directory $target_dir"
        exit 1
    }
    
    # 检查是否为git仓库
    if [ ! -d .git ]; then
        echo 'NOT_GIT_REPO'
        exit 0
    fi
    
    # 先尝试更新远程信息（静默执行）
    if git remote | grep -q origin; then
        git fetch origin 2>/dev/null || true
    fi
    
    # 获取远程当前状态
    local remote_hash=$(git rev-parse HEAD 2>/dev/null || echo '')
    local remote_branch=$(git branch --show-current 2>/dev/null || echo '')
    
    # 如果是detached HEAD状态，尝试获取更多信息
    if [ -z "$remote_branch" ] && [ -n "$remote_hash" ]; then
        if ! git symbolic-ref HEAD >/dev/null 2>&1; then
            remote_branch="(detached:${remote_hash:0:8})"
        fi
    fi
    
    # 输出当前状态用于调试
    echo "REMOTE_STATUS:$remote_branch:$remote_hash"
    
    # 如果哈希完全一致，跳过同步
    if [ "$remote_hash" = "$local_hash" ]; then
        echo 'HASH_MATCH'
        exit 0
    fi
    
    # 智能回滚不需要保留的文件
    smart_rollback "$files_to_keep" "$exclude_patterns"
    
    # 智能版本同步逻辑
    if [ "$remote_branch" = "$local_branch" ]; then
        # 分支一致，检查哈希关系
        if git merge-base --is-ancestor "$local_hash" "$remote_hash" 2>/dev/null; then
            # 本地哈希是远程的祖先，远程更新（不需要操作）
            echo 'REMOTE_NEWER'
        elif git merge-base --is-ancestor "$remote_hash" "$local_hash" 2>/dev/null; then
            # 远程哈希是本地的祖先，需要更新到本地哈希
            if git remote | grep -q origin; then
                echo 'PULLING_TO_LOCAL_HASH'
                # 先确保有最新的远程信息
                git fetch origin "$local_branch" 2>/dev/null || true
                git pull origin "$local_branch" 2>/dev/null || {
                    # Pull失败，强制重置到本地哈希
                    force_reset_to_hash "$local_hash"
                }
            else
                echo 'NO_REMOTE_ORIGIN'
            fi
        else
            # 分支分叉，强制重置到本地哈希
            echo 'BRANCH_DIVERGED_RESETTING'
            force_reset_to_hash "$local_hash"
        fi
    else
        # 分支不一致，切换到本地分支并重置
        echo 'BRANCH_MISMATCH_SWITCHING'
        # 确保有最新的远程分支信息
        if git remote | grep -q origin; then
            git fetch origin 2>/dev/null || true
        fi
        git checkout "$local_branch" 2>/dev/null || git checkout -b "$local_branch" 2>/dev/null || true
        force_reset_to_hash "$local_hash"
    fi
    
    echo 'SYNC_COMPLETED'
}

# 功能：强制重置到指定哈希，不保留任何本地修改（安全版本）
function force_reset_to_hash() {
    local target_hash="$1"
    
    # 验证哈希格式
    if ! validate_git_hash "$target_hash"; then
        echo 'INVALID_HASH_FORMAT'
        return 1
    fi
    
    # 检查目标哈希是否存在
    if ! git cat-file -e "$target_hash" 2>/dev/null; then
        echo 'HASH_NOT_FOUND'
        return 1
    fi
    
    # 创建安全备份
    create_safety_backup
    
    # 检查是否有重要的未提交更改
    local has_important_changes=false
    if git status --porcelain 2>/dev/null | grep -E '\.(sql|db|config|env)$' >/dev/null; then
        has_important_changes=true
    fi
    
    # 如果有重要更改，创建紧急提交
    if [ "$has_important_changes" = true ]; then
        git add . 2>/dev/null || true
        git commit -m "Emergency backup before sync reset - $(date)" 2>/dev/null || true
    fi
    
    # 强制清理所有本地状态（静默执行）
    git merge --abort 2>/dev/null || true
    git rebase --abort 2>/dev/null || true
    git cherry-pick --abort 2>/dev/null || true
    git am --abort 2>/dev/null || true
    git reset HEAD . 2>/dev/null || true
    git checkout --force . 2>/dev/null || true
    
    # 限制性清理：只清理非重要文件
    git clean -fd 2>/dev/null || true  # 移除-x选项，保留.gitignore文件
    
    # 强制重置到目标哈希
    if git reset --hard "$target_hash" 2>/dev/null; then
        echo 'RESET_SUCCESS'
        return 0
    else
        # 激进重置方法（作为最后手段）
        if [ -f .git/index ]; then
            cp .git/index .git/index.backup 2>/dev/null || true
            rm -f .git/index 2>/dev/null || true
        fi
        
        if git checkout --force "$target_hash" 2>/dev/null; then
            local current_branch=$(git branch --show-current 2>/dev/null || echo '')
            if [ -z "$current_branch" ]; then
                local branch_name=$(git symbolic-ref --short HEAD 2>/dev/null || echo 'main')
                git checkout -B "$branch_name" "$target_hash" 2>/dev/null || true
            fi
            echo 'RESET_SUCCESS_FALLBACK'
            return 0
        else
            # 恢复index备份
            if [ -f .git/index.backup ]; then
                mv .git/index.backup .git/index 2>/dev/null || true
            fi
            echo 'RESET_FAILED'
            return 1
        fi
    fi
}

# 功能：智能回滚
function smart_rollback() {
    local keep_files="$1"
    local exclude_patterns="$2"
    
    # 获取所有修改的文件
    local all_modified=$(git diff --name-only 2>/dev/null || echo '')
    local all_staged=$(git diff --cached --name-only 2>/dev/null || echo '')
    local all_untracked=$(git ls-files --others --exclude-standard 2>/dev/null || echo '')
    
    # 智能回滚：只回滚不需要保留的修改文件
    if [ -n "$all_modified" ]; then
        for file in $all_modified; do
            local should_keep=false
            
            # 检查是否在保留列表中
            if echo "$keep_files" | grep -q "^$file$"; then
                should_keep=true
            fi
            
            # 检查是否匹配排除模式
            if [ -n "$exclude_patterns" ] && echo "$file" | grep -E "$exclude_patterns" >/dev/null 2>&1; then
                should_keep=true
            fi
            
            # 如果不需要保留，则回滚该文件
            if [ "$should_keep" = false ]; then
                git checkout -- "$file" 2>/dev/null || true
            fi
        done
    fi
    
    # 智能清理：只清理不需要保留的未跟踪文件
    if [ -n "$all_untracked" ]; then
        for file in $all_untracked; do
            local should_keep=false
            
            # 检查是否在保留列表中
            if echo "$keep_files" | grep -q "^$file$"; then
                should_keep=true
            fi
            
            # 检查是否匹配排除模式
            if [ -n "$exclude_patterns" ] && echo "$file" | grep -E "$exclude_patterns" >/dev/null 2>&1; then
                should_keep=true
            fi
            
            # 如果不需要保留，则删除该文件
            if [ "$should_keep" = false ]; then
                rm -f "$file" 2>/dev/null || true
            fi
        done
    fi
}

# 功能：检查目录是否存在且为git仓库
function check_git_repo() {
    local target_dir="$1"
    
    if [ -d "$target_dir" ] && [ -d "$target_dir/.git" ]; then
        echo 'exists'
    else
        echo 'not_exists'
    fi
}

# 主函数：根据参数执行不同功能
case "$1" in
    "check_repo")
        check_git_repo "$2"
        ;;

    "sync_version")
        smart_version_sync "$2" "$3" "$4" "$5" "$6"
        ;;
    *)
        echo "Usage: $0 {check_repo|sync_version} [args...]"
        echo "  check_repo <target_dir>"
        echo "  sync_version <target_dir> <files_to_keep> <local_hash> <local_branch> <exclude_patterns>"
        exit 1
        ;;
esac 