#!/bin/bash

# 从环境变量中读取多个 URL 和关键词（用逗号分隔）
URLS=${URLS}
KEYWORDS=${KEYWORDS}
INTERVAL=${INTERVAL:-60}         # 默认检查间隔为60秒
BOT_TOKEN=${YGN_BOT_TOKEN}
CHAT_ID=${TG_USER_ID}

# 使用公共 API 查询当前 IP 地址和归属地信息
response=$(curl -s https://ipinfo.io)

# 输出查询结果
echo "当前 IP 归属地信息："
echo "$response"

# 检查环境变量是否设置
if [[ -z "$URLS" || -z "$KEYWORDS" || -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
  echo "请在青龙面板上设置环境变量：URLS、KEYWORDS、INTERVAL（可选）、BOT_TOKEN 和 CHAT_ID"
  exit 1
fi

# 将 URL 和关键词分割成数组
IFS=',' read -r -a URL_ARRAY <<< "$URLS"
IFS=',' read -r -a KEYWORD_ARRAY <<< "$KEYWORDS"

# 确保 URL 和关键词数量匹配
if [ "${#URL_ARRAY[@]}" -ne "${#KEYWORD_ARRAY[@]}" ]; then
  echo "错误：URL 和关键词数量不匹配，请确保 URLS 和 KEYWORDS 中的项数相同。"
  exit 1
fi

# 初始化每个 URL 的失败计数
FAIL_COUNT_ARRAY=()
for ((i=0; i<${#URL_ARRAY[@]}; i++)); do
  FAIL_COUNT_ARRAY[i]=0
done

# 发送 Telegram 通知的函数
send_telegram_notification() {
  local index=$1
  local keyword=$2
  MESSAGE="警告：第 $index 个 URL 连续三次检测不到关键词 '$keyword'。"
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
       -d chat_id="$CHAT_ID" \
       -d text="$MESSAGE"
}

# 持续监测每个 URL 的关键词
while true; do
  for ((i=0; i<${#URL_ARRAY[@]}; i++)); do
    URL=${URL_ARRAY[i]}
    KEYWORD=${KEYWORD_ARRAY[i]}
    
    echo "检查中：$URL 中是否包含关键词 '$KEYWORD'..."

    # 使用 curl 获取网页内容并检查关键词
    content=$(curl -s -L "$URL")
    if echo "$content" | grep -q "$KEYWORD"; then
      echo "关键词 '$KEYWORD' 存在于网页 $URL 中。"
      FAIL_COUNT_ARRAY[i]=0  # 重置计数器
    else
      echo "关键词 '$KEYWORD' 不存在于网页 $URL 中。"
      FAIL_COUNT_ARRAY[i]=$((FAIL_COUNT_ARRAY[i] + 1))  # 增加计数器
    fi

    # 检查是否连续三次失败
    if [ "${FAIL_COUNT_ARRAY[i]}" -ge 3 ]; then
      echo "连续三次检测不到关键词，发送 Telegram 通知..."
      send_telegram_notification "$((i + 1))" "$KEYWORD"  # 发送当前域名的索引（从1开始）
      FAIL_COUNT_ARRAY[i]=0  # 发送通知后重置计数器
    fi
  done

  # 等待指定的时间间隔
  sleep "$INTERVAL"
done
