#!/bin/bash

# 基础配置
REMOTE_HOST="34.68.158.244"
REMOTE_PORT="22"
LOCAL_DIRS=("/mnt/d/PycharmProjects/searxng" "/mnt/d/PycharmProjects/fast-crawler")
REMOTE_DIR="/root/work"
REFRESH_INTERVAL=60


# 排除目录配置 - 可以根据需要修改
EXCLUDE_PATTERNS=(
    '.git'
    '.gitignore'
    '.idea'
    '.vscode'
    '.log'
    '.vs'
    '__pycache__'
    'build'
    'target'
    'node_modules'
)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
DARK_GRAY='\033[1;30m'
NC='\033[0m' # No Color

function get_exclude_args() {
    local exclude_args=""
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        exclude_args+="--exclude='$pattern' "
    done
    echo "$exclude_args"
}

function get_tar_exclude_args() {
    local exclude_args=""
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        exclude_args+="--exclude='$pattern' "
    done
    echo "$exclude_args"
}


function update_remote_repository() {
    local remote_target_dir="$1"
    local dir_name="$2"
    local files_to_keep="$3"  # 要保留的文件列表

    # 在远程执行git操作：智能回滚和拉取最新版本
    ssh "$REMOTE_HOST" -p "$REMOTE_PORT" "
        cd $remote_target_dir 2>/dev/null || exit 1

        # 检查是否为git仓库
        if [ -d .git ]; then
            # 获取所有修改的文件
            all_modified=\$(git diff --name-only 2>/dev/null || echo '')
            all_staged=\$(git diff --cached --name-only 2>/dev/null || echo '')
            all_untracked=\$(git ls-files --others --exclude-standard 2>/dev/null || echo '')

            # 要保留的文件列表
            keep_files='$files_to_keep'

            # 排除模式列表
            exclude_patterns='$(printf '%s\n' "${EXCLUDE_PATTERNS[@]}" | tr '\n' '|' | sed 's/|$//')'

            # 智能回滚：只回滚不需要保留的修改文件
            if [ -n \"\$all_modified\" ]; then
                for file in \$all_modified; do
                    should_keep=false

                    # 检查是否在保留列表中
                    if echo \"\$keep_files\" | grep -q \"^\$file\$\"; then
                        should_keep=true
                    fi

                    # 检查是否匹配排除模式
                    if [ -n \"\$exclude_patterns\" ] && echo \"\$file\" | grep -E \"\$exclude_patterns\" >/dev/null 2>&1; then
                        should_keep=true
                    fi

                    # 如果不需要保留，则回滚该文件
                    if [ \"\$should_keep\" = false ]; then
                        git checkout -- \"\$file\" 2>/dev/null || true
                    fi
                done
            fi

            # 智能清理：只清理不需要保留的未跟踪文件
            if [ -n \"\$all_untracked\" ]; then
                for file in \$all_untracked; do
                    should_keep=false

                    # 检查是否在保留列表中
                    if echo \"\$keep_files\" | grep -q \"^\$file\$\"; then
                        should_keep=true
                    fi

                    # 检查是否匹配排除模式
                    if [ -n \"\$exclude_patterns\" ] && echo \"\$file\" | grep -E \"\$exclude_patterns\" >/dev/null 2>&1; then
                        should_keep=true
                    fi

                    # 如果不需要保留，则删除该文件
                    if [ \"\$should_keep\" = false ]; then
                        rm -f \"\$file\" 2>/dev/null || true
                    fi
                done
            fi

            # 尝试拉取最新版本
            if git remote | grep -q origin; then
                git pull origin \$(git branch --show-current 2>/dev/null || echo main) 2>/dev/null || {
                    echo 'Pull failed, repository may need manual intervention'
                }
            fi
        fi
    " 2>/dev/null
}

function perform_initial_sync() {
    local local_dir="$1"
    local remote_target_dir="$2"
    local dir_name="$3"

    echo -e "${YELLOW}[$dir_name] Initial sync: compressing project...${NC}"

    # 创建临时压缩文件
    local temp_archive=$(mktemp --suffix=.tar.gz)
    local exclude_args_tar=$(get_tar_exclude_args)
    local dir_size=$(du -sh "$local_dir" 2>/dev/null | cut -f1)

    # 压缩当前目录
    eval "tar -czf '$temp_archive' $exclude_args_tar --exclude='.git' -C '$local_dir' ." 2>/dev/null

    if [ $? -eq 0 ]; then
        local archive_size=$(du -h "$temp_archive" | cut -f1)
        echo -e "${YELLOW}[$dir_name] Transferring ($dir_size → $archive_size)...${NC}"

        # 传输并设置远程
        ssh "$REMOTE_HOST" -p "$REMOTE_PORT" "mkdir -p $remote_target_dir" 2>/dev/null
        scp -P "$REMOTE_PORT" "$temp_archive" "$REMOTE_HOST:$remote_target_dir/project.tar.gz" 2>/dev/null

        if [ $? -eq 0 ]; then
            ssh "$REMOTE_HOST" -p "$REMOTE_PORT" "
                cd $remote_target_dir
                tar -xzf project.tar.gz && rm -f project.tar.gz
                git init >/dev/null 2>&1
                git config core.autocrlf input >/dev/null 2>&1
                git config core.safecrlf warn >/dev/null 2>&1
                git add . >/dev/null 2>&1 && git commit -m 'Initial commit from sync service' >/dev/null 2>&1
            " 2>/dev/null

            rm -f "$temp_archive"
            echo -e "${GREEN}[$dir_name] Initial sync completed${NC}"
            return 0
        else
            echo -e "${RED}[$dir_name] Transfer failed${NC}"
            rm -f "$temp_archive"
            return 1
        fi
    else
        echo -e "${RED}[$dir_name] Compression failed${NC}"
        rm -f "$temp_archive"
        return 1
    fi
}

function sync_files() {
    echo -e "${GREEN}Starting incremental git sync...${NC}"

    local exclude_args=$(get_exclude_args)

    for local_dir in "${LOCAL_DIRS[@]}"; do
        local dir_name=$(basename "$local_dir")
        local remote_target_dir="$REMOTE_DIR/$dir_name"

        echo -e "${CYAN}Processing directory: $local_dir -> $remote_target_dir${NC}"

        # 检查本地目录是否存在
        if [ ! -d "$local_dir" ]; then
            echo -e "${RED}Local directory not found: $local_dir${NC}"
            continue
        fi

        # 检查本地是否为git仓库
        if [ ! -d "$local_dir/.git" ]; then
            echo -e "${YELLOW}[$dir_name] Not a git repository, skipping...${NC}"
            continue
        fi

        cd "$local_dir"

        # 首先检查远程目录是否存在项目
        local remote_exists=$(ssh "$REMOTE_HOST" -p "$REMOTE_PORT" "
            if [ -d $remote_target_dir ] && [ -d $remote_target_dir/.git ]; then
                echo 'exists'
            else
                echo 'not_exists'
            fi
        " 2>/dev/null)

        if [ "$remote_exists" = "not_exists" ]; then
            # 执行初始完整同步
            if perform_initial_sync "$local_dir" "$remote_target_dir" "$dir_name"; then
                echo -e "${DARK_GRAY}----------------------------------------${NC}"
                continue
            else
                echo -e "${DARK_GRAY}----------------------------------------${NC}"
                continue
            fi
        fi

        # 远程项目存在，检查是否有需要同步的变更
        # 获取当前分支名
        local current_branch=$(git branch --show-current 2>/dev/null)
        if [ -z "$current_branch" ]; then
            echo -e "${RED}[$dir_name] Unable to determine current branch${NC}"
            continue
        fi

        # 检查远程分支是否存在
        local remote_branch="origin/$current_branch"
        if ! git rev-parse --verify "$remote_branch" >/dev/null 2>&1; then
            # 如果远程分支不存在，检查是否有未提交的更改
            if git diff --quiet && git diff --cached --quiet; then
                # 即使没有本地更改，也要确保远程保持最新
                echo -e "${YELLOW}[$dir_name] No local changes, updating remote...${NC}"
                update_remote_repository "$remote_target_dir" "$dir_name" ""
                echo -e "${GREEN}[$dir_name] Remote updated${NC}"
                echo -e "${DARK_GRAY}----------------------------------------${NC}"
                continue
            fi
        else
            # 检查是否有未推送到远程主分支的提交
            local unpushed_commits=$(git rev-list --count "$remote_branch..HEAD" 2>/dev/null || echo "0")
            local uncommitted_changes=false

            # 同时检查是否有未提交的更改
            if ! git diff --quiet || ! git diff --cached --quiet; then
                uncommitted_changes=true
            fi

            if [ "$unpushed_commits" -eq 0 ] && [ "$uncommitted_changes" = false ]; then
                # 即使没有本地更改，也要确保远程保持最新
                echo -e "${YELLOW}[$dir_name] No local changes, updating remote...${NC}"
                update_remote_repository "$remote_target_dir" "$dir_name" ""
                echo -e "${GREEN}[$dir_name] Remote updated${NC}"
                echo -e "${DARK_GRAY}----------------------------------------${NC}"
                continue
            fi
        fi

        # 获取需要同步的文件列表
        local modified_files=$(git diff --name-only)
        local staged_files=$(git diff --cached --name-only)
        local untracked_files=$(git ls-files --others --exclude-standard)

        # 获取未推送提交中的文件
        local unpushed_files=""
        local remote_branch="origin/$current_branch"
        if git rev-parse --verify "$remote_branch" >/dev/null 2>&1; then
            unpushed_files=$(git diff --name-only "$remote_branch..HEAD" 2>/dev/null || echo "")
        fi

        # 合并所有需要同步的文件
        local all_files="$modified_files"$'\n'"$staged_files"$'\n'"$untracked_files"$'\n'"$unpushed_files"
        local unique_files=$(echo "$all_files" | grep -v '^$' | sort -u)

        if [ -z "$unique_files" ]; then
            echo -e "${GREEN}[$dir_name] No changes to sync${NC}"
            echo -e "${DARK_GRAY}----------------------------------------${NC}"
            continue
        fi

        # 统计文件数量
        local file_count=$(echo "$unique_files" | wc -l)
        local modified_count=$(echo "$modified_files" | grep -v '^$' | wc -l)
        local staged_count=$(echo "$staged_files" | grep -v '^$' | wc -l)
        local untracked_count=$(echo "$untracked_files" | grep -v '^$' | wc -l)
        local unpushed_count=$(echo "$unpushed_files" | grep -v '^$' | wc -l)

        local sync_info=""
        [ $modified_count -gt 0 ] && sync_info+="M:$modified_count "
        [ $staged_count -gt 0 ] && sync_info+="S:$staged_count "
        [ $untracked_count -gt 0 ] && sync_info+="U:$untracked_count "
        [ $unpushed_count -gt 0 ] && sync_info+="P:$unpushed_count "

        echo -e "${YELLOW}[$dir_name] Syncing $file_count files ($sync_info)${NC}"

        # 在同步前，智能回滚远程不需要的文件
        echo -e "${GRAY}[$dir_name] Smart rollback on remote...${NC}"
        update_remote_repository "$remote_target_dir" "$dir_name" "$unique_files"

        # 使用rsync同步特定文件
        if [ -n "$unique_files" ]; then
            # 调试：显示要同步的文件列表
            echo -e "${GRAY}Files to sync: $(echo "$unique_files" | tr '\n' ' ')${NC}"

            # 构建rsync命令，使用--include和--exclude模式来只同步指定文件
            local remote_target="${REMOTE_HOST}:${remote_target_dir}/"
            local include_args=""

            # 为每个文件创建include参数
            while IFS= read -r file; do
                if [ -n "$file" ]; then
                    include_args+="--include=$file "
                    # 如果文件在子目录中，也需要包含父目录
                    local dir_path=$(dirname "$file")
                    while [ "$dir_path" != "." ] && [ "$dir_path" != "/" ]; do
                        include_args+="--include=$dir_path/ "
                        dir_path=$(dirname "$dir_path")
                    done
                fi
            done <<< "$unique_files"

            # 排除所有其他文件
            include_args+="--exclude=* "

            local rsync_cmd="rsync -avz $include_args $exclude_args -e \"ssh -p $REMOTE_PORT\" \"$local_dir/\" \"$remote_target\""

            # 显示rsync命令（调试用）
            echo -e "${GRAY}Executing: rsync with $(echo "$unique_files" | wc -l) files${NC}"

            # 执行rsync并显示传输信息
            eval "$rsync_cmd" 2>&1 | grep -E "(sending|sent|total|->)" || true
            local exit_code=${PIPESTATUS[0]}

            if [ $exit_code -eq 0 ]; then
                echo -e "${GREEN}[$dir_name] Sync completed${NC}"
            else
                echo -e "${RED}[$dir_name] Sync failed (exit code: $exit_code)${NC}"
            fi
        else
            echo -e "${YELLOW}[$dir_name] No valid files to sync${NC}"
        fi

        echo -e "${DARK_GRAY}----------------------------------------${NC}"
    done
}

function show_config() {
    echo -e "${CYAN}=== Git Sync Service ===${NC}"
    echo -e "${WHITE}Remote: $REMOTE_HOST:$REMOTE_DIR${NC}"
    echo -e "${WHITE}Interval: ${REFRESH_INTERVAL}s | Repositories: ${#LOCAL_DIRS[@]} | Excludes: ${#EXCLUDE_PATTERNS[@]}${NC}"

    local git_repos=0
    for dir in "${LOCAL_DIRS[@]}"; do
        if [ -d "$dir/.git" ]; then
            ((git_repos++))
        fi
    done

    if [ $git_repos -eq ${#LOCAL_DIRS[@]} ]; then
        echo -e "${GREEN}All directories are Git repositories${NC}"
    else
        echo -e "${YELLOW}Warning: $((${#LOCAL_DIRS[@]} - git_repos)) directories are not Git repositories${NC}"
    fi
    echo ""
}

# 信号处理函数
function cleanup() {
    echo -e "\n${YELLOW}Received interrupt signal, stopping sync...${NC}"
    exit 0
}

# 设置信号处理
trap cleanup SIGINT SIGTERM

# 显示配置信息
show_config

# 主循环
echo -e "${GREEN}Git sync started. Press Ctrl+C to stop.${NC}"
echo ""

while true; do
    sync_files
    echo -e "${GRAY}Next check in $REFRESH_INTERVAL seconds...${NC}"
    echo ""
    sleep "$REFRESH_INTERVAL"
done