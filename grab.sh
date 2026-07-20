#!/usr/bin/env bash
# grab.sh - 循环抢占多台 Oracle Cloud A1.Flex 免费 ARM 实例(幂等、可重启)
# 注意:不使用 set -e,launch 失败是常态(容量不足),需自行判断后继续。

# ---------- 必填校验 ----------
require() {
  local name="$1" val="${!1:-}"
  if [ -z "$val" ]; then
    echo "❌ 缺少必填环境变量: ${name},请检查 .env。容器退出(不重启)。"
    exit 0
  fi
}
require COMPARTMENT_ID
require SUBNET_ID
require IMAGE_ID

# ---------- 配置 ----------
SSH_KEY_FILE="${SSH_KEY_FILE:-/keys/id_rsa.pub}"
DISPLAY_NAME="${DISPLAY_NAME:-free-arm}"
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
NUM_INSTANCES="${NUM_INSTANCES:-2}"
OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-12}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-50}"
SLEEP_SECONDS="${SLEEP_SECONDS:-60}"
AVAILABILITY_DOMAINS_RAW="${AVAILABILITY_DOMAINS:-}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
SHAPE_CONFIG="{\"ocpus\": ${OCPUS}, \"memoryInGBs\": ${MEMORY_GB}}"

log() { echo "[$(date '+%F %T')] $*"; }

notify() {
  local msg="$1"
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=${msg}" >/dev/null 2>&1 || true
  fi
}

# 返回当前已存在(未 TERMINATED)、名字以 ${DISPLAY_NAME}- 开头的实例名,每行一个
list_existing_names() {
  local json status
  json=$(oci compute instance list --compartment-id "$COMPARTMENT_ID" --output json </dev/null 2>/dev/null)
  status=$?
  if [ $status -ne 0 ] || [ -z "$json" ]; then
    return 1
  fi
  printf '%s' "$json" | DISPLAY_NAME="$DISPLAY_NAME" python3 -c '
import sys, json, os
prefix = os.environ.get("DISPLAY_NAME", "") + "-"
payload = json.load(sys.stdin)
if not isinstance(payload, dict) or not isinstance(payload.get("data"), list):
    raise ValueError("OCI response missing data list")
for x in payload["data"]:
    name = x.get("display-name", "")
    state = (x.get("lifecycle-state") or "").upper()
    if name.startswith(prefix) and state not in ("TERMINATED", "TERMINATING"):
        print(name)
'
}

# ---------- 解析可用域 ----------
declare -a ADS=()
if [ -n "$AVAILABILITY_DOMAINS_RAW" ]; then
  IFS=',' read -r -a ADS <<< "$AVAILABILITY_DOMAINS_RAW"
else
  log "未指定可用域,自动获取..."
  AD_JSON=$(oci iam availability-domain list --compartment-id "$COMPARTMENT_ID" \
    --query "data[].name" --output json </dev/null 2>/dev/null)
  if [ -z "$AD_JSON" ]; then
    log "❌ 获取可用域失败,请检查 /root/.oci 配置与网络。容器退出(不重启)。"
    notify "❌ OCI 抢占停止:获取可用域失败"
    exit 0
  fi
  mapfile -t ADS < <(printf '%s' "$AD_JSON" | python3 -c '
import sys, json
try:
    for x in (json.load(sys.stdin) or []):
        if isinstance(x, str): print(x)
except Exception:
    pass')
fi

declare -a VALID_ADS=()
for ad in "${ADS[@]}"; do
  ad=$(echo "$ad" | xargs)
  [[ "$ad" =~ ^[A-Za-z0-9._:-]+$ ]] && VALID_ADS+=("$ad")
done
ADS=("${VALID_ADS[@]}")
if [ ${#ADS[@]} -eq 0 ]; then
  log "❌ 无有效可用域,请检查配置。容器退出(不重启)。"
  notify "❌ OCI 抢占停止:无有效可用域"
  exit 0
fi

log "目标可用域: ${ADS[*]}"
log "目标: ${NUM_INSTANCES} 台 × ${OCPUS}核/${MEMORY_GB}GB/${BOOT_VOLUME_GB}GB (${SHAPE})"

# ---------- 目标实例名列表 ----------
declare -a TARGETS=()
for i in $(seq 1 "$NUM_INSTANCES"); do TARGETS+=("${DISPLAY_NAME}-${i}"); done

notify "🚀 OCI 抢占启动:目标 ${NUM_INSTANCES} 台 ${OCPUS}核/${MEMORY_GB}GB"

attempt=0
while true; do
  attempt=$((attempt + 1))

  # 每轮开始刷新"已存在"集合；查询失败时禁止继续创建，避免把失败误判为零实例
  EXISTING_OUTPUT=$(list_existing_names)
  if [ $? -ne 0 ]; then
    log "⚠️ 查询已有实例失败，本轮不执行创建，${SLEEP_SECONDS}s 后重试。"
    sleep "$SLEEP_SECONDS"
    continue
  fi
  EXISTING=()
  [ -n "$EXISTING_OUTPUT" ] && mapfile -t EXISTING <<< "$EXISTING_OUTPUT"
  declare -a TODO=()
  for t in "${TARGETS[@]}"; do
    found=0
    for e in "${EXISTING[@]}"; do [ "$t" = "$e" ] && found=1 && break; done
    [ $found -eq 0 ] && TODO+=("$t")
  done

  log "第 ${attempt} 轮 | 已有 ${#EXISTING[@]}/${NUM_INSTANCES} 台,待抢: ${TODO[*]:-无}"

  if [ ${#TODO[@]} -eq 0 ]; then
    log "🎉 已抢满 ${NUM_INSTANCES} 台,全部完成!容器退出。"
    notify "🎉 已抢满 ${NUM_INSTANCES} 台 Oracle 免费 ARM 实例!"
    exit 0
  fi

  for NAME in "${TODO[@]}"; do
    for AD in "${ADS[@]}"; do
      log "  [${NAME}] 尝试创建于 ${AD} ... (单次调用约需 1-2 分钟)"
      OUTPUT=$(oci compute instance launch \
        --availability-domain "$AD" \
        --compartment-id "$COMPARTMENT_ID" \
        --shape "$SHAPE" \
        --shape-config "$SHAPE_CONFIG" \
        --image-id "$IMAGE_ID" \
        --subnet-id "$SUBNET_ID" \
        --assign-public-ip true \
        --display-name "$NAME" \
        --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
        --ssh-authorized-keys-file "$SSH_KEY_FILE" \
        </dev/null 2>&1)
      STATUS=$?

      if [ $STATUS -eq 0 ]; then
        log "  ✅ [${NAME}] 抢占成功!(${AD})"
        IID=$(printf '%s' "$OUTPUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["data"]["id"])
except Exception: pass' 2>/dev/null)
        log "      Instance OCID: ${IID:-(见日志)}"
        notify "✅ [${NAME}] 抢占成功!${OCPUS}核/${MEMORY_GB}GB @ ${AD}"
        break   # 这台成功,跳出 AD 循环,去抢下一台
      fi

      if printf '%s' "$OUTPUT" | grep -q "Out of host capacity"; then
        log "  → [${NAME}] ${AD} 容量不足"
      elif printf '%s' "$OUTPUT" | grep -qE "LimitExceeded|QuotaExceeded"; then
        log "  → ⚠️ 已达配额上限,停止。容器退出(不重启)。"
        printf '%s\n' "$OUTPUT" | head -5
        notify "⚠️ OCI 抢占停止:已达配额上限"
        exit 0
      elif printf '%s' "$OUTPUT" | grep -qE "TooManyRequests|429"; then
        log "  → 被限流(429),延长等待"
        sleep $((SLEEP_SECONDS * 2))
      else
        log "  → [${NAME}] ${AD} 其他错误:"
        printf '%s\n' "$OUTPUT" | grep -E '"message"|"code"' | head -3
      fi
    done
  done

  log "本轮结束,等待 ${SLEEP_SECONDS}s 后重试..."
  sleep "$SLEEP_SECONDS"
done
