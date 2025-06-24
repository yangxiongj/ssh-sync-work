# Git增量文件同步服务

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
✅ **配置热更新** - 配置文件支持热更新，无需重启服务  
✅ **等待模式** - 当没有配置同步目录时自动进入等待模式  
✅ **灵活配置文件** - 支持自定义配置文件路径  
✅ **配置缓存管理** - 智能配置缓存，提升性能  

## 环境要求

- WSL Ubuntu (或其他支持systemd的Linux发行版)
- Git (版本控制系统)
- rsync (文件同步工具)
- openssh-client (SSH客户端)
- systemd (服务管理)
- 本地目录必须是Git仓库

## 文件说明

### 核心脚本
- `sync-files.sh` - 主同步脚本
- `remote-sync-helper.sh` - 远程助手脚本
- `sync-service.sh` - 服务管理脚本，支持配置管理
- `install.sh` - 一键安装脚本，支持自定义配置文件
- `sync.yaml` - 默认配置文件

### 文档
- `使用手册.md` - 完整的使用指南和故障排除
- `项目伪代码说明.md` - 系统算法和工作流程说明
- `技术实现文档.md` - 详细的技术实现细节

### 运行时文件
- `.sync-env` - 环境变量文件
- `/tmp/sync_config_cache` - 配置缓存文件

## 快速开始

### 1. 配置同步参数

编辑 `sync.yaml` 配置文件：

```yaml
# 远程服务器配置
remote:
  host: 34.68.158.244
  port: 22
  dir: /root/work
  os: ubuntu

# 同步目录配置
# 注意: 当此配置项被注释或为空时，服务将进入等待状态
# 取消注释并添加至少一个目录路径后，服务将自动开始同步
directories:
- /mnt/d/PycharmProjects/test

# 调试模式
debug_mode: false

# 刷新间隔 (秒)
refresh_interval: 10

# 配置更新检测间隔 (秒)
config_check_interval: 10

# 排除模式配置
exclude_patterns:
  - .git
  - .idea
  - __pycache__
  - node_modules

# 日志配置
logs:
  dir: /tmp/sync
  max_days: 7
  max_size: 10
```

**重要说明：** 
- 所有 `directories` 中的目录必须是Git仓库
- 远程服务器上的对应目录也会被初始化为Git仓库
- 只有包含未提交更改的仓库才会被同步
- 配置文件支持热更新，修改后会在下一个检查周期自动加载
- 当 `directories` 配置项被注释或为空时，服务将进入等待状态
- 配置文件中的所有设置都以配置文件为最高优先级

### 2. 一键安装

#### 使用默认配置文件安装：
```bash
chmod +x install.sh
sudo ./install.sh
```

#### 使用自定义配置文件安装：
```bash
chmod +x install.sh
sudo ./install.sh /path/to/your/sync.yaml
```

### 3. 服务管理

```bash
# 安装开机自启服务 (需要sudo)
sudo ./sync-service.sh install

# 启动服务
./sync-service.sh start

# 查看服务状态和配置信息
./sync-service.sh status

# 查看当前配置
./sync-service.sh config

# 刷新配置缓存
./sync-service.sh refresh-config

# 停止服务
./sync-service.sh stop

# 重启服务
./sync-service.sh restart

# 实时查看systemd日志
./sync-service.sh logs-f

# 卸载服务 (需要sudo)
sudo ./sync-service.sh uninstall
```

### 4. 配置管理

系统提供了强大的配置管理功能：

#### 配置优先级
1. **配置文件** (最高优先级)
2. 环境变量
3. 默认值

#### 配置缓存
- 系统会自动缓存配置以提升性能
- 配置文件更新时会自动刷新缓存
- 可以手动刷新配置缓存：`./sync-service.sh refresh-config`

#### 配置验证
- 启动服务时会自动验证配置文件
- 提供详细的配置状态信息
- 配置错误时会显示明确的错误信息

## Git增量同步工作原理

### 同步流程

#### 初始同步（远程项目不存在时）
1. **检查本地仓库** - 验证目录是否为Git仓库
2. **检测远程项目** - 检查远程目录是否存在项目
3. **创建压缩包** - 将整个项目压缩（包含.git目录以保持Git历史）
4. **传输项目** - 将压缩包传输到远程服务器
5. **远程解压** - 解压项目文件，保持完整的Git历史

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
- **保持Git历史** - 首次同步时传输完整的Git仓库，保持版本历史一致性
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

### 配置热更新

配置文件 `sync.yaml` 支持热更新，无需重启服务：

1. 编辑 `sync.yaml` 文件
2. 保存更改
3. 系统会在下一个检查周期自动加载新配置（默认10秒）

### 等待模式

当 `directories` 配置项被注释或为空时，服务将进入等待模式：

1. 服务会继续运行，但不会执行同步操作
2. 日志中会显示 "等待配置目录更新" 的信息
3. 服务状态会显示为 "等待配置"
4. 取消注释并添加至少一个目录路径后，服务将自动开始同步

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

## 📚 文档说明

### 使用建议
- **新手用户**: 先阅读本README了解基本概念，然后查看`使用手册.md`进行安装和配置
- **故障排除**: 遇到问题时查看`使用手册.md`中的故障排除部分
- **深入理解**: 想了解系统工作原理，请阅读`项目伪代码说明.md`
- **技术细节**: 需要了解实现细节或进行二次开发，请查看`技术实现文档.md`

### 文档层次
1. **README.md** (本文件) - 项目概述和快速开始
2. **使用手册.md** - 完整的安装、配置、使用和故障排除指南
3. **项目伪代码说明.md** - 系统算法和工作流程的伪代码描述
4. **技术实现文档.md** - 详细的技术实现细节和API文档

## 技术支持

如遇问题，请按以下顺序查阅：
1. 查看`使用手册.md`中的故障排除部分
2. 检查服务日志文件内容：`./sync-service.sh logs`
3. 验证WSL和systemd配置
4. 确认脚本执行权限和网络连接状态 