#!/usr/bin/env bash

set -euo pipefail

IP_MODE="-4"
MAX_TRIES=10
WAIT_AFTER_SWITCH=8
CHANGE_API="https://api.pqs.pw/ipch/xxx"  # PQS 更换 IP API URL

Font_Red="\033[31m"
Font_Green="\033[32m"
Font_Yellow="\033[33m"
Font_Blue="\033[36m"
Font_Suffix="\033[0m"

UA_BROWSER="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
ACCEPT_HDR='text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7'
TITLE1="81280792"   # LEGO Ninjago
TITLE2="70143836"   # Breaking Bad
TIMEOUT=10
RETRY=1

usage() {
  echo "Usage: $0 [-4|-6] [--max N] [--wait SECONDS]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -4) IP_MODE="-4"; shift ;;
    -6) IP_MODE="-6"; shift ;;
    --max) MAX_TRIES="$2"; shift 2 ;;
    --wait) WAIT_AFTER_SWITCH="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done


curl_fetch() {
  local url="$1"
  curl ${IP_MODE} -fsL --max-time "${TIMEOUT}" --retry "${RETRY}" \
    -H "accept: ${ACCEPT_HDR}" \
    -H "accept-language: en-US,en;q=0.9" \
    -H 'priority: u=0, i' \
    -H 'sec-ch-ua: "Microsoft Edge";v="135", "Not-A.Brand";v="8", "Chromium";v="135"' \
    -H 'sec-ch-ua-mobile: ?0' \
    -H 'sec-ch-ua-platform: "Windows"' \
    -H 'sec-ch-ua-platform-version: "15.0.0"' \
    -H 'sec-fetch-dest: document' \
    -H 'sec-fetch-mode: navigate' \
    -H 'sec-fetch-site: none' \
    -H 'sec-fetch-user: ?1' \
    -H 'upgrade-insecure-requests: 1' \
    --user-agent "${UA_BROWSER}" \
    "$url"
}

extract_region() {
  local html="$1"
  local region
  region=$(echo "$html" | grep -o 'data-country="[A-Z][A-Z]"' | sed 's/.*="\([A-Z][A-Z]\)".*/\1/' | head -n1)
  [[ -n "$region" ]] && { echo "$region"; return; }
  echo "US"
}

test_scholar_once() {
  local url1="https://scholar.google.com/scholar?hl=zh-CN&as_sdt=0%2C5&q=%E9%87%8F%E5%AD%90%E5%8A%9B%E5%AD%A6&btnG=&oq=%E9%87%8F%E5%AD%90"
  local url2="https://scholar.google.com/scholar?hl=zh-CN&as_sdt=0%2C5&q=Quantum+Mechanics&btnG="
  local r1 r2
  r1="$(curl_fetch "$url1" || true)"
  r2="$(curl_fetch "$url2" || true)"

  if [[ -z "$r1" || -z "$r2" ]]; then
    echo -e " scholar:\t\t\t${Font_Red}[ERROR] Failed (Network Connection)${Font_Suffix}"
    echo "STATUS=NETWORK_FAIL"
    return 1
  fi

 # 在两次请求结果中查找 BLOCK_PHRASES 中的任何关键词
 # 封鎖提示關鍵詞（繁/簡/英 + 常見變體）
  BLOCK_PHRASES=(
    "我們的系統檢測到您的計算機網路中存在異常流量"
    "我们的系统检测到您的计算机网络中存在异常流量"
    "我們的系統檢測到您的網路中存在異常流量"
    "我們檢測到異常流量"
    "检测到异常流量"
    "異常流量"
    "unusual traffic"
    "detected unusual activity"
    "Our systems have detected unusual traffic"
    "To continue, please type the characters"
    "please type the characters"
    "please type the characters you see in the image"
    "please show you're not a robot"
    "verify you are human"
    "verify you're human"
    "please enable JavaScript"
    "enable JavaScript"
    "captcha"
    "recaptcha"
    "/sorry"
    "access denied"
    "access has been denied"
    "访问受限"
    "访问已被阻止"
    "访问被阻止"
    "Page not available"
  )
  m1=""
  m2=""
  for phrase in "${BLOCK_PHRASES[@]}"; do
    if echo "$r1" | grep -Fqi "$phrase"; then
      m1="$phrase"
      break
    fi
  done
  for phrase in "${BLOCK_PHRASES[@]}"; do
    if echo "$r2" | grep -Fqi "$phrase"; then
      m2="$phrase"
      break
    fi
  done
  # 如果两个结果都包含封锁关键词 → 判定为被封锁
  if [[ -n "$m1" && -n "$m2" ]]; then
    echo -e " Scholar:\t\t\t${Font_Yellow}[WARN] Access Limited (Detected: ${m1})${Font_Suffix}"
    echo "STATUS=BLOCKED"
    return 0
  fi

  if [[ -z "$m1" || -z "$m2" ]]; then
    local region
    region="$(extract_region "$r1")"
    echo -e " Scholar:\t\t\t${Font_Green}[OK] Unlocked (Region: ${region})${Font_Suffix}"
    echo "STATUS=UNLOCK REGION=${region}"
    return 0
  fi

  echo -e " Scholar:\t\t\t${Font_Red}[ERROR] Unknown Failure${Font_Suffix}"
  echo "STATUS=FAILED"
  return 0
}

switch_ip() {
  echo -e "${Font_Blue}[INFO] Switching IP via: ${CHANGE_API}${Font_Suffix}"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "${CHANGE_API}" || echo "000")
  echo " Switch API HTTP: ${code}"
  [[ "$code" == "200" ]] || return 1
  return 0
}

main() {
  for ((i=1; i<=MAX_TRIES; i++)); do
    echo "== Attempt ${i}/${MAX_TRIES} =="

    out="$(test_scholar_once || true)"
    echo "$out" | sed 's/^/  /'

    status=$(echo "$out" | grep -o 'STATUS=[A-Z_]*' | head -n1 | cut -d= -f2)

    if [[ "$status" == "UNLOCK" ]]; then
      echo -e "${Font_Green}[OK] Done: Scholar Fully Unlocked.${Font_Suffix}"
      exit 0
    fi

    if [[ "$status" == "NETWORK_FAIL" ]]; then
      echo -e "${Font_Yellow}[WARN] Network issue detected, skipping IP switch.${Font_Suffix}"
      sleep "${WAIT_AFTER_SWITCH}"
      continue
    fi

    if [[ "$status" == "FAILED" || -z "$status" ]]; then
      echo -e "${Font_Yellow}[WARN] Test failed or unknown status, retrying after wait...${Font_Suffix}"
      sleep "${WAIT_AFTER_SWITCH}"
      continue
    fi

    if [[ "$status" == "ORIGINALS" ]]; then
      echo -e "${Font_Blue}[INFO] Detected Originals-only region, switching IP...${Font_Suffix}"
      if switch_ip; then
        echo -e "${Font_Green}[OK] IP switched. Waiting ${WAIT_AFTER_SWITCH}s...${Font_Suffix}"
        sleep "${WAIT_AFTER_SWITCH}"
        continue
      else
        echo -e "${Font_Red}[ERROR] IP switch API failed. Waiting ${WAIT_AFTER_SWITCH}s before retry...${Font_Suffix}"
        sleep "${WAIT_AFTER_SWITCH}"
        continue
      fi
    fi
  done

  echo -e "${Font_Red}[ERROR] Reached max attempts (${MAX_TRIES}) without full unlock.${Font_Suffix}"
  exit 2
}

main
