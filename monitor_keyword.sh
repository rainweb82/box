#!/bin/bash

# 从环境变量中读取参数
URL=${URL}
KEYWORD=${KEYWORD}
INTERVAL=${INTERVAL:-60}         # 默认检查间隔为60秒
BOT_TOKEN=${YGN_BOT_TOKEN}
CHAT_ID=${TG_USER_ID}

# 检查环境变量是否设置
if [[ -z "$URL" || -z "$KEYWORD" || -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
  echo "请在青龙面板上设置环境变量：URL、KEYWORD、INTERVAL（可选）、BOT_TOKEN 和 CHAT_ID"
  exit 1
fi

FAIL_COUNT=0  # 计数连续失败次数

# 发送 Telegram 通知的函数
send_telegram_notification() {
  MESSAGE="警告：在 $URL 中连续三次检测不到关键词 '$KEYWORD'。"
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
       -d chat_id="$CHAT_ID" \
       -d text="$MESSAGE"
}

# 持续监测关键词
while true; do
  echo "检查中：$URL 中是否包含关键词 '$KEYWORD'..."

  # 使用 curl 获取网页内容并检查关键词
  content=$(curl -s "$URL")
  if echo "$content" | grep -q "$KEYWORD"; then
    echo "关键词 '$KEYWORD' 存在于网页 $URL 中。"
    FAIL_COUNT=0  # 重置计数器
  else
    echo "关键词 '$KEYWORD' 不存在于网页 $URL 中。"
    FAIL_COUNT=$((FAIL_COUNT + 1))  # 增加计数器
  fi

  # 检查是否连续三次失败
  if [ "$FAIL_COUNT" -ge 3 ]; then
    echo "连续三次检测不到关键词，发送 Telegram 通知..."
    send_telegram_notification
    FAIL_COUNT=0  # 发送通知后重置计数器
  fi

  # 等待指定的时间间隔
  sleep "$INTERVAL"
done
