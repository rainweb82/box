#!/usr/bin/env bash
# cron:0 30 9 * * *
# new Env("域名检测任务")

# 从环境变量中读取多个 URL 和关键词
URLS=${URLS}                                                                   # 监测链接（用换行分隔）
KEYWORDS=${KEYWORDS}                                                           # 链接中需要包含的关键词（用换行分隔）
BOT_TOKEN=${YGN_BOT_TOKENS}                                                    # TG通知机器人token（用换行分隔）
CHAT_ID=${YGN_USER_IDS}                                                        # TG通知机器人id（用换行分隔）
INTERVAL=${INTERVAL:-60}                                                       # 默认检查间隔为60秒
FAIL_COUNT=${FAIL_COUNT:-3}                                                    # 连续错误触发通知次数，默认3次
CUMULATIVE_FAIL=${CUMULATIVE_FAIL:-5}                                          # 累计错误触发通知次数，默认5次
NEW_DOMAIN_NOTIFICATION_INTERVAL=${NEW_DOMAIN_NOTIFICATION_INTERVAL:-1800}     # 新域名通知间隔时间，默认30分钟
KNOWN_DOMAINS_FILE="known_domains.txt"                                         # 已知最终跳转域名列表（用换行分隔）

# 检查环境变量是否设置
if [[ -z "$URLS" || -z "$KEYWORDS" ]]; then
  echo "请在青龙面板上设置环境变量: URLS、KEYWORDS"
  exit 1
fi

# 确保 URL 和关键词数量匹配
if [ "${#URL_ARRAY[@]}" -ne "${#KEYWORD_ARRAY[@]}" ]; then
  echo "错误: URL 和关键词数量不匹配，请确保 URLS 和 KEYWORDS 中的项数相同。"
  exit 1
fi

# 确保通知机器人的 ID 和 TOKEN 数量匹配
if [ "${#CHAT_ID_ARRAY[@]}" -ne "${#BOT_TOKEN_ARRAY[@]}" ]; then
  echo "错误: URL 和关键词数量不匹配，请确保 YGN_USER_ID 和 YGN_BOT_TOKEN 中的项数相同。"
  exit 1
fi

# 将 URL 和关键词分割成数组
readarray -t URL_ARRAY <<< "$URLS"
readarray -t KEYWORD_ARRAY <<< "$KEYWORDS"
readarray -t CHAT_ID_ARRAY <<< "$CHAT_ID"
readarray -t BOT_TOKEN_ARRAY <<< "$BOT_TOKEN"

# 检查是否存在 known_domains.txt 文件
if [[ ! -f "$KNOWN_DOMAINS_FILE" ]]; then
  echo "警告: 文件 $KNOWN_DOMAINS_FILE 不存在，将跳过新域名的检测。"
  echo ""
  CHECK_NEW_DOMAINS_ENABLED=0  # 标志为不执行新域名检测
else
  CHECK_NEW_DOMAINS_ENABLED=1  # 标志为允许新域名检测
  # 读取已知域名到数组
  readarray -t DOMAIN_ARRAY < "$KNOWN_DOMAINS_FILE"
  # 打印当前已知域名列表
  echo "已知最终跳转后域名列表: "
  for domain in "${DOMAIN_ARRAY[@]}"; do
    echo "$domain"
  done
  echo ""
fi

# 初始化每个 URL 的失败计数、最终 URL 地址、每日统计计数和恢复通知标记
FAIL_COUNT_ARRAY=()
PREV_FINAL_URL_ARRAY=()
INITIAL_CHECK_DONE=()
KEYWORD_PRESENT_COUNT=()
KEYWORD_ABSENT_COUNT=()
KEYWORD_RECOVERY_NOTIFICATION_SENT=()
NEW_DOMAIN_NOTIFICATION_TIME=()
DAILY_NOTIFICATION_SENT=0  # 标志变量，记录是否已发送当日统计
LAST_NOTIFICATION_DATE=""  # 记录上次发送统计通知的日期
STARTUP_DONE=0  # 标志是否为脚本首次启动
NEW_DOMAINS_TO_NOTIFY=()  # 存储新发现的域名
CUMULATIVE_FAIL_COUNT=()  # 初始化累计失败计数数组
RUN_TIME=$(date +%s)  # 记录脚本的启动时间
MAX_RUNTIME=86300  # 设置24小时（86400秒）的运行时长
RECOVERY_NOTIFICATION_SENT_BY_DOMAIN=()  # 恢复通知标志（按域名区分）

for ((i=0; i<${#URL_ARRAY[@]}; i++)); do
  FAIL_COUNT_ARRAY[i]=0
  PREV_FINAL_URL_ARRAY[i]=""
  INITIAL_CHECK_DONE[i]=0
  KEYWORD_PRESENT_COUNT[i]=0
  KEYWORD_ABSENT_COUNT[i]=0
  KEYWORD_RECOVERY_NOTIFICATION_SENT[i]=0
  NEW_DOMAIN_NOTIFICATION_TIME[i]=0
  CUMULATIVE_FAIL_COUNT[i]=0  # 累计失败计数
  RECOVERY_NOTIFICATION_SENT_BY_DOMAIN[i]=""
done

# 使用公共 API 查询当前 IP 地址和归属地信息，并格式化输出
response=$(curl --max-time 30 -s https://ipinfo.io)
formatted_response=$(echo "$response" | jq -r '[
  "IP地址: " + .ip,
  "国家: " + .country,
  "城市: " + (.city // "未知"),
  "地区: " + (.region // "未知"),
  "运营商: " + (.org // "未知")
] | .[]')

# 输出查询结果
echo "当前 IP 归属地信息: "
echo "$formatted_response"
echo ""

# 输出当前检测的域名
echo "即将检测的 URL 和对应的域名: "
for ((i=0; i<${#URL_ARRAY[@]}; i++)); do
  echo "监测网址: URL$((i + 1))"
  echo "原始地址: ${URL_ARRAY[i]}"
  echo "监测关键词: ${KEYWORD_ARRAY[i]}"
  echo ""
done

# 提取 URL 的一级域名
get_domain() {
  local url=$1
  # 提取域名部分
  local domain=$(echo "$url" | awk -F[/:] '{print $4}')
  
  # 使用正则识别一级域名，适应常见的两级和三级域名
  if [[ "$domain" =~ ([^.]+\.[^.]+\.(com\.cn|net\.cn|org\.cn|gov\.cn|co\.uk|org\.uk|ac\.uk))$ ]]; then
    # 处理三级域名情况
    echo "${BASH_REMATCH[0]}"
  else
    # 处理两级域名
    echo "$domain" | awk -F. '{print $(NF-1)"."$NF}'
  fi
}

get_ip_info() {

  local response=$(curl --max-time 30 -s https://ipinfo.io)
  local ip=$(echo "$response" | jq -r '.ip')
  # 替换 IP 地址的最后一段为 "*"
  local masked_ip=$(echo "$ip" | awk -F. '{print $1"."$2"."$3".*"}')

  local formatted_response=$(echo "$response" | jq -r --arg masked_ip "$masked_ip" '[
    "IP地址: " + $masked_ip,
    "国家: " + .country,
    "城市: " + (.city // "未知"),
    "地区: " + (.region // "未知"),
    "运营商: " + (.org // "未知")
  ] | .[]')
  echo "$formatted_response"
}

# 发送 Telegram 通知的函数
send_telegram_notification() {
  local message=$1
  local ip_info=$(get_ip_info)
for ((j=0; j<${#BOT_TOKEN_ARRAY[@]}; j++)); do
echo "------------------------"
echo "$message"
echo
echo "当前 IP 归属地信息: "
echo "$ip_info"
echo "------------------------"
  curl -s --max-time 30 -o /dev/null -X POST "https://api.telegram.org/bot${BOT_TOKEN_ARRAY[j]}/sendMessage" \
       -d chat_id="${CHAT_ID_ARRAY[j]}" \
       -d text="$message

当前 IP 归属地信息: 
$ip_info"
done   
}

# 每日统计发送
send_daily_summary() {
  local message="每日监测统计: 
"
  for ((i=0; i<${#URL_ARRAY[@]}; i++)); do
    message+="第 $((i + 1)) 个 URL ${URL_ARRAY[i]}
监测到关键词: ${KEYWORD_PRESENT_COUNT[i]} 次，未检测到关键词: ${KEYWORD_ABSENT_COUNT[i]} 次"
    KEYWORD_PRESENT_COUNT[i]=0  # 重置计数
    KEYWORD_ABSENT_COUNT[i]=0    # 重置计数
  done
  send_telegram_notification "$message"
}

# 检查是否存在不在域名列表中的新域名
check_and_notify_new_domain() {
  local index=$1
  local current_domain=$2
  local current_time=$(date +%s)

  # 将新的域名列表文件内容重新读入数组
  readarray -t DOMAIN_ARRAY < "$KNOWN_DOMAINS_FILE"

  # 检查域名是否在已知列表中
  local is_known=0
  for domain in "${DOMAIN_ARRAY[@]}"; do
    if [[ "$domain" == "$current_domain" ]]; then
      is_known=1
      break
    fi
  done

  # 如果是新域名
  if [[ $is_known -eq 0 ]]; then
    # 将新域名添加到待通知列表
    if [[ ! " ${NEW_DOMAINS_TO_NOTIFY[*]} " =~ " ${current_domain} " ]]; then
      NEW_DOMAINS_TO_NOTIFY+=("$current_domain")
    fi
  fi

  # 检查是否需要发送新域名通知
  if [[ $is_known -eq 0 && ($((current_time - NEW_DOMAIN_NOTIFICATION_TIME[index])) -ge $NEW_DOMAIN_NOTIFICATION_INTERVAL || ${NEW_DOMAIN_NOTIFICATION_TIME[index]} -eq 0) ]]; then
    # 如果是新域名且第一次发现，或超过半小时没有发送通知
    local domains_to_notify="${NEW_DOMAINS_TO_NOTIFY[*]}"
    NEW_DOMAINS_TO_NOTIFY=()  # 清空待通知列表
    send_telegram_notification "【注意】: 检测到新的域名 '$domains_to_notify'，请手动更新已知域名列表。"
    NEW_DOMAIN_NOTIFICATION_TIME[index]=$current_time  # 更新最后发送通知时间
  fi
}

update_known_domains_list() {
  # 重新读取已知域名列表
  readarray -t UPDATED_DOMAIN_ARRAY < "$KNOWN_DOMAINS_FILE"
  # 从 NEW_DOMAINS_TO_NOTIFY 列表中移除已存在于已知域名列表的域名
  for updated_domain in "${UPDATED_DOMAIN_ARRAY[@]}"; do
    for i in "${!NEW_DOMAINS_TO_NOTIFY[@]}"; do
      if [[ "${NEW_DOMAINS_TO_NOTIFY[i]}" == "$updated_domain" ]]; then
        unset 'NEW_DOMAINS_TO_NOTIFY[i]'
      fi
    done
  done
  # 重新索引 NEW_DOMAINS_TO_NOTIFY 列表
  NEW_DOMAINS_TO_NOTIFY=("${NEW_DOMAINS_TO_NOTIFY[@]}")
}

# 持续监测每个 URL 的关键词和最终地址变化
while true; do
  # 检查是否超过24小时
  current_time=$(date +%s)
  runtime=$((current_time - RUN_TIME))
  if [ "$runtime" -ge "$MAX_RUNTIME" ]; then
    send_daily_summary  # 发送每日统计
    sleep "5"
    echo "脚本已运行24小时，自动结束进程。请等待定时任务自动重启进程。"
    exit 0
  fi

start_time=$(date +%s)  # 记录当前时间（秒）
  for ((i=0; i<${#URL_ARRAY[@]}; i++)); do
    URL=${URL_ARRAY[i]}
    KEYWORD=${KEYWORD_ARRAY[i]}
    
    printf "$(date +%H:%M:%S) 检查 URL$((i + 1)) ... | "

    # 获取最终跳转后的 URL 和网页内容
    FINAL_URL=$(curl --max-time 30 -Ls -o /dev/null -w %{url_effective} "$URL")
    content=$(curl --max-time 30 -s -L "$FINAL_URL")
    NOW_DOMAIN=$(get_domain "$FINAL_URL")

    if echo "$content" | grep -q "$KEYWORD"; then
      echo "关键词 '$KEYWORD' 存在于 $NOW_DOMAIN 的页面中。"
      FAIL_COUNT_ARRAY[i]=0  # 重置计数器
      KEYWORD_PRESENT_COUNT[i]=$((KEYWORD_PRESENT_COUNT[i] + 1))  # 有关键词计数
      
      # 检查是否需要发送恢复通知（按域名）
      if [[ "${RECOVERY_NOTIFICATION_SENT_BY_DOMAIN[i]}" == *"$NOW_DOMAIN"* ]]; then
        send_telegram_notification "【恢复】: $NOW_DOMAIN 的关键词 '$KEYWORD' 已重新检测到。"
        # 从恢复通知标志中移除当前域名
        RECOVERY_NOTIFICATION_SENT_BY_DOMAIN[i]=$(echo "${RECOVERY_NOTIFICATION_SENT_BY_DOMAIN[i]}" | sed "s/$NOW_DOMAIN,//g")
      fi
    else
      echo "[警告]: 关键词 '$KEYWORD' 不存在于 $NOW_DOMAIN 的页面中。"
      FAIL_COUNT_ARRAY[i]=$((FAIL_COUNT_ARRAY[i] + 1))  # 增加计数器
      CUMULATIVE_FAIL_COUNT[i]=$((CUMULATIVE_FAIL_COUNT[i] + 1))  # 增加累计失败计数
      KEYWORD_ABSENT_COUNT[i]=$((KEYWORD_ABSENT_COUNT[i] + 1))  # 无关键词计数

      # 检查是否连续 3 次失败
      if [ "${FAIL_COUNT_ARRAY[i]}" -ge $FAIL_COUNT ]; then
        echo "连续 $FAIL_COUNT 次检测不到关键词，发送 Telegram 通知..."
        send_telegram_notification "【严重问题】: $NOW_DOMAIN 连续 $FAIL_COUNT 次检测不到关键词 '$KEYWORD'。"
      fi

      # 检查是否累计 5 次失败
      if [ "${CUMULATIVE_FAIL_COUNT[i]}" -ge $CUMULATIVE_FAIL ]; then
        echo "累计 $CUMULATIVE_FAIL 次检测不到关键词，发送 Telegram 通知..."
        send_telegram_notification "【提醒】: $NOW_DOMAIN 累计 $CUMULATIVE_FAIL 次检测不到关键词 '$KEYWORD'。"
      fi

      # 发送通知后重置计数
      if [ "${FAIL_COUNT_ARRAY[i]}" -ge $FAIL_COUNT ] || [ "${CUMULATIVE_FAIL_COUNT[i]}" -ge $CUMULATIVE_FAIL ]; then
        FAIL_COUNT_ARRAY[i]=0  # 发送通知后重置计数器
        CUMULATIVE_FAIL_COUNT[i]=0  # 发送通知后重置累计失败计数器
        KEYWORD_RECOVERY_NOTIFICATION_SENT[i]=1  # 标记为已发送无关键词通知
        RECOVERY_NOTIFICATION_SENT_BY_DOMAIN[i]+="$NOW_DOMAIN,"
      fi
    fi

    # 检查是否需要新域名检测
    if [[ $CHECK_NEW_DOMAINS_ENABLED -eq 1 ]]; then
      check_and_notify_new_domain "$i" "$NOW_DOMAIN"
      update_known_domains_list  # 更新已知域名列表
    fi
  done

  # 计算等待时间，确保每次间隔是准确的
  end_time=$(date +%s)
  elapsed_time=$((end_time - start_time))  # 计算所用时间

  total_wait_time=$((INTERVAL - elapsed_time))   # 默认间隔减去每次检测所用时间，避免总的等待时间过长
  # 如果所花时间超过设定的间隔（极少情况下发生），可以设置一个最小的等待时间，比如 1 秒
  if [[ $total_wait_time -le 0 ]]; then
    total_wait_time=1
  fi

  # 等待指定的时间间隔
  sleep "$total_wait_time"  # 等待调整后的时间
done
