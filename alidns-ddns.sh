#!/usr/bin/env bash
set -u
umask 077

# =========================
# 配置区
# =========================

# 认证信息
ACCESS_KEY_ID="your_access_key_id"
ACCESS_KEY_SECRET="your_access_key_secret"

# 解析配置
DOMAIN="example.com"     # 主域名
RR="home"                # 子域名；根域名填 @
IP_VERSION="6"           # 只能填 4 或 6

# 记录参数
TTL="600"

# 网络参数
IFACE=""                 # 留空表示自动选择；建议多网卡机器指定，如 eth0

# 运行参数
STATE_DIR="/var/lib/alidns-ddns"
LOCK_FILE="/run/alidns-ddns.lock"

mkdir -p "$STATE_DIR"

# =========================
# 工具检查
# =========================
for cmd in curl ip openssl awk sed grep date flock head cut paste sort tr; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[$(date '+%F %T')] missing command: $cmd" >&2
    exit 1
  }
done

# =========================
# 派生变量
# =========================
case "$IP_VERSION" in
  4) RECORD_TYPE="A" ;;
  6) RECORD_TYPE="AAAA" ;;
  *)
    echo "[$(date '+%F %T')] invalid IP_VERSION: $IP_VERSION (must be 4 or 6)" >&2
    exit 1
    ;;
esac

# =========================
# 基础函数
# =========================
log() {
  echo "[$(date '+%F %T')] $*"
}

rawurlencode() {
  local string="${1}"
  local strlen=${#string}
  local encoded=""
  local pos c o
  for (( pos=0; pos<strlen; pos++ )); do
    c=${string:$pos:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) o="$c" ;;
      *) printf -v o '%%%02X' "'$c" ;;
    esac
    encoded+="$o"
  done
  printf '%s' "$encoded"
}

# =========================
# 获取本机 IP
# =========================
get_ipv4() {
  local lines ip4

  if [[ -n "$IFACE" ]]; then
    lines="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null || true)"
  else
    lines="$(ip -4 -o addr show scope global 2>/dev/null || true)"
  fi

  ip4="$(printf '%s\n' "$lines" \
    | awk '{print $4}' \
    | cut -d/ -f1 \
    | head -n1)"

  printf '%s' "$ip4"
}

get_ipv6() {
  local lines ip6

  if [[ -n "$IFACE" ]]; then
    lines="$(ip -6 -o addr show dev "$IFACE" scope global 2>/dev/null || true)"
  else
    lines="$(ip -6 -o addr show scope global 2>/dev/null || true)"
  fi

  # 过滤 temporary / deprecated / tentative，尽量取稳定可用的全局 IPv6
  ip6="$(printf '%s\n' "$lines" \
    | grep -v ' temporary ' \
    | grep -v ' deprecated ' \
    | grep -v ' tentative ' \
    | awk '{print $4}' \
    | cut -d/ -f1 \
    | head -n1)"

  printf '%s' "$ip6"
}

get_current_ip() {
  case "$IP_VERSION" in
    4) get_ipv4 ;;
    6) get_ipv6 ;;
  esac
}

# =========================
# 阿里云 DNS RPC API
# =========================
aliyun_rpc_call() {
  local action="$1"
  shift

  local endpoint="https://alidns.aliyuncs.com/"
  local method="GET"
  local timestamp nonce canonical_qs string_to_sign signature
  local -a params

  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  nonce="$(date +%s%N)"

  params=(
    "AccessKeyId=$(rawurlencode "$ACCESS_KEY_ID")"
    "Action=$(rawurlencode "$action")"
    "Format=JSON"
    "SignatureMethod=HMAC-SHA1"
    "SignatureNonce=$(rawurlencode "$nonce")"
    "SignatureVersion=1.0"
    "Timestamp=$(rawurlencode "$timestamp")"
    "Version=2015-01-09"
  )

  local kv
  for kv in "$@"; do
    params+=("$(rawurlencode "${kv%%=*}")=$(rawurlencode "${kv#*=}")")
  done

  IFS=$'\n' canonical_qs="$(printf '%s\n' "${params[@]}" | sort | paste -sd'&' -)"
  unset IFS

  string_to_sign="${method}&%2F&$(rawurlencode "$canonical_qs")"

  signature="$(printf '%s' "$string_to_sign" \
    | openssl dgst -sha1 -hmac "${ACCESS_KEY_SECRET}&" -binary \
    | openssl base64 -A)"

  curl -fsS "${endpoint}?Signature=$(rawurlencode "$signature")&${canonical_qs}"
}

describe_record() {
  aliyun_rpc_call "DescribeDomainRecords" \
    "DomainName=${DOMAIN}" \
    "RRKeyWord=${RR}" \
    "TypeKeyWord=${RECORD_TYPE}"
}

add_record() {
  local value="$1"
  aliyun_rpc_call "AddDomainRecord" \
    "DomainName=${DOMAIN}" \
    "RR=${RR}" \
    "Type=${RECORD_TYPE}" \
    "Value=${value}" \
    "TTL=${TTL}"
}

update_record() {
  local record_id="$1"
  local value="$2"
  aliyun_rpc_call "UpdateDomainRecord" \
    "RecordId=${record_id}" \
    "RR=${RR}" \
    "Type=${RECORD_TYPE}" \
    "Value=${value}" \
    "TTL=${TTL}"
}

extract_first_record_id() {
  sed -n 's/.*"RecordId":"\([^"]*\)".*/\1/p' | head -n1
}

extract_first_value() {
  sed -n 's/.*"Value":"\([^"]*\)".*/\1/p' | head -n1
}

# =========================
# 主流程
# =========================
main() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || exit 0

  local current_ip resp record_id remote_value state_file
  state_file="${STATE_DIR}/last_ip_v${IP_VERSION}"

  current_ip="$(get_current_ip)"

  # 当前没有可用 IP：视为正常状态，不报错，不删解析，等待下一轮
  if [[ -z "$current_ip" ]]; then
    log "no usable IPv${IP_VERSION} found, skip"
    exit 0
  fi

  if ! resp="$(describe_record 2>/dev/null)"; then
    log "DescribeDomainRecords failed, skip this round"
    exit 0
  fi

  record_id="$(printf '%s' "$resp" | extract_first_record_id)"
  remote_value="$(printf '%s' "$resp" | extract_first_value)"

  # 没有记录则自动创建
  if [[ -z "$record_id" ]]; then
    if add_record "$current_ip" >/dev/null 2>&1; then
      printf '%s\n' "$current_ip" > "$state_file"
      log "created ${RR}.${DOMAIN} ${RECORD_TYPE} -> $current_ip"
      exit 0
    else
      log "AddDomainRecord failed"
      exit 0
    fi
  fi

  # 云端记录与当前 IP 相同则直接退出
  if [[ "$remote_value" == "$current_ip" ]]; then
    printf '%s\n' "$current_ip" > "$state_file"
    log "unchanged ${RR}.${DOMAIN} ${RECORD_TYPE}: $current_ip"
    exit 0
  fi

  # 已有记录则更新
  if update_record "$record_id" "$current_ip" >/dev/null 2>&1; then
    printf '%s\n' "$current_ip" > "$state_file"
    log "updated ${RR}.${DOMAIN} ${RECORD_TYPE}: ${remote_value:-<empty>} -> $current_ip"
    exit 0
  else
    log "UpdateDomainRecord failed"
    exit 0
  fi
}

main "$@"