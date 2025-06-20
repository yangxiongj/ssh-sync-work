
# 远程开发轻量级实现

一个基于Git的智能增量同步工具，只同步未提交到远程的更改，避免全量同步。适用于WSL Ubuntu环境。

## 功能特性

✅ **Git增量同步** - 只同步未提交的更改，避免全量传输  
✅ **智能远程更新** - 自动在远程回滚本地修改并拉取最新版本  
✅ **开机自动启动** - 通过systemd服务实现  
✅ **后台静默运行** - systemd守护进程管理  
✅ **进程监控** - systemd自动监控和恢复同步进程  
✅ **灵活的排除规则** - 可配置的文件/目录排除  
✅ **详细的日志记录** - 完整的操作日志  
✅ **WSL路径支持** - 自动处理Windows到Linux路径映射  
✅ **行结束符处理** - 自动配置Git处理CRLF/LF转换，避免跨平台问题  

## 环境要求

- WSL Ubuntu (或其他支持systemd的Linux发行版)
- Git (版本控制系统)
- rsync (文件同步工具)
- openssh-client (SSH客户端)
- systemd (服务管理)
- 本地目录必须是Git仓库

## 文件说明

- `sync-files.sh` - 主同步脚本
- `sync-service.sh` - 服务管理脚本
- `install.sh` - 一键安装脚本
- `service.log` - 服务运行日志
- `service.pid` - 进程ID文件

## 快速开始

### 1. 配置同步参数

编辑 `sync-files.sh` 中的配置：

```bash
# 基础配置
REMOTE_HOST="127.0.0.1"                    # 远程服务器IP
REMOTE_PORT="22"                           # SSH端口
LOCAL_DIRS=(                               # 本地Git仓库目录列表 (WSL路径)
    "/mnt/d/PycharmProjects/searxng" 
    "/mnt/d/PycharmProjects/fast-crawler"
)
REMOTE_DIR="/root/work"                    # 远程目标目录
REFRESH_INTERVAL=60                        # 同步间隔(秒)

# Git配置
AUTO_CRLF_CONFIG=true                      # 自动配置Git处理行结束符
```

**重要说明：** 
- 所有 `LOCAL_DIRS` 中的目录必须是Git仓库
- 远程服务器上的对应目录也会被初始化为Git仓库
- 只有包含未提交更改的仓库才会被同步

### 2. 一键安装

运行安装脚本：

```bash
chmod +x install.sh
./install.sh
```

### 3. 手动管理服务

```bash
# 安装开机自启服务 (需要sudo)
sudo ./sync-service.sh install

# 启动服务
./sync-service.sh start

# 查看服务状态
./sync-service.sh status

# 停止服务
./sync-service.sh stop

# 重启服务
./sync-service.sh restart

# 查看日志
./sync-service.sh logs

# 实时查看日志
./sync-service.sh logs-f

# 卸载服务 (需要sudo)
sudo ./sync-service.sh uninstall
```

## Git增量同步工作原理

### 同步流程

#### 初始同步（远程项目不存在时）
1. **检查本地仓库** - 验证目录是否为Git仓库
2. **检测远程项目** - 检查远程目录是否存在项目
3. **创建压缩包** - 将整个项目压缩（排除.git和配置的排除项）
4. **传输项目** - 将压缩包传输到远程服务器
5. **远程初始化** - 解压并初始化Git仓库，创建初始提交

#### 增量同步（远程项目已存在时）
1. **检测需要同步的更改** - 检查：
   - 未推送到远程分支的提交
   - 未提交的修改、暂存文件
   - 未跟踪的新文件
2. **远程更新** - 在远程执行：
   - `git checkout .` - 回滚所有本地修改
   - `git clean -fd` - 清理未跟踪文件
   - `git pull origin <branch>` - 拉取最新版本
3. **增量同步** - 只同步有变化的文件（未推送提交 + 未提交更改）
4. **完成同步** - 远程仓库获得最新代码 + 本地所有更改

### 同步的文件类型
- **已修改文件** (`git diff --name-only`) - 工作区修改但未暂存
- **已暂存文件** (`git diff --cached --name-only`) - 已暂存但未提交  
- **未跟踪文件** (`git ls-files --others --exclude-standard`) - 新文件但未加入Git
- **未推送提交中的文件** (`git diff --name-only origin/branch..HEAD`) - 已提交但未推送到远程

### 优势
- **智能初始化** - 首次同步时自动压缩传输整个项目
- **高效传输** - 后续只传输有变化的文件
- **保持同步** - 远程始终基于最新版本
- **避免冲突** - 自动处理远程修改冲突
- **智能检测** - 无更改时跳过同步
- **压缩传输** - 初始同步使用压缩包，减少传输时间

## 排除规则配置

在 `sync-files.sh` 中的 `EXCLUDE_PATTERNS` 数组中配置排除规则：

```bash
EXCLUDE_PATTERNS=(
    '.git'
    '__pycache__'
    'node_modules'
    'target'        # Java编译目录
    'build'         # 通用构建目录
    'dist'          # 分发目录
    # 添加更多规则...
)
```

## WSL路径说明

在WSL环境中，Windows磁盘挂载在 `/mnt/` 目录下：

- `C:\` → `/mnt/c/`
- `D:\` → `/mnt/d/`
- `D:\PycharmProjects\test` → `/mnt/d/PycharmProjects/test`

## 行结束符处理

### 自动配置
脚本会自动配置Git来正确处理跨平台的行结束符问题：

- **Git配置**: 设置`core.autocrlf=input`和`core.safecrlf=warn`
- **`.gitattributes`文件**: 自动创建详细的文件类型规则
- **特殊处理**: `.po`文件强制使用LF结束符

### 配置说明
```bash
AUTO_CRLF_CONFIG=true   # 启用自动配置
AUTO_CRLF_CONFIG=false  # 禁用自动配置，使用现有设置
```

### 解决的问题
- ❌ `warning: CRLF will be replaced by LF`
- ❌ 跨平台文件格式不一致
- ❌ Git提交时的行结束符警告

## 服务管理

### systemd服务
服务安装后会创建 `/etc/systemd/system/file-sync-service.service` 文件，通过systemd管理：

```bash
# 查看服务状态
systemctl status file-sync-service

# 查看服务日志
journalctl -u file-sync-service -f

# 手动启动/停止
systemctl start file-sync-service
systemctl stop file-sync-service
```

### 日志查看

服务运行日志保存在 `service.log` 文件中：

```bash
# 查看最新日志
tail -f service.log

# 查看最近50行日志
tail -n 50 service.log
```

## 故障排除

### 依赖安装
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install git rsync openssh-client

# CentOS/RHEL
sudo yum install git rsync openssh-clients
```

### 服务无法启动
1. 检查脚本执行权限：`chmod +x sync-files.sh`
2. 确认SSH连接正常：`ssh user@host -p port`
3. 查看服务日志：`./sync-service.sh logs`

### 同步失败
1. 检查网络连接
2. 确认SSH密钥配置正确
3. 验证远程目录权限
4. 检查本地目录路径是否正确

### WSL相关问题
1. 确认WSL版本支持systemd
2. 检查Windows路径映射是否正确
3. 验证文件权限设置

## 卸载

```bash
# 停止并卸载服务
sudo ./sync-service.sh uninstall

# 清理文件
rm -f service.log service.pid
```

## 注意事项

1. **SSH配置** - 确保已配置SSH密钥认证，避免密码提示
2. **网络稳定性** - 建议在稳定的网络环境下使用
3. **磁盘空间** - 确保远程服务器有足够的存储空间
4. **权限管理** - 安装和卸载服务需要sudo权限
5. **WSL systemd** - 确保WSL配置支持systemd服务

## WSL systemd 配置

如果WSL不支持systemd，需要启用：

```bash
# 编辑WSL配置
sudo vim /etc/wsl.conf

# 添加以下内容
[boot]
systemd=true

# 重启WSL
# 在Windows PowerShell中执行：wsl --shutdown
```

## 技术支持

如遇问题，请检查：
1. WSL和systemd配置
2. 脚本执行权限
3. 网络连接状态
4. 服务日志文件内容 