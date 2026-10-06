#!/usr/bin/env bash
# anime-migrate v2: 把做种结束（已从 qBittorrent 移除）的番剧迁移至 OSS
# 逻辑：每 INTERVAL 秒扫描一次本地 /Media：
#   1. 通过 qBittorrent API（API Key 认证）获取"仍在任务列表中的种子"占用的路径（做种保护）
#      三重来源：content_path；content_path 缺失时用 save_path 与 save_path/name 兜底
#   2. 空列表不采信：60s 后复核，两次都空才认定"真的没有种子"
#      （防 qB 重启后 WebUI 先就绪、种子列表未加载完成的假空——v1 误迁的主因）
#   3. 找出超过 MIN_AGE_MIN 分钟无变动、且不受任何种子保护的视频/字幕文件
#   4. 每个文件迁移前再实时复核一次 qB 列表（关闭轮内时序竞态窗口）
#   5. rclone moveto 上传至 OSS（上传校验成功后 rclone 才会删除本地文件）
#   6. 清理空目录
# DRY_RUN=1 时为演练模式：只打印将迁移的文件，不实际迁移
set -u

QB_URL="${QB_URL:-http://127.0.0.1:8080}"
QBT_API_KEY="${QBT_API_KEY:?请在 .env 中设置 QBT_API_KEY}"
REMOTE="${REMOTE:?请在 .env 中设置 OSS_REMOTE}"
LOCAL_ROOT="${LOCAL_ROOT:-/Media}"
MIN_AGE_MIN="${MIN_AGE_MIN:-15}"
INTERVAL="${INTERVAL:-600}"
DRY_RUN="${DRY_RUN:-0}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---- 拉取 qB 种子列表并生成保护路径列表 ----
# 返回 0 = 成功（合法空列表时输出标记 EMPTY_OK，由调用方决定是否采信）
# 返回 1 = 失败（qB 不可达 / 非法 JSON，调用方必须放弃迁移）
fetch_protected() {
  local resp
  resp=$(curl -s --max-time 15 \
    -H "Authorization: Bearer ${QBT_API_KEY}" \
    "${QB_URL}/api/v2/torrents/info")

  # fail-safe：必须是合法 JSON 数组（qB 旧版本空列表可能返回 {}，同样视为失败）
  if ! echo "$resp" | jq -e 'type=="array"' >/dev/null 2>&1; then
    return 1
  fi

  if [ "$(echo "$resp" | jq 'length')" -eq 0 ]; then
    echo "EMPTY_OK"
    return 0
  fi

  # 三重保护来源（fail-closed：宁可多保护，绝不漏保护）
  echo "$resp" | jq -r '
    .[] |
      (.content_path // empty),
      (if (.content_path // "") == "" then (.save_path // empty) else empty end),
      (if (.content_path // "") == "" then ((.save_path // "") + "/" + (.name // "")) else empty end)
  ' | sed '/^$/d' | sort -u
}

# ---- 判断文件是否受保护：全等 或 以 "保护路径/" 开头 ----
is_protected() {
  local f="$1" p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    [ "$p" = "EMPTY_OK" ] && continue
    if [ "$f" = "$p" ] || [[ "$f" == "$p"/* ]]; then
      return 0
    fi
  done
  return 1
}

log "anime-migrate v2 启动: 本地目录=${LOCAL_ROOT} 远程=${REMOTE} 扫描间隔=${INTERVAL}s 保护期=${MIN_AGE_MIN}min 演练模式=${DRY_RUN}"

while true; do
  EMPTY_CONFIRMED=0
  PROTECTED=$(fetch_protected) || {
    log "ERROR: 无法获取 qBittorrent 种子列表（保护检查失败），本轮跳过不迁移，${INTERVAL}s 后重试"
    sleep "$INTERVAL"
    continue
  }

  # 空列表不采信：60s 后复核，两次都空才按"确实没有种子"处理
  if [ "$PROTECTED" = "EMPTY_OK" ]; then
    log "WARN: qB 种子列表为空（可能刚重启、列表尚未加载完），60s 后复核"
    sleep 60
    PROTECTED=$(fetch_protected) || {
      log "ERROR: 复核时无法获取 qB 种子列表，本轮跳过不迁移"
      sleep "$INTERVAL"
      continue
    }
    if [ "$PROTECTED" = "EMPTY_OK" ]; then
      log "WARN: 复核后列表仍为空，按无做种任务处理"
      PROTECTED=""
      EMPTY_CONFIRMED=1
    fi
  fi

  log "本轮保护路径条目数: $(printf '%s\n' "$PROTECTED" | grep -c .)"

  find "$LOCAL_ROOT" -type f \
    ! -path "*/.incomplete/*" \
    -mmin +"$MIN_AGE_MIN" \
    \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' \
       -o -iname '*.ts' -o -iname '*.m2ts' -o -iname '*.wmv' \
       -o -iname '*.flv' -o -iname '*.mov' -o -iname '*.ass' \
       -o -iname '*.srt' \) \
    -print0 | while IFS= read -r -d '' f; do

      # 保护检查（本轮扫描时的列表）
      if printf '%s\n' "$PROTECTED" | is_protected "$f"; then
        continue   # 还在下载或做种，跳过
      fi

      # 迁移前实时复核：qB 不可达或列表可疑时放弃迁移
      NOW_PROTECTED=$(fetch_protected) || {
        log "ERROR: 迁移前复核失败（qB 不可达），放弃迁移: ${f}"
        continue
      }
      if [ "$NOW_PROTECTED" = "EMPTY_OK" ] && [ "$EMPTY_CONFIRMED" -ne 1 ]; then
        log "WARN: 迁移前复核发现列表变空（疑似 qB 正在重启），放弃迁移: ${f}"
        continue
      fi
      if printf '%s\n' "$NOW_PROTECTED" | is_protected "$f"; then
        log "跳过（迁移前复核发现已受保护）: ${f}"
        continue
      fi

      rel="${f#"$LOCAL_ROOT"/}"

      if [ "$DRY_RUN" = "1" ]; then
        log "演练: 将迁移 ${f} -> ${REMOTE}/${rel}"
        continue
      fi

      log "迁移: ${f} -> ${REMOTE}/${rel}"
      if rclone moveto "$f" "${REMOTE}/${rel}" \
           --config /config/rclone/rclone.conf \
           --transfers 1 --retries 3 --low-level-retries 5 \
           --stats 0 --log-level NOTICE; then
        log "完成: ${rel}"
      else
        log "ERROR: 迁移失败(将保留本地文件等待下次重试): ${f}"
      fi
    done

  # 清理空目录（保留 /Media 本身和顶层 anime/movie 目录）
  find "$LOCAL_ROOT" -mindepth 2 -type d -empty -delete 2>/dev/null

  sleep "$INTERVAL"
done
