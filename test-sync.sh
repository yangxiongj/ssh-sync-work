#!/bin/bash

# 简单的同步功能测试脚本
# 使用方法: ./test-sync.sh [测试目录] [保留文件] [本地哈希] [分支名] [排除模式]

# 默认参数
TEST_DIR="${1:-/root/work/searxng}"
KEEP_FILES="${2:-}"
LOCAL_HASH="${3:-0d747837634b17ca0623888414dc842de9355604}"
BRANCH_NAME="${4:-master}"
EXCLUDE_PATTERNS="${5:-\.log$|\.tmp$}"

echo "========================================="
echo "测试 remote-sync-helper.sh 同步功能"
echo "========================================="
echo "测试目录: $TEST_DIR"
echo "保留文件: $KEEP_FILES"
echo "本地哈希: $LOCAL_HASH"
echo "分支名称: $BRANCH_NAME"
echo "排除模式: $EXCLUDE_PATTERNS"
echo "========================================="

# 检查测试目录
echo "1. 检查测试目录..."
if [ ! -d "$TEST_DIR" ]; then
    echo "错误: 测试目录 $TEST_DIR 不存在"
    exit 1
fi

cd "$TEST_DIR"

# 检查是否为git仓库
if [ ! -d ".git" ]; then
    echo "错误: $TEST_DIR 不是git仓库"
    exit 1
fi

echo "当前目录状态:"
echo "分支: $(git branch --show-current 2>/dev/null || echo '未知')"
echo "哈希: $(git rev-parse HEAD 2>/dev/null || echo '未知')"

# 获取初始哈希（如果没有提供）
if [ -z "$LOCAL_HASH" ]; then
    LOCAL_HASH=$(git rev-parse HEAD)
    echo "使用当前哈希: $LOCAL_HASH"
fi

# 显示当前文件状态
echo "2. 当前文件状态..."
echo "Git状态:"
git status --porcelain

echo "现有文件:"
ls -la

# 执行同步测试
echo ""
echo "3. 执行同步测试..."
echo "命令: /tmp/remote-sync-helper.sh sync_version \"$TEST_DIR\" \"$KEEP_FILES\" \"$LOCAL_HASH\" \"$BRANCH_NAME\" \"$EXCLUDE_PATTERNS\""
echo ""

# 回到原目录执行脚本
cd - >/dev/null

# 执行同步
result=$(/tmp/remote-sync-helper.sh sync_version "$TEST_DIR" "$KEEP_FILES" "$LOCAL_HASH" "$BRANCH_NAME" "$EXCLUDE_PATTERNS")

echo "原始输出: $result"
echo ""

# 转换为中文输出
echo "同步结果解释:"
echo "$result" | while IFS= read -r line; do
    case "$line" in
        "REMOTE_STATUS:"*)
            branch=$(echo "$line" | cut -d: -f2)
            hash=$(echo "$line" | cut -d: -f3)
            echo "  📍 远程状态: 分支[$branch] 哈希[${hash:0:8}...]"
            ;;
        "HASH_MATCH")
            echo "  ✅ 哈希匹配: 本地和远程版本一致，无需同步"
            ;;
        "REMOTE_NEWER")
            echo "  ⬆️  远程更新: 远程版本比本地新，保持远程版本"
            ;;
        "PULLING_TO_LOCAL_HASH")
            echo "  ⬇️  拉取更新: 正在拉取到本地指定版本"
            ;;
        "BRANCH_DIVERGED_RESETTING")
            echo "  🔄 分支分叉: 检测到分支分叉，强制重置到目标版本"
            ;;
        "BRANCH_MISMATCH_SWITCHING")
            echo "  🔀 分支切换: 分支不匹配，切换到目标分支"
            ;;
        "HASH_NOT_FOUND")
            echo "  ❌ 哈希未找到: 目标哈希在仓库中不存在"
            ;;
        "RESET_FAILED")
            echo "  ❌ 重置失败: 无法重置到目标版本"
            ;;
        "NO_REMOTE_ORIGIN")
            echo "  ⚠️  无远程源: 仓库没有配置origin远程源"
            ;;
        "NOT_GIT_REPO")
            echo "  ❌ 非Git仓库: 目标目录不是Git仓库"
            ;;
        "SYNC_COMPLETED")
            echo "  ✅ 同步完成: 同步流程已完成"
            ;;
        "ERROR:"*)
            echo "  ❌ 错误: $line"
            ;;
        "")
            # 跳过空行
            ;;
        *)
            echo "  ℹ️  其他: $line"
            ;;
    esac
done
echo ""

# 检查同步后的状态
echo "4. 检查同步后状态..."
cd "$TEST_DIR"

echo "当前分支: $(git branch --show-current)"
echo "当前哈希: $(git rev-parse HEAD)"
echo "文件状态:"
ls -la

echo ""
echo "文件内容检查:"
echo "file1.txt: $(cat file1.txt 2>/dev/null || echo '文件不存在')"
echo "keep.txt: $(cat keep.txt 2>/dev/null || echo '文件不存在')"
echo "test.log: $(cat test.log 2>/dev/null || echo '文件不存在')"
echo "important.log: $(cat important.log 2>/dev/null || echo '文件不存在')"

cd - >/dev/null

echo ""
echo "========================================="
echo "测试完成！"
echo "========================================="

# 注意：测试完成，目录保持不变 