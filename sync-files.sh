#!/bin/bash

# 防止重复加载配置函数
if [ -n "$SYNC_CONFIG_LOADED" ]; then
    return 0 2>/dev/null || true
fi
SYNC_CONFIG_LOADED=true

# 配置文件路径
CONFIG_FILE="/mnt/d/sync.yaml"

# 默认配置 (当YAML文件不存在或解析失败时使用)
DEFAULT_REMOTE_HOST="34.68.158.244"
DEFAULT_REMOTE_PORT="22"
DEFAULT_REMOTE_DIR="/root/work"
DEFAULT_REMOTE_OS="ubuntu"
DEFAULT_REFRESH_INTERVAL=60
DEFAULT_LOCAL_DIRS=()
DEFAULT_EXCLUDE_PATTERNS=(
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

# 当前配置变量 (从YAML加载或使用默认值)
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
REMOTE_SCRIPT_PATH="/tmp/$REMOTE_SCRIPT_NAME"
LOCAL_SCRIPT_PATH="./remote-sync-helper.sh"
REMOTE_SCRIPT_UPLOADED=false

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
DARK_GRAY='\033[1;30m'
NC='\033[0m' # No Color

# 全局变量：循环计数器和错误统计
LOOP_COUNTER=0
ERROR_COUNTER=0
MAX_ERRORS=10
MAX_LOOPS=86400  # 24小时最大循环次数（按秒计算）

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

function load_config() {
    # 检查配置文件是否存在
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Configuration file not found: $CONFIG_FILE${NC}"
        echo -e "${YELLOW}Using default configuration...${NC}"
        load_default_config
        return
    fi
    
    # 获取配置文件的时间戳
    local current_timestamp=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null)
    
    # 检查是否有缓存且时间戳一致
    if [ -f "$CONFIG_CACHE_FILE" ] && [ "$CONFIG_TIMESTAMP" = "$current_timestamp" ] && [ ${#LOCAL_DIRS[@]} -gt 0 ]; then
        echo -e "${GRAY}Using cached configuration (timestamp: $current_timestamp)${NC}"
        return
    fi
    
    # 静默加载配置
    
    # 先加载默认配置作为基础
    load_default_config
    
    # 清空数组配置
    LOCAL_DIRS=()
    EXCLUDE_PATTERNS=()
    
    # YAML解析状态变量
    local in_directories_section=false
    local in_exclude_patterns_section=false
    local in_remote_section=false
    
    while IFS= read -r line; do
        # 去除前后空格
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        # 检查顶级配置项
        if [[ "$line" =~ ^remote: ]]; then
            in_remote_section=true
            in_directories_section=false
            in_exclude_patterns_section=false
            continue
        elif [[ "$line" =~ ^directories: ]]; then
            in_directories_section=true
            in_remote_section=false
            in_exclude_patterns_section=false
            continue
        elif [[ "$line" =~ ^exclude_patterns: ]]; then
            in_exclude_patterns_section=true
            in_directories_section=false
            in_remote_section=false
            continue
        elif [[ "$line" =~ ^refresh_interval:[[:space:]]*(.+)$ ]]; then
            local interval_value="${BASH_REMATCH[1]}"
            # 去除引号并提取数字
            interval_value=$(echo "$interval_value" | sed 's/^["'\'']*//;s/["'\'']*$//')
            REFRESH_INTERVAL="$interval_value"
            echo -e "${GRAY}  Set refresh_interval: $REFRESH_INTERVAL${NC}"
            in_directories_section=false
            in_remote_section=false
            in_exclude_patterns_section=false
            continue
        elif [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*: ]]; then
            # 其他顶级键，重置所有section标志
            in_directories_section=false
            in_remote_section=false
            in_exclude_patterns_section=false
            continue
        fi
        
        # 处理remote部分的配置
        if [ "$in_remote_section" = true ]; then
            if [[ "$line" =~ ^host:[[:space:]]*(.+)$ ]]; then
                # 提取值并去除引号
                local host_value="${BASH_REMATCH[1]}"
                # 去除双引号和单引号
                host_value=$(echo "$host_value" | sed 's/^["'\'']*//;s/["'\'']*$//')
                REMOTE_HOST="$host_value"
            elif [[ "$line" =~ ^port:[[:space:]]*(.+)$ ]]; then
                local port_value="${BASH_REMATCH[1]}"
                # 去除引号并提取数字
                port_value=$(echo "$port_value" | sed 's/^["'\'']*//;s/["'\'']*$//')
                REMOTE_PORT="$port_value"
            elif [[ "$line" =~ ^dir:[[:space:]]*(.+)$ ]]; then
                local dir_value="${BASH_REMATCH[1]}"
                # 去除引号
                dir_value=$(echo "$dir_value" | sed 's/^["'\'']*//;s/["'\'']*$//')
                REMOTE_DIR="$dir_value"
            elif [[ "$line" =~ ^os:[[:space:]]*(.+)$ ]]; then
                local os_value="${BASH_REMATCH[1]}"
                # 去除引号
                os_value=$(echo "$os_value" | sed 's/^["'\'']*//;s/["'\'']*$//')
                REMOTE_OS="$os_value"
            fi
        fi
        
        # 处理directories部分
        if [ "$in_directories_section" = true ] && [[ "$line" =~ ^-[[:space:]]+ ]]; then
            local dir_path=$(echo "$line" | sed 's/^-[[:space:]]*//' | sed 's/^["'\'']//' | sed 's/["'\'']*$//')
            if [ -n "$dir_path" ]; then
                LOCAL_DIRS+=("$dir_path")
            fi
        fi
        
        # 处理exclude_patterns部分
        if [ "$in_exclude_patterns_section" = true ] && [[ "$line" =~ ^-[[:space:]]+ ]]; then
            local pattern=$(echo "$line" | sed 's/^-[[:space:]]*//' | sed 's/^["'\'']//' | sed 's/["'\'']*$//')
            if [ -n "$pattern" ]; then
                EXCLUDE_PATTERNS+=("$pattern")
            fi
        fi
        
    done < "$CONFIG_FILE"
    
    # 更新时间戳缓存
    CONFIG_TIMESTAMP="$current_timestamp"
    
    # 保存到缓存文件
    save_config_cache
    
    # 验证配置
    validate_config
    
    # 配置加载完成（静默）
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
    # 如果关键配置为空，使用默认值
    [ -z "$REMOTE_HOST" ] && REMOTE_HOST="$DEFAULT_REMOTE_HOST"
    [ -z "$REMOTE_PORT" ] && REMOTE_PORT="$DEFAULT_REMOTE_PORT"
    [ -z "$REMOTE_DIR" ] && REMOTE_DIR="$DEFAULT_REMOTE_DIR"
    [ -z "$REMOTE_OS" ] && REMOTE_OS="$DEFAULT_REMOTE_OS"
    [ -z "$REFRESH_INTERVAL" ] && REFRESH_INTERVAL="$DEFAULT_REFRESH_INTERVAL"
    
    # 如果数组为空，使用默认值
    if [ ${#LOCAL_DIRS[@]} -eq 0 ]; then
        echo -e "${YELLOW}No directories found in configuration, using defaults...${NC}"
        LOCAL_DIRS=("${DEFAULT_LOCAL_DIRS[@]}")
    fi
    
    if [ ${#EXCLUDE_PATTERNS[@]} -eq 0 ]; then
        echo -e "${YELLOW}No exclude patterns found in configuration, using defaults...${NC}"
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

function ensure_remote_script() {
    # 如果已经确认存在，跳过检查
    if [ "$REMOTE_SCRIPT_UPLOADED" = true ]; then
        return 0
    fi
    
    # 检查远程脚本是否存在
    if ssh "$REMOTE_HOST" -p "$REMOTE_PORT" "[ -x $REMOTE_SCRIPT_PATH ]" 2>/dev/null; then
        REMOTE_SCRIPT_UPLOADED=true
        return 0
    fi
    
    # 远程脚本不存在，尝试上传
    if [ ! -f "$LOCAL_SCRIPT_PATH" ]; then
        echo -e "${RED}Remote helper script not found: $LOCAL_SCRIPT_PATH${NC}"
        return 1
    fi
    
    # 上传脚本到远程服务器（静默）
    scp -P "$REMOTE_PORT" "$LOCAL_SCRIPT_PATH" "$REMOTE_HOST:$REMOTE_SCRIPT_PATH" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        ssh "$REMOTE_HOST" -p "$REMOTE_PORT" "chmod +x $REMOTE_SCRIPT_PATH" 2>/dev/null
        if [ $? -eq 0 ]; then
            REMOTE_SCRIPT_UPLOADED=true
            return 0
        else
            echo -e "${RED}Failed to set script permissions${NC}"
            return 1
        fi
    else
        echo -e "${RED}Failed to upload remote script${NC}"
        return 1
    fi
}

function load_cached_config() {
    # 如果缓存文件存在，尝试加载缓存
    if [ -f "$CONFIG_CACHE_FILE" ]; then
        local cached_dirs=()
        local cached_patterns=()
        local cached_timestamp=""
        local cached_host=""
        local cached_port=""
        local cached_dir=""
        local cached_os=""
        local cached_interval=""
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^CONFIG_TIMESTAMP= ]]; then
                cached_timestamp="${line#CONFIG_TIMESTAMP=}"
            elif [[ "$line" =~ ^REMOTE_HOST= ]]; then
                cached_host="${line#REMOTE_HOST=}"
            elif [[ "$line" =~ ^REMOTE_PORT= ]]; then
                cached_port="${line#REMOTE_PORT=}"
            elif [[ "$line" =~ ^REMOTE_DIR= ]]; then
                cached_dir="${line#REMOTE_DIR=}"
            elif [[ "$line" =~ ^REMOTE_OS= ]]; then
                cached_os="${line#REMOTE_OS=}"
            elif [[ "$line" =~ ^REFRESH_INTERVAL= ]]; then
                cached_interval="${line#REFRESH_INTERVAL=}"
            elif [[ "$line" =~ ^LOCAL_DIR= ]]; then
                cached_dirs+=("${line#LOCAL_DIR=}")
            elif [[ "$line" =~ ^EXCLUDE_PATTERN= ]]; then
                cached_patterns+=("${line#EXCLUDE_PATTERN=}")
            fi
        done < "$CONFIG_CACHE_FILE"
        
        # 检查配置文件是否存在且时间戳一致
        if [ -f "$CONFIG_FILE" ]; then
            local current_timestamp=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null)
            if [ "$cached_timestamp" = "$current_timestamp" ] && [ ${#cached_dirs[@]} -gt 0 ]; then
                # 加载所有缓存的配置
                REMOTE_HOST="$cached_host"
                REMOTE_PORT="$cached_port"
                REMOTE_DIR="$cached_dir"
                REMOTE_OS="$cached_os"
                REFRESH_INTERVAL="$cached_interval"
                LOCAL_DIRS=("${cached_dirs[@]}")
                EXCLUDE_PATTERNS=("${cached_patterns[@]}")
                CONFIG_TIMESTAMP="$cached_timestamp"
                
                # 缓存配置加载完成（静默）
                return 0
            fi
        fi
    fi
    return 1
}

function update_remote_repository() {
    local remote_target_dir="$1"
    local dir_name="$2"
    local files_to_keep="$3"  # 要保留的文件列表
    local local_hash="$4"     # 本地当前哈希值
    local local_branch="$5"   # 本地当前分支
    
    # 静默执行版本同步
    
    # 确保远程脚本已上传
    if ! ensure_remote_script; then
        echo -e "${RED}[$dir_name] Failed to ensure remote script${NC}"
        return 1
    fi
    
    # 准备排除模式参数
    local exclude_patterns=$(printf '%s\n' "${EXCLUDE_PATTERNS[@]}" | tr '\n' '|' | sed 's/|$//')
    
    # 使用远程脚本执行同步
    local sync_result=$(ssh "$REMOTE_HOST" -p "$REMOTE_PORT" \
        "$REMOTE_SCRIPT_PATH sync_version \"$remote_target_dir\" \"$files_to_keep\" \"$local_hash\" \"$local_branch\" \"$exclude_patterns\"" 2>/dev/null)
    
    # 解析同步结果
    local remote_info=""
    local sync_status=""
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^REMOTE_STATUS: ]]; then
            remote_info="${line#REMOTE_STATUS:}"
        elif [[ "$line" =~ ^(HASH_MATCH|REMOTE_NEWER|PULLING_TO_LOCAL_HASH|BRANCH_DIVERGED_RESETTING|BRANCH_MISMATCH_SWITCHING|SYNC_COMPLETED|NOT_GIT_REPO|NO_REMOTE_ORIGIN|RESET_FAILED|HASH_NOT_FOUND)$ ]]; then
            sync_status="$line"
        elif [[ "$line" =~ ^ERROR: ]]; then
            echo -e "${RED}[$dir_name] ${line#ERROR:}${NC}"
            return 1
        fi
    done <<< "$sync_result"
    
    # 显示同步结果（只显示关键状态）
    case "$sync_status" in
        "HASH_MATCH")
            return 0  # 静默跳过，版本已同步
            ;;
        "REMOTE_NEWER")
            echo -e "${YELLOW}[$dir_name] Remote version is newer${NC}"
            ;;
        "PULLING_TO_LOCAL_HASH"|"BRANCH_DIVERGED_RESETTING"|"BRANCH_MISMATCH_SWITCHING")
            echo -e "${CYAN}[$dir_name] Updated to local version${NC}"
            ;;
        "NOT_GIT_REPO"|"RESET_FAILED"|"HASH_NOT_FOUND")
            echo -e "${RED}[$dir_name] Sync failed: $sync_status${NC}"
            ;;
        "NO_REMOTE_ORIGIN")
            echo -e "${YELLOW}[$dir_name] No remote origin${NC}"
            ;;
    esac
}

# 安全函数：验证路径是否安全
function validate_path() {
    local path="$1"
    # 检查路径是否包含危险字符，但允许正常的绝对路径
    if [[ "$path" =~ \.\./|^\.|[\;\|\&\$\`] ]]; then
        return 1
    fi
    # 检查是否包含连续的斜杠（可能的路径注入）
    if [[ "$path" =~ // ]]; then
        return 1
    fi
    # 检查是否包含危险的系统路径（但允许常用的工作目录）
    if [[ "$path" =~ ^/etc/|^/boot/|^/sys/|^/proc/|^/dev/ ]]; then
        return 1
    fi
    return 0
}

# 安全函数：转义shell特殊字符
function escape_shell_arg() {
    local arg="$1"
    # 使用printf %q进行安全转义
    printf '%q' "$arg"
}

# 功能：执行初始完整同步（优化的压缩传输）
function perform_initial_sync() {
    local local_dir="$1"
    local remote_target_dir="$2"
    local dir_name="$3"
    
    # 验证路径安全性
    if ! validate_path "$remote_target_dir"; then
        echo -e "${RED}[$dir_name] Invalid remote path detected${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}[$dir_name] Starting initial sync with optimized compression...${NC}"
    
    # 统一使用压缩传输（更高效）
    local dir_size=$(du -sm "$local_dir" 2>/dev/null | cut -f1)
    echo -e "${CYAN}[$dir_name] Directory size: ${dir_size}MB${NC}"
    
    # 检查文件数量，选择最优压缩策略
    local file_count=$(find "$local_dir" -type f | wc -l)
    echo -e "${CYAN}[$dir_name] File count: ${file_count}${NC}"
    
    if [ "$file_count" -gt 10000 ] || [ "$dir_size" -gt 500 ]; then
        # 大量文件或超大目录：使用快速压缩
        echo -e "${CYAN}[$dir_name] Using fast compression for large dataset...${NC}"
        perform_compressed_initial_sync "$local_dir" "$remote_target_dir" "$dir_name" "fast"
    else
        # 普通大小：使用标准压缩
        echo -e "${CYAN}[$dir_name] Using standard compression...${NC}"
        perform_compressed_initial_sync "$local_dir" "$remote_target_dir" "$dir_name" "standard"
    fi
}



# 功能：使用优化压缩进行初始同步
function perform_compressed_initial_sync() {
    local local_dir="$1"
    local remote_target_dir="$2"
    local dir_name="$3"
    local compression_mode="${4:-standard}"  # fast|standard
    
    local exclude_args_tar=$(get_tar_exclude_args)
    local temp_archive=""
    local compression_level=""
    
    echo -e "${CYAN}[$dir_name] Creating compressed archive (${compression_mode} mode)...${NC}"
    
    # 根据压缩模式选择算法和级别
    case "$compression_mode" in
        "fast")
            # 快速模式：优先使用lz4，压缩级别最低
            if command -v lz4 >/dev/null 2>&1; then
                temp_archive=$(mktemp --suffix=.tar.lz4)
                compression_level="-1"  # 最快压缩
                echo -e "${CYAN}[$dir_name] Using LZ4 fast compression...${NC}"
            else
                temp_archive=$(mktemp --suffix=.tar.gz)
                compression_level="-1"  # gzip最快级别
                echo -e "${CYAN}[$dir_name] Using gzip fast compression...${NC}"
            fi
            ;;
        "standard")
            # 标准模式：平衡压缩率和速度
            if command -v lz4 >/dev/null 2>&1; then
                temp_archive=$(mktemp --suffix=.tar.lz4)
                compression_level="-3"  # 平衡压缩
                echo -e "${CYAN}[$dir_name] Using LZ4 standard compression...${NC}"
            else
                temp_archive=$(mktemp --suffix=.tar.gz)
                compression_level="-3"  # gzip平衡级别
                echo -e "${CYAN}[$dir_name] Using gzip standard compression...${NC}"
            fi
            ;;
    esac
    
    # 执行压缩
    if [[ "$temp_archive" == *.lz4 ]]; then
        # 使用lz4压缩
        if ! tar -cf - $exclude_args_tar -C "$local_dir" . | lz4 $compression_level > "$temp_archive" 2>/dev/null; then
            echo -e "${RED}[$dir_name] Failed to create lz4 archive${NC}"
            rm -f "$temp_archive"
            return 1
        fi
    else
        # 使用gzip压缩
        if ! tar -cf - $exclude_args_tar -C "$local_dir" . | gzip $compression_level > "$temp_archive" 2>/dev/null; then
            echo -e "${RED}[$dir_name] Failed to create gzip archive${NC}"
            rm -f "$temp_archive"
            return 1
        fi
    fi
    
    # 显示压缩后的文件大小
    local archive_size=$(du -h "$temp_archive" 2>/dev/null | cut -f1)
    echo -e "${CYAN}[$dir_name] Archive created: ${archive_size}${NC}"
    
    # 创建远程目录
    local escaped_remote_dir=$(escape_shell_arg "$remote_target_dir")
    if ! ssh "$REMOTE_HOST" -p "$REMOTE_PORT" "mkdir -p $escaped_remote_dir" 2>/dev/null; then
        echo -e "${RED}[$dir_name] Failed to create remote directory${NC}"
        rm -f "$temp_archive"
        return 1
    fi
    
    # 使用优化的传输参数上传
    echo -e "${CYAN}[$dir_name] Uploading archive (${archive_size})...${NC}"
    
    # 根据文件类型选择最优传输参数
    local transfer_args=()
    if [[ "$temp_archive" == *.lz4 ]]; then
        # LZ4文件：禁用SSH压缩，使用快速传输
        transfer_args=(
            "-P" "$REMOTE_PORT"
            "-o" "Compression=no"        # 禁用SSH压缩
            "-o" "ConnectTimeout=10"
            "-o" "ServerAliveInterval=60"
            "$temp_archive"
            "$REMOTE_HOST:$remote_target_dir/project.tar.lz4"
        )
    else
        # GZIP文件：同样禁用SSH压缩
        transfer_args=(
            "-P" "$REMOTE_PORT"
            "-o" "Compression=no"        # 禁用SSH压缩
            "-o" "ConnectTimeout=10"
            "-o" "ServerAliveInterval=60"
            "$temp_archive"
            "$REMOTE_HOST:$remote_target_dir/project.tar.gz"
        )
    fi
    
    # 显示传输进度（如果有pv工具）
    if command -v pv >/dev/null 2>&1; then
        echo -e "${CYAN}[$dir_name] Transferring with progress monitor...${NC}"
        pv "$temp_archive" | ssh "$REMOTE_HOST" -p "$REMOTE_PORT" "cat > $remote_target_dir/project.tar.${temp_archive##*.}"
        local upload_result=$?
    else
        # 使用标准scp传输
        scp "${transfer_args[@]}" 2>/dev/null
        local upload_result=$?
    fi
    
    if [ $upload_result -ne 0 ]; then
        echo -e "${RED}[$dir_name] Failed to upload archive${NC}"
        rm -f "$temp_archive"
        return 1
    fi
    
    # 远程解压
    echo -e "${CYAN}[$dir_name] Extracting archive on remote server...${NC}"
    local extract_cmd=""
    local archive_name=""
    
    if [[ "$temp_archive" == *.lz4 ]]; then
        archive_name="project.tar.lz4"
        # 检查远程是否有lz4工具
        extract_cmd="
            if command -v lz4 >/dev/null 2>&1; then
                lz4 -dc $archive_name | tar -xf -
            else
                echo 'ERROR: lz4 not found on remote server'
                exit 1
            fi
        "
    else
        archive_name="project.tar.gz"
        extract_cmd="tar -xzf $archive_name"
    fi
    
    local remote_extract_result=$(ssh "$REMOTE_HOST" -p "$REMOTE_PORT" "
        cd $(escape_shell_arg "$remote_target_dir") && 
        $extract_cmd && 
        rm -f $archive_name && 
        echo 'SUCCESS'
    " 2>/dev/null)
    
    rm -f "$temp_archive"
    
    if [ "$remote_extract_result" = "SUCCESS" ]; then
        echo -e "${GREEN}[$dir_name] Optimized sync completed${NC}"
        return 0
    else
        echo -e "${RED}[$dir_name] Failed to extract on remote${NC}"
        return 1
    fi
}

function sync_files() {
    local exclude_args=$(get_exclude_args)
    
    for local_dir in "${LOCAL_DIRS[@]}"; do
        local dir_name=$(basename "$local_dir")
        local remote_target_dir="$REMOTE_DIR/$dir_name"
        
        # 检查本地目录是否存在
        if [ ! -d "$local_dir" ]; then
            echo -e "${RED}[$dir_name] Directory not found${NC}"
            continue
        fi
        
        # 检查本地是否为git仓库
        if [ ! -d "$local_dir/.git" ]; then
            echo -e "${YELLOW}[$dir_name] Not a git repository, skipping...${NC}"
            continue
        fi
        
        if ! cd "$local_dir" 2>/dev/null; then
            echo -e "${RED}[$dir_name] Cannot access directory${NC}"
            continue
        fi
        
        # 首先检查远程目录是否存在项目
        # 确保远程脚本已上传
        if ! ensure_remote_script; then
            echo -e "${RED}[$dir_name] Failed to ensure remote script${NC}"
            continue
        fi
        
        local remote_exists=$(ssh "$REMOTE_HOST" -p "$REMOTE_PORT" \
            "$REMOTE_SCRIPT_PATH check_repo \"$remote_target_dir\"" 2>/dev/null)
        
        if [ "$remote_exists" = "not_exists" ]; then
            # 执行初始完整同步
            perform_initial_sync "$local_dir" "$remote_target_dir" "$dir_name"
            continue
        fi
        
        # 远程项目存在，检查是否有需要同步的变更
        # 获取当前分支名或HEAD状态
        local current_branch=$(git branch --show-current 2>/dev/null)
        local is_detached_head=false
        
        if [ -z "$current_branch" ]; then
            # 检查是否处于detached HEAD状态
            if git symbolic-ref HEAD >/dev/null 2>&1; then
                echo -e "${RED}[$dir_name] Unable to determine current branch${NC}"
                continue
            else
                # 处于detached HEAD状态
                is_detached_head=true
                local current_commit=$(git rev-parse HEAD 2>/dev/null)
                echo -e "${YELLOW}[$dir_name] Detached HEAD at ${current_commit:0:8}${NC}"
                
                # 尝试找到包含当前commit的分支
                local containing_branches=$(git branch --contains HEAD 2>/dev/null | grep -v '(HEAD detached' | head -1 | sed 's/^[* ] *//')
                if [ -n "$containing_branches" ]; then
                    current_branch="$containing_branches"
                    echo -e "${CYAN}[$dir_name] Using branch: $current_branch (contains current commit)${NC}"
                else
                    # 如果找不到包含的分支，使用master/main作为默认分支
                    if git show-ref --verify --quiet refs/heads/master; then
                        current_branch="master"
                    elif git show-ref --verify --quiet refs/heads/main; then
                        current_branch="main"
                    else
                        echo -e "${RED}[$dir_name] Cannot determine branch for detached HEAD${NC}"
                        continue
                    fi
                    echo -e "${CYAN}[$dir_name] Using default branch: $current_branch${NC}"
                fi
            fi
        fi
        
        # 检查远程分支是否存在
        local remote_branch="origin/$current_branch"
        if ! git rev-parse --verify "$remote_branch" >/dev/null 2>&1; then
            # 如果远程分支不存在，检查是否有未提交的更改
            if git diff --quiet && git diff --cached --quiet; then
                # 即使没有本地更改，也要确保远程保持最新
                local local_hash=$(git rev-parse HEAD 2>/dev/null)
                echo -e "${YELLOW}[$dir_name] No local changes, updating remote...${NC}"
                update_remote_repository "$remote_target_dir" "$dir_name" "" "$local_hash" "$current_branch"
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
                local local_hash=$(git rev-parse HEAD 2>/dev/null)
                echo -e "${YELLOW}[$dir_name] No local changes, updating remote...${NC}"
                update_remote_repository "$remote_target_dir" "$dir_name" "" "$local_hash" "$current_branch"
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
        
        # 在同步前，智能版本同步和回滚远程不需要的文件
        local local_hash=$(git rev-parse HEAD 2>/dev/null)
        update_remote_repository "$remote_target_dir" "$dir_name" "$unique_files" "$local_hash" "$current_branch"
        
        # 使用rsync同步特定文件（高性能版本）
        if [ -n "$unique_files" ]; then
            local remote_target="${REMOTE_HOST}:${remote_target_dir}/"
            local include_args=""
            
            # 安全的文件路径处理
            while IFS= read -r file; do
                if [ -n "$file" ]; then
                    # 验证文件路径安全性
                    if ! validate_path "$file"; then
                        echo -e "${YELLOW}[$dir_name] Skipping unsafe path: $file${NC}"
                        continue
                    fi
                    
                    include_args+="--include=$(escape_shell_arg "$file") "
                    local dir_path=$(dirname "$file")
                    # 限制目录遍历深度，防止无限循环
                    local depth=0
                    while [ "$dir_path" != "." ] && [ "$dir_path" != "/" ] && [ $depth -lt 20 ]; do
                        if validate_path "$dir_path"; then
                            include_args+="--include=$(escape_shell_arg "$dir_path")/ "
                        fi
                        dir_path=$(dirname "$dir_path")
                        ((depth++))
                    done
                fi
            done <<< "$unique_files"
            
            include_args+="--exclude=* "
            
            # 使用高性能rsync参数
            local rsync_args=(
                "-avz"
                "--compress-level=1"      # 低压缩级别，更快
                "--whole-file"           # 传输整个文件
                "--partial"              # 支持断点续传
                $include_args
                $exclude_args
                "-e" "ssh -p $REMOTE_PORT -o Compression=no -o ConnectTimeout=10"
                "$local_dir/"
                "$remote_target"
            )
            
            # 静默执行rsync
            if rsync "${rsync_args[@]}" >/dev/null 2>&1; then
                echo -e "${GREEN}[$dir_name] Files synced${NC}"
            else
                echo -e "${RED}[$dir_name] Sync failed${NC}"
            fi
        fi
    done
}

function show_config() {
    echo -e "${CYAN}=== Git Sync Service ===${NC}"
    echo -e "${WHITE}Remote: $REMOTE_HOST:$REMOTE_DIR | Interval: ${REFRESH_INTERVAL}s | Repos: ${#LOCAL_DIRS[@]}${NC}"
    echo ""
}

# 信号处理函数
function cleanup() {
    echo -e "\n${YELLOW}Received interrupt signal, stopping sync...${NC}"
    # 清理临时文件
    rm -f /tmp/sync_*.tar.gz 2>/dev/null || true
    echo -e "${CYAN}Loop statistics: $LOOP_COUNTER iterations, $ERROR_COUNTER errors${NC}"
    exit 0
}

# 安全函数：检查系统资源
function check_system_resources() {
    # 检查内存使用率
    local mem_usage=$(free | awk 'NR==2{printf "%.0f", $3*100/$2}' 2>/dev/null || echo "0")
    if [ "$mem_usage" -gt 90 ]; then
        echo -e "${RED}Warning: High memory usage (${mem_usage}%)${NC}"
        return 1
    fi
    
    # 检查磁盘空间
    local disk_usage=$(df / | awk 'NR==2{print $5}' | sed 's/%//' 2>/dev/null || echo "0")
    if [ "$disk_usage" -gt 95 ]; then
        echo -e "${RED}Warning: Low disk space (${disk_usage}% used)${NC}"
        return 1
    fi
    
    return 0
}

# 安全函数：循环保护检查
function check_loop_safety() {
    ((LOOP_COUNTER++))
    
    # 检查循环次数
    if [ $LOOP_COUNTER -gt $MAX_LOOPS ]; then
        echo -e "${RED}Error: Maximum loop count reached. Exiting for safety.${NC}"
        return 1
    fi
    
    # 检查错误次数
    if [ $ERROR_COUNTER -gt $MAX_ERRORS ]; then
        echo -e "${RED}Error: Too many errors encountered. Exiting for safety.${NC}"
        return 1
    fi
    
    # 每100次循环检查一次系统资源
    if [ $((LOOP_COUNTER % 100)) -eq 0 ]; then
        if ! check_system_resources; then
            ((ERROR_COUNTER++))
            return 1
        fi
    fi
    
    return 0
}

# 主执行逻辑 - 只有直接运行脚本时才执行
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # 设置信号处理
    trap cleanup SIGINT SIGTERM

    # 初始加载配置
    if ! load_cached_config; then
        load_config
    fi

    # 显示配置信息
    show_config

    # 主循环（安全版本）
    echo -e "${GREEN}Git sync started. Press Ctrl+C to stop.${NC}"
    echo ""

    while true; do
        # 循环安全检查
        if ! check_loop_safety; then
            echo -e "${RED}Safety check failed. Stopping sync service.${NC}"
            break
        fi
        
        # 每次循环前检查配置文件是否有变化
        if ! load_config; then
            echo -e "${YELLOW}Failed to load config, using cached version${NC}"
            ((ERROR_COUNTER++))
        fi
        
        # 执行同步，捕获错误
        if ! sync_files; then
            echo -e "${YELLOW}Sync failed, continuing...${NC}"
            ((ERROR_COUNTER++))
        else
            # 成功执行，重置错误计数器
            ERROR_COUNTER=0
        fi
        
        # 静默等待下次检查
        sleep "$REFRESH_INTERVAL"
    done
fi 