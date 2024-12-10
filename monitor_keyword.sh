#!/usr/bin/env bash
# cron:0 0 11 * * *
# new Env("域名检测任务")

# 从环境变量中读取多个 URL 和关键词
URLS=${URLS}                                                                   # 监测链接（用换行分隔）
KEYWORDS=${KEYWORDS}                                                           # 链接中需要包含的关键词（用换行分隔）
BOT_TOKEN=${MONITOR_BOT_TOKENS}                                                # TG通知机器人token（用换行分隔）
CHAT_ID=${MONITOR_USER_IDS}                                                    # TG通知机器人id（用换行分隔）
INTERVAL=${INTERVAL:-60}                                                       # 默认检查间隔为60秒
FAIL_COUNT=${FAIL_COUNT:-3}                                                    # 连续错误触发通知次数，默认3次
CUMULATIVE_FAIL=${CUMULATIVE_FAIL:-5}                                          # 累计错误触发通知次数，默认5次
ALLOWED_SUFFIXES=${ALLOWED_SUFFIXES:-""}                                       # 如果未设置，则为空字符串
NEW_DOMAIN_NOTIFICATION_INTERVAL=${NEW_DOMAIN_NOTIFICATION_INTERVAL:-1800}     # 新域名通知间隔时间，默认30分钟
KNOWN_DOMAINS_FILE="known_domains.txt"                                         # 已知最终跳转域名列表（用换行分隔）

declare -A DOMAIN_FAIL_COUNT
declare -A DOMAIN_CUMULATIVE_FAIL_COUNT
declare -A DOMAIN_RECOVERY_NOTIFICATION_SENT

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
  echo "错误: URL 和关键词数量不匹配，请确保 MONITOR_USER_ID 和 MONITOR_BOT_TOKEN 中的项数相同。"
  exit 1
fi

# 将 URL 和关键词分割成数组
readarray -t URL_ARRAY <<< "$URLS"
readarray -t KEYWORD_ARRAY <<< "$KEYWORDS"
readarray -t CHAT_ID_ARRAY <<< "$CHAT_ID"
readarray -t BOT_TOKEN_ARRAY <<< "$BOT_TOKEN"
readarray -t ALLOWED_SUFFIX_ARRAY <<< "$ALLOWED_SUFFIXES"  # 将后缀转换为数组

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
KEYWORD_PRESENT_COUNT=()
KEYWORD_ABSENT_COUNT=()
NEW_DOMAIN_NOTIFICATION_TIME=()
NEW_DOMAINS_TO_NOTIFY=()  # 存储新发现的域名
RUN_TIME=$(date +%s)  # 记录脚本的启动时间
MAX_RUNTIME=86300  # 设置24小时（86400秒）的运行时长

for ((i=0; i<${#URL_ARRAY[@]}; i++)); do
  KEYWORD_PRESENT_COUNT[i]=0
  KEYWORD_ABSENT_COUNT[i]=0
  NEW_DOMAIN_NOTIFICATION_TIME[i]=0
done

# 使用公共 API 查询当前 IP 地址和归属地信息，并格式化输出
response=$(curl --max-time 30 -s https://ipinfo.io)
ip=$(echo "$response" | jq -r '.ip')
# 替换 IP 地址的最后一段为 "*"
masked_ip=$(echo "$ip" | awk -F. '{print $1"."$2"."$3".*"}')
formatted_response=$(echo "$response" | jq -r --arg masked_ip "$masked_ip" '[
  "IP地址: " + $masked_ip,
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

# 输出允许通知域名后缀列表
if [[ -n "$ALLOWED_SUFFIXES" ]]; then
  echo "允许发送失败通知的域名后缀: "
  for ((i=0; i<${#ALLOWED_SUFFIXES[@]}; i++)); do
    echo ".${ALLOWED_SUFFIXES[i]}"
  done
  echo ""
fi

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

# 发送 Telegram 通知的函数
send_telegram_notification() {
  local message=$1
  local domain=$2
  local force_send=${3:-false}  # 第二个参数控制是否强制发送
  # 检查是否填写 BOT_TOKEN 和 CHAT_ID
  if [[ -z "$BOT_TOKEN_ARRAY" || -z "$CHAT_ID_ARRAY" ]]; then
    echo "未填写 BOT_TOKEN 或 CHAT_ID，无法发送 Telegram 通知。"
    return
  fi
  
  # 如果未填写允许通知域名列表，则都可发送通知
  if [[ -n "$ALLOWED_SUFFIXES" ]]; then
    # 如果不是强制发送，检查域名是否符合允许的后缀
    if [[ "$force_send" == "false" ]]; then
        # 判断是否为允许的域名
        local is_allowed=0
        for suffix in "${ALLOWED_SUFFIX_ARRAY[@]}"; do
            if [[ "$domain" == *".$suffix" ]]; then
            is_allowed=1
            break
            fi
        done
        if [[ "$is_allowed" -eq 0 ]]; then
            echo "$domain 不在允许通知列表中，跳过发送通知。"
            return
        fi
    fi
  fi

  for ((j=0; j<${#BOT_TOKEN_ARRAY[@]}; j++)); do
  curl -s --max-time 30 -o /dev/null -X POST "https://api.telegram.org/bot${BOT_TOKEN_ARRAY[j]}/sendMessage" \
       -d chat_id="${CHAT_ID_ARRAY[j]}" \
       -d text="$message

当前 IP 归属地信息: 
$formatted_response"
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
  send_telegram_notification "$message" "$domain" true
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
    echo "检测到新的域名 '$domains_to_notify，发送 Telegram 通知..."
    send_telegram_notification "【注意】: 检测到新的域名 '$domains_to_notify'，请手动更新已知域名列表。" "$domains_to_notify" true
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
  start_time=$(date +%s)  # 记录当前时间（秒）
  # 检查是否超过24小时
  current_time=$(date +%s)
  runtime=$((current_time - RUN_TIME))
  if [ "$runtime" -ge "$MAX_RUNTIME" ]; then
    echo "脚本即将结束，发送日报 Telegram 通知..."
    send_daily_summary  # 发送每日统计
    sleep "5"
    exit 0
  fi

  for ((i=0; i<${#URL_ARRAY[@]}; i++)); do
    URL=${URL_ARRAY[i]}
    KEYWORD=${KEYWORD_ARRAY[i]}
    
    printf "$(date +%H:%M:%S) 检查 URL$((i + 1)) ... | "

    # 获取最终跳转后的 URL 和网页内容
    content=$(curl --max-time 10 -s -L -w '\n%{url_effective}' "$URL")
    FINAL_URL=$(echo "$content" | tail -n 1)
    NOW_DOMAIN=$(get_domain "$FINAL_URL")

    if echo "$content" | grep -q "$KEYWORD"; then
      echo "关键词 '$KEYWORD' 存在于 $NOW_DOMAIN 的页面中。"
      # 关键词存在，重置对应域名的计数器
      DOMAIN_FAIL_COUNT["$NOW_DOMAIN"]=0  # 重置连续无关键词计数
      KEYWORD_PRESENT_COUNT[i]=$((KEYWORD_PRESENT_COUNT[i] + 1))  # 增加有关键词计数
      
        # 检查是否需要发送恢复通知
        if [[ "${DOMAIN_RECOVERY_NOTIFICATION_SENT[$NOW_DOMAIN]}" -eq 1 ]]; then
            echo "$NOW_DOMAIN 的关键词 '$KEYWORD' 已重新检测到，发送 Telegram 通知..."
            send_telegram_notification "【恢复】: $NOW_DOMAIN 的关键词 '$KEYWORD' 已重新检测到。" "$NOW_DOMAIN"
            DOMAIN_RECOVERY_NOTIFICATION_SENT["$NOW_DOMAIN"]=0
        fi
    else
      echo "[警告]: 关键词 '$KEYWORD' 不存在于 $NOW_DOMAIN 的页面中。"
      # 增加域名计数器
      DOMAIN_FAIL_COUNT["$NOW_DOMAIN"]=$((DOMAIN_FAIL_COUNT["$NOW_DOMAIN"] + 1))  # 增加连续无关键词计数
      DOMAIN_CUMULATIVE_FAIL_COUNT["$NOW_DOMAIN"]=$((DOMAIN_CUMULATIVE_FAIL_COUNT["$NOW_DOMAIN"] + 1))  # 增加累计无关键词计数
      KEYWORD_ABSENT_COUNT[i]=$((KEYWORD_ABSENT_COUNT[i] + 1))  # 增加无关键词计数

      # 检查连续失败次数
      if [[ "${DOMAIN_FAIL_COUNT[$NOW_DOMAIN]}" -ge $FAIL_COUNT ]]; then
          echo "$NOW_DOMAIN 已连续 $FAIL_COUNT 次检测不到关键词，发送 Telegram 通知..."
          send_telegram_notification "【提醒】: $NOW_DOMAIN 连续 ${FAIL_COUNT} 次检测不到关键词 '$KEYWORD'。" "$NOW_DOMAIN"
          DOMAIN_FAIL_COUNT["$NOW_DOMAIN"]=0  # 重置连续无关键词计数
          DOMAIN_CUMULATIVE_FAIL_COUNT["$NOW_DOMAIN"]=0  # 重置累计无关键词计数
          DOMAIN_RECOVERY_NOTIFICATION_SENT["$NOW_DOMAIN"]=1  # 标记需要发送恢复通知
      fi

      # 检查累计失败次数
      if [[ "${DOMAIN_CUMULATIVE_FAIL_COUNT[$NOW_DOMAIN]}" -ge $CUMULATIVE_FAIL ]]; then
          echo "$NOW_DOMAIN 已累计 $CUMULATIVE_FAIL 次检测不到关键词，发送 Telegram 通知..."
          send_telegram_notification "【注意】: $NOW_DOMAIN 累计 ${CUMULATIVE_FAIL} 次检测不到关键词 '$KEYWORD'。" "$NOW_DOMAIN"
          DOMAIN_FAIL_COUNT["$NOW_DOMAIN"]=0  # 重置连续无关键词计数
          DOMAIN_CUMULATIVE_FAIL_COUNT["$NOW_DOMAIN"]=0  # 重置累计无关键词计数
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
