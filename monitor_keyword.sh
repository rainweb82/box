#!/bin/bash

# 从环境变量中读取多个 URL 和关键词（用逗号分隔）
URLS=${URLS}
KEYWORDS=${KEYWORDS}
INTERVAL=${INTERVAL:-60}         # 默认检查间隔为60秒
DAILY_NOTIFICATION_TIME=${DAILY_NOTIFICATION_TIME:-"10:00"}  # 默认通知时间为10:00
BOT_TOKEN=${YGN_BOT_TOKEN}
CHAT_ID=${TG_USER_ID}

# 使用公共 API 查询当前 IP 地址和归属地信息，并格式化输出
response=$(curl -s https://ipinfo.io)
formatted_response=$(echo "$response" | jq -r '[
  "IP地址: " + .ip,
  "城市: " + (.city // "未知"),
  "地区: " + (.region // "未知"),
  "国家: " + .country,
  "邮政编码: " + (.postal // "未知"),
  "位置: " + .loc,
  "组织: " + (.org // "未知")
] | .[]')

# 输出查询结果
echo "当前 IP 归属地信息："
echo "$formatted_response"

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

# 初始化每个 URL 的失败计数、最终 URL 地址、初始检查标记，以及每日统计计数
FAIL_COUNT_ARRAY=()
PREV_FINAL_URL_ARRAY=()
INITIAL_CHECK_DONE=()
KEYWORD_PRESENT_COUNT=()
KEYWORD_ABSENT_COUNT=()

for ((i=0; i<${#URL_ARRAY[@]}; i++)); do
  FAIL_COUNT_ARRAY[i]=0
  PREV_FINAL_URL_ARRAY[i]=""
  INITIAL_CHECK_DONE[i]=0
  KEYWORD_PRESENT_COUNT[i]=0
  KEYWORD_ABSENT_COUNT[i]=0
done

# 提取 URL 的域名部分
get_domain() {
  local url=$1
  echo "$url" | awk -F[/:] '{print $4}'
}

# 检查域名是否变化
check_domain_change() {
  local index=$1
  local final_url=$2
  local prev_url=${PREV_FINAL_URL_ARRAY[index]}
  
  # 提取当前和前一次的域名
  local current_domain=$(get_domain "$final_url")
  local prev_domain=$(get_domain "$prev_url")
  
  # 初次检查时只更新记录，不发送通知
  if [[ "${INITIAL_CHECK_DONE[index]}" -eq 0 ]]; then
    PREV_FINAL_URL_ARRAY[index]="$final_url"
    INITIAL_CHECK_DONE[index]=1
  elif [[ "$current_domain" != "$prev_domain" ]]; then
    echo "域名已变更，发送 Telegram 通知..."
    send_telegram_notification "警告：第 $((index + 1)) 个 URL 的域名已从 '$prev_domain' 变为 '$current_domain'。"
    PREV_FINAL_URL_ARRAY[index]="$final_url"  # 更新为新的最终地址
  fi
}

# 发送 Telegram 通知的函数
send_telegram_notification() {
  local message=$1
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
       -d chat_id="$CHAT_ID" \
       -d text="$message"
}

# 每日统计发送
send_daily_summary() {
  local message="每日监测统计："
  for ((i=0; i<${#URL_ARRAY[@]}; i++)); do
    message+="\n第 $((i + 1)) 个 URL (${URL_ARRAY[i]}): 有关键词次数：${KEYWORD_PRESENT_COUNT[i]}，无关键词次数：${KEYWORD_ABSENT_COUNT[i]}"
    KEYWORD_PRESENT_COUNT[i]=0  # 重置计数
    KEYWORD_ABSENT_COUNT[i]=0    # 重置计数
  done
  send_telegram_notification "$message"
}

# 持续监测每个 URL 的关键词和最终地址变化
while true; do
  for ((i=0; i<${#URL_ARRAY[@]}; i++)); do
    URL=${URL_ARRAY[i]}
    KEYWORD=${KEYWORD_ARRAY[i]}
    
    echo "$(date +%H:%M:%S) 检查中..."

    # 使用 curl 获取网页内容并检查关键词
    content=$(curl -s -L "$URL")
    if echo "$content" | grep -q "$KEYWORD"; then
      echo "关键词 '$KEYWORD' 存在于网页 $URL 中。"
      FAIL_COUNT_ARRAY[i]=0  # 重置计数器
      KEYWORD_PRESENT_COUNT[i]=$((KEYWORD_PRESENT_COUNT[i] + 1))  # 有关键词计数
    else
      echo "关键词 '$KEYWORD' 不存在于网页 $URL 中。"
      FAIL_COUNT_ARRAY[i]=$((FAIL_COUNT_ARRAY[i] + 1))  # 增加计数器
      KEYWORD_ABSENT_COUNT[i]=$((KEYWORD_ABSENT_COUNT[i] + 1))  # 无关键词计数
    fi

    # 检查是否连续三次失败
    if [ "${FAIL_COUNT_ARRAY[i]}" -ge 3 ]; then
      echo "连续三次检测不到关键词，发送 Telegram 通知..."
      send_telegram_notification "警告：第 $((i + 1)) 个 URL 连续三次检测不到关键词 '$KEYWORD'。"
      FAIL_COUNT_ARRAY[i]=0  # 发送通知后重置计数器
    fi

    # 检查最终地址的域名是否变化
    FINAL_URL=$(curl -Ls -o /dev/null -w %{url_effective} "$URL")
    check_domain_change "$i" "$FINAL_URL"
  done

  # 检查当前时间是否与每日通知时间一致
  if [[ "$(date +%H:%M)" == "$DAILY_NOTIFICATION_TIME" ]]; then
    send_daily_summary  # 发送每日统计
    sleep 60  # 防止在一分钟内多次发送
  fi

  # 等待指定的时间间隔
  sleep "$INTERVAL"
done
