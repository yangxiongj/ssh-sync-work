#!/bin/bash

# 文件同步服务一键安装脚本
echo -e "\033[0;36m=== 文件同步服务安装程序 ===\033[0m"
echo ""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-files.sh"
SERVICE_SCRIPT="$SCRIPT_DIR/sync-service.sh"
REMOTE_HELPER_SCRIPT="$SCRIPT_DIR/remote-sync-helper.sh"

# 检查必要文件
echo -e "${YELLOW}检查必要文件...${NC}"

if [ ! -f "$SYNC_SCRIPT" ]; then
    echo -e "${RED}错误: 找不到 sync-files.sh${NC}"
    exit 1
fi

if [ ! -f "$SERVICE_SCRIPT" ]; then
    echo -e "${RED}错误: 找不到 sync-service.sh${NC}"
    exit 1
fi

if [ ! -f "$REMOTE_HELPER_SCRIPT" ]; then
    echo -e "${RED}错误: 找不到 remote-sync-helper.sh${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 所有必要文件已找到${NC}"

# 设置脚本执行权限
chmod +x "$SYNC_SCRIPT"
chmod +x "$SERVICE_SCRIPT"
chmod +x "$REMOTE_HELPER_SCRIPT"

# 检查依赖
echo ""
echo -e "${YELLOW}检查系统依赖...${NC}"

# 检查git
if ! command -v git &> /dev/null; then
    echo -e "${RED}错误: 未找到 git，请先安装${NC}"
    echo "Ubuntu/Debian: sudo apt install git"
    echo "CentOS/RHEL: sudo yum install git"
    exit 1
fi

# 检查rsync
if ! command -v rsync &> /dev/null; then
    echo -e "${RED}错误: 未找到 rsync，请先安装${NC}"
    echo "Ubuntu/Debian: sudo apt install rsync"
    echo "CentOS/RHEL: sudo yum install rsync"
    exit 1
fi

# 检查ssh
if ! command -v ssh &> /dev/null; then
    echo -e "${RED}错误: 未找到 ssh，请先安装${NC}"
    echo "Ubuntu/Debian: sudo apt install openssh-client"
    echo "CentOS/RHEL: sudo yum install openssh-clients"
    exit 1
fi

# 检查tar
if ! command -v tar &> /dev/null; then
    echo -e "${RED}错误: 未找到 tar，请先安装${NC}"
    echo "Ubuntu/Debian: sudo apt install tar"
    echo "CentOS/RHEL: sudo yum install tar"
    exit 1
fi

# 检查scp
if ! command -v scp &> /dev/null; then
    echo -e "${RED}错误: 未找到 scp，请先安装${NC}"
    echo "Ubuntu/Debian: sudo apt install openssh-client"
    echo "CentOS/RHEL: sudo yum install openssh-clients"
    exit 1
fi

# 检查systemctl
if ! command -v systemctl &> /dev/null; then
    echo -e "${RED}错误: 系统不支持 systemd${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 基础依赖检查通过${NC}"

# 检查并安装性能优化工具
echo ""
echo -e "${YELLOW}检查性能优化工具...${NC}"

# 检查lz4压缩工具
if ! command -v lz4 &> /dev/null; then
    echo -e "${YELLOW}未找到 lz4 压缩工具，将自动安装以提升传输性能${NC}"
    
    # 检测系统类型并安装lz4
    if command -v apt &> /dev/null; then
        echo -e "${CYAN}检测到 Debian/Ubuntu 系统，安装 lz4...${NC}"
        if sudo apt update >/dev/null 2>&1 && sudo apt install -y lz4 >/dev/null 2>&1; then
            echo -e "${GREEN}✓ lz4 安装成功${NC}"
        else
            echo -e "${YELLOW}警告: lz4 安装失败，将使用标准压缩${NC}"
        fi
    elif command -v yum &> /dev/null; then
        echo -e "${CYAN}检测到 CentOS/RHEL 系统，安装 lz4...${NC}"
        if sudo yum install -y lz4 >/dev/null 2>&1; then
            echo -e "${GREEN}✓ lz4 安装成功${NC}"
        else
            echo -e "${YELLOW}警告: lz4 安装失败，将使用标准压缩${NC}"
        fi
    elif command -v dnf &> /dev/null; then
        echo -e "${CYAN}检测到 Fedora 系统，安装 lz4...${NC}"
        if sudo dnf install -y lz4 >/dev/null 2>&1; then
            echo -e "${GREEN}✓ lz4 安装成功${NC}"
        else
            echo -e "${YELLOW}警告: lz4 安装失败，将使用标准压缩${NC}"
        fi
    else
        echo -e "${YELLOW}警告: 无法自动安装 lz4，请手动安装以获得最佳性能${NC}"
    fi
else
    echo -e "${GREEN}✓ lz4 已安装${NC}"
fi

# 检查pv工具（进度显示）
if ! command -v pv &> /dev/null; then
    echo -e "${YELLOW}未找到 pv 工具，将自动安装以显示传输进度${NC}"
    
    if command -v apt &> /dev/null; then
        if sudo apt install -y pv >/dev/null 2>&1; then
            echo -e "${GREEN}✓ pv 安装成功${NC}"
        else
            echo -e "${YELLOW}警告: pv 安装失败${NC}"
        fi
    elif command -v yum &> /dev/null; then
        if sudo yum install -y pv >/dev/null 2>&1; then
            echo -e "${GREEN}✓ pv 安装成功${NC}"
        else
            echo -e "${YELLOW}警告: pv 安装失败${NC}"
        fi
    elif command -v dnf &> /dev/null; then
        if sudo dnf install -y pv >/dev/null 2>&1; then
            echo -e "${GREEN}✓ pv 安装成功${NC}"
        else
            echo -e "${YELLOW}警告: pv 安装失败${NC}"
        fi
    fi
else
    echo -e "${GREEN}✓ pv 已安装${NC}"
fi

echo -e "${GREEN}✓ 所有依赖检查和优化工具安装完成${NC}"

# 导入配置处理函数
source "$SYNC_SCRIPT"

# 检查并安装远程服务器优化工具
function check_and_install_remote_tools() {
    local remote_host="$1"
    local remote_port="$2"
    local remote_os="$3"  # 配置的远程操作系统类型
    
    echo -e "${CYAN}检查远程服务器 $remote_host:$remote_port 的优化工具...${NC}"
    
    # 测试SSH连接
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$remote_host" -p "$remote_port" "echo 'SSH连接测试成功'" 2>/dev/null; then
        echo -e "${YELLOW}警告: 无法连接到远程服务器，跳过工具检查${NC}"
        return 1
    fi
    
    # 使用配置的操作系统类型，而不是检测
    local system=""
    case "${remote_os,,}" in  # 转换为小写
        ubuntu|debian)
            system="debian"
            ;;
        centos|rhel|redhat)
            system="rhel"
            ;;
        fedora)
            system="fedora"
            ;;
        alpine)
            system="alpine"
            ;;
        *)
            echo -e "${YELLOW}警告: 未知的远程操作系统类型 '$remote_os'，默认使用 debian${NC}"
            system="debian"
            ;;
    esac
    
    echo -e "${GRAY}配置的远程系统: $remote_os -> $system${NC}"
    
    # 检查远程工具状态（不再检测系统类型）
    local remote_check_result=$(ssh "$remote_host" -p "$remote_port" '
        # 检查lz4
        if command -v lz4 >/dev/null 2>&1; then
            LZ4_STATUS="installed"
        else
            LZ4_STATUS="missing"
        fi
        
        # 检查pv
        if command -v pv >/dev/null 2>&1; then
            PV_STATUS="installed"
        else
            PV_STATUS="missing"
        fi
        
        echo "$LZ4_STATUS:$PV_STATUS"
    ' 2>/dev/null)
    
    if [ -z "$remote_check_result" ]; then
        echo -e "${YELLOW}警告: 无法检查远程工具状态${NC}"
        return 1
    fi
    
    # 解析结果
    IFS=':' read -r lz4_status pv_status <<< "$remote_check_result"
    
    echo -e "${GRAY}远程工具状态: lz4: $lz4_status, pv: $pv_status${NC}"
    
    # 安装缺失的工具
    local install_commands=""
    local tools_to_install=""
    
    if [ "$lz4_status" = "missing" ]; then
        tools_to_install+="lz4 "
    fi
    
    if [ "$pv_status" = "missing" ]; then
        tools_to_install+="pv "
    fi
    
    if [ -n "$tools_to_install" ]; then
        echo -e "${YELLOW}远程服务器缺少优化工具: $tools_to_install${NC}"
        echo -e "${CYAN}正在安装远程优化工具...${NC}"
        
        case "$system" in
            "debian")
                install_commands="sudo apt update >/dev/null 2>&1 && sudo apt install -y $tools_to_install >/dev/null 2>&1"
                ;;
            "rhel")
                install_commands="sudo yum install -y $tools_to_install >/dev/null 2>&1"
                ;;
            "fedora")
                install_commands="sudo dnf install -y $tools_to_install >/dev/null 2>&1"
                ;;
            "alpine")
                install_commands="sudo apk update >/dev/null 2>&1 && sudo apk add $tools_to_install >/dev/null 2>&1"
                ;;
            *)
                echo -e "${YELLOW}警告: 未知系统类型，无法自动安装工具${NC}"
                return 1
                ;;
        esac
        
        # 执行安装命令
        if ssh "$remote_host" -p "$remote_port" "$install_commands" 2>/dev/null; then
            echo -e "${GREEN}✓ 远程优化工具安装成功${NC}"
        else
            echo -e "${YELLOW}警告: 远程工具安装失败，可能需要手动安装或权限不足${NC}"
            echo -e "${GRAY}提示: 在远程服务器手动执行: $install_commands${NC}"
        fi
    else
        echo -e "${GREEN}✓ 远程服务器优化工具已就绪${NC}"
    fi
}

# 上传远程脚本函数
function upload_remote_script() {
    local remote_host="$1"
    local remote_port="$2"
    local remote_script_path="/tmp/remote-sync-helper.sh"
    
    echo -e "${CYAN}上传远程助手脚本到 $remote_host:$remote_port...${NC}"
    
    # 检查本地远程脚本是否存在
    if [ ! -f "$REMOTE_HELPER_SCRIPT" ]; then
        echo -e "${RED}错误: 找不到远程助手脚本 $REMOTE_HELPER_SCRIPT${NC}"
        return 1
    fi
    
    # 测试SSH连接
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$remote_host" -p "$remote_port" "echo 'SSH连接测试成功'" 2>/dev/null; then
        echo -e "${RED}错误: 无法连接到远程服务器 $remote_host:$remote_port${NC}"
        echo -e "${YELLOW}请检查:${NC}"
        echo -e "${WHITE}  1. 服务器地址和端口是否正确${NC}"
        echo -e "${WHITE}  2. SSH密钥是否已配置${NC}"
        echo -e "${WHITE}  3. 网络连接是否正常${NC}"
        return 1
    fi
    
    # 上传脚本
    if scp -P "$remote_port" "$REMOTE_HELPER_SCRIPT" "$remote_host:$remote_script_path" 2>/dev/null; then
        # 设置执行权限
        if ssh "$remote_host" -p "$remote_port" "chmod +x $remote_script_path" 2>/dev/null; then
            echo -e "${GREEN}✓ 远程助手脚本上传成功${NC}"
            return 0
        else
            echo -e "${RED}错误: 无法设置远程脚本执行权限${NC}"
            return 1
        fi
    else
        echo -e "${RED}错误: 远程脚本上传失败${NC}"
        return 1
    fi
}

# 安装文件同步服务
function install_file_sync_service() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] 开始安装文件同步服务..." >> "$SCRIPT_DIR/service.log"
    
    # 步骤1: 加载配置
    echo ""
    echo -e "${CYAN}步骤1: 加载配置文件${NC}"
    
    # 使用导入的配置函数
    if ! load_cached_config; then
        load_config
    fi
    
    # 步骤2: 检查远程服务器优化工具
    echo ""
    echo -e "${CYAN}步骤2: 检查远程服务器优化工具${NC}"
    
    if [ -n "$REMOTE_HOST" ]; then
        check_and_install_remote_tools "$REMOTE_HOST" "$REMOTE_PORT" "$REMOTE_OS"
    else
        echo -e "${YELLOW}跳过远程工具检查（无有效配置）${NC}"
    fi
    
    # 步骤3: 上传远程助手脚本
    echo ""
    echo -e "${CYAN}步骤3: 上传远程助手脚本${NC}"
    
    if [ -n "$REMOTE_HOST" ]; then
        if upload_remote_script "$REMOTE_HOST" "$REMOTE_PORT"; then
            echo -e "${GREEN}✓ 远程脚本上传完成${NC}"
        else
            echo -e "${YELLOW}警告: 远程脚本上传失败，服务仍可正常安装${NC}"
            echo -e "${YELLOW}首次运行时会自动上传远程脚本${NC}"
        fi
    else
        echo -e "${YELLOW}跳过远程脚本上传（无有效配置）${NC}"
    fi
    
    # 步骤4: 创建systemd服务
    echo ""
    echo -e "${CYAN}步骤4: 创建systemd服务${NC}"
    
    # 服务配置
    local SERVICE_NAME="file-sync-service"
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    local LOG_FILE="$SCRIPT_DIR/service.log"
    
    # 创建systemd服务文件
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=File Sync Service
After=network.target

[Service]
Type=simple
User=$SUDO_USER
Group=$SUDO_USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SYNC_SCRIPT
Restart=always
RestartSec=10
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF
    
    # 设置脚本执行权限
    chmod +x "$SYNC_SCRIPT"
    
    # 重新加载systemd配置
    systemctl daemon-reload
    
    # 启用服务开机自启
    systemctl enable "$SERVICE_NAME"
    
    echo "[$timestamp] 服务安装成功！已创建开机自启动服务。" >> "$LOG_FILE"
    echo "[$timestamp] 服务名称: $SERVICE_NAME" >> "$LOG_FILE"
    echo "[$timestamp] 服务文件: $SERVICE_FILE" >> "$LOG_FILE"
    
    echo -e "${GREEN}✓ systemd服务创建完成${NC}"
    return 0
}

# 显示当前配置
echo ""
echo -e "${CYAN}当前配置预览:${NC}"
head -20 "$SYNC_SCRIPT" | grep -E '^[A-Z_]+=.*' | while read line; do
    echo -e "${WHITE}  $line${NC}"
done

echo ""
echo -e "${WHITE}确认安装并设置开机自启? (Y/N): ${NC}"
read -r confirm

if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${GREEN}开始安装服务...${NC}"
    
    # 检查是否需要sudo权限
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}需要sudo权限来安装系统服务${NC}"
        echo -e "${YELLOW}请输入sudo密码...${NC}"
        
        # 使用sudo重新运行当前脚本
        exec sudo "$0" "$@"
    fi
    
    # 以下代码以root权限运行
    install_file_sync_service
    
    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}启动服务...${NC}"
        systemctl start file-sync-service
        
        echo ""
        echo -e "${GREEN}检查服务状态...${NC}"
        systemctl status file-sync-service --no-pager -l
        
        echo ""
        echo -e "${GREEN}=== 安装完成 ===${NC}"
        echo -e "${WHITE}服务已安装并启动，将在下次开机时自动启动${NC}"
        echo ""
        echo -e "${CYAN}常用命令:${NC}"
        echo -e "${WHITE}  查看状态: ./sync-service.sh status${NC}"
        echo -e "${WHITE}  停止服务: ./sync-service.sh stop${NC}"
        echo -e "${WHITE}  启动服务: ./sync-service.sh start${NC}"
        echo -e "${WHITE}  重启服务: ./sync-service.sh restart${NC}"
        echo -e "${WHITE}  查看日志: ./sync-service.sh logs${NC}"
        echo -e "${WHITE}  实时日志: ./sync-service.sh logs-f${NC}"
        echo -e "${WHITE}  卸载服务: sudo ./sync-service.sh uninstall${NC}"
        echo ""
        echo -e "\033[0;37m日志文件: service.log\033[0m"
    else
        echo -e "${RED}安装失败${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}安装已取消${NC}"
fi

echo ""
echo -e "${WHITE}按任意键退出...${NC}"
read -n 1 -s 