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

# 配置文件路径
CONFIG_FILE="/mnt/d/sync.yaml"

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

echo -e "${GREEN}✓ 所有依赖检查通过${NC}"

# 读取配置文件函数
function read_config() {
    local remote_host=""
    local remote_port="22"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}警告: 配置文件不存在 $CONFIG_FILE${NC}"
        echo -e "${YELLOW}将使用默认配置进行远程脚本上传测试${NC}"
        remote_host="34.68.158.244"
        remote_port="22"
    else
        # 解析YAML配置
        local in_remote_section=false
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            
            if [[ "$line" =~ ^remote: ]]; then
                in_remote_section=true
                continue
            elif [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*: ]]; then
                in_remote_section=false
                continue
            fi
            
            if [ "$in_remote_section" = true ]; then
                if [[ "$line" =~ ^host:[[:space:]]*[\"\']*([^\"\']+)[\"\']*$ ]]; then
                    remote_host="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^port:[[:space:]]*([0-9]+) ]]; then
                    remote_port="${BASH_REMATCH[1]}"
                fi
            fi
        done < "$CONFIG_FILE"
    fi
    
    echo "$remote_host:$remote_port"
}

# 上传远程脚本函数
function upload_remote_script() {
    local remote_host="$1"
    local remote_port="$2"
    local remote_script_path="/tmp/remote-sync-helper.sh"
    
    echo -e "${CYAN}上传远程助手脚本到 $remote_host:$remote_port...${NC}"
    
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
    echo -e "${GREEN}开始安装...${NC}"
    
    # 上传远程助手脚本
    echo ""
    echo -e "${CYAN}步骤1: 上传远程助手脚本${NC}"
    config_info=$(read_config)
    remote_host="${config_info%%:*}"
    remote_port="${config_info##*:}"
    
    if [ -n "$remote_host" ]; then
        if upload_remote_script "$remote_host" "$remote_port"; then
            echo -e "${GREEN}✓ 远程脚本上传完成${NC}"
        else
            echo -e "${YELLOW}警告: 远程脚本上传失败，服务仍可正常安装${NC}"
            echo -e "${YELLOW}首次运行时会自动上传远程脚本${NC}"
        fi
    else
        echo -e "${YELLOW}跳过远程脚本上传（无有效配置）${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}步骤2: 安装系统服务${NC}"
    
    # 检查是否需要sudo权限
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}需要sudo权限来安装系统服务${NC}"
        echo -e "${YELLOW}请输入sudo密码...${NC}"
        
        # 安装服务
        sudo "$SERVICE_SCRIPT" install
        install_result=$?
        
        if [ $install_result -eq 0 ]; then
            echo ""
            echo -e "${GREEN}启动服务...${NC}"
            "$SERVICE_SCRIPT" start
            
            echo ""
            echo -e "${GREEN}检查服务状态...${NC}"
            "$SERVICE_SCRIPT" status
            
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
        # 以root权限运行
        "$SERVICE_SCRIPT" install
        install_result=$?
        
        if [ $install_result -eq 0 ]; then
            echo ""
            echo -e "${GREEN}启动服务...${NC}"
            "$SERVICE_SCRIPT" start
            
            echo ""
            echo -e "${GREEN}检查服务状态...${NC}"
            "$SERVICE_SCRIPT" status
            
            echo ""
            echo -e "${GREEN}=== 安装完成 ===${NC}"
            echo -e "${WHITE}服务已安装并启动，将在下次开机时自动启动${NC}"
        else
            echo -e "${RED}安装失败${NC}"
            exit 1
        fi
    fi
else
    echo -e "${YELLOW}安装已取消${NC}"
fi

echo ""
echo -e "${WHITE}按任意键退出...${NC}"
read -n 1 -s 