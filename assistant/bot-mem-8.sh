#!/usr/bin/env bash
set -euo pipefail

API_KEY="sk-proxy"
MODEL="my-agent"
CONVO_FILE="conversation.json"
SAVE_DIR="saved_convos"

mkdir -p "$SAVE_DIR"
[[ -f "$CONVO_FILE" ]] || echo "[]" > "$CONVO_FILE"

timestamp() { date +"%Y%m%d-%H%M%S"; }

save_convo() {
  local savefile="$SAVE_DIR/conversation-$(timestamp).json"
  cp "$CONVO_FILE" "$savefile"
  echo "[conversation saved to $savefile]"
}

list_convos() {
  local i=1
  for f in "$SAVE_DIR"/conversation-*.json 2>/dev/null; do
    [[ -e "$f" ]] || { echo "[no saved conversations]"; return; }
    echo "$i) $(basename "$f")"
    ((i++))
  done
}

load_convo() {
  local num="$1"
  local f
  f=$(ls "$SAVE_DIR"/conversation-*.json 2>/dev/null | sed -n "${num}p") || true
  if [[ -z "$f" ]]; then
    echo "[no such conversation #$num]"
    return 1
  fi
  jq -s '.[0] + .[1]' "$CONVO_FILE" "$f" > "$CONVO_FILE.tmp" && mv "$CONVO_FILE.tmp" "$CONVO_FILE"
  echo "[conversation $num loaded from $f]"
}

clear_convo() {
  echo "[]" > "$CONVO_FILE"
  echo "[conversation cleared]"
}

clear_saved() {
  local num="$1"
  if [[ "$num" == "all" ]]; then
    rm -f "$SAVE_DIR"/conversation-*.json
    echo "[all saved conversations cleared]"
  else
    local f
    f=$(ls "$SAVE_DIR"/conversation-*.json 2>/dev/null | sed -n "${num}p") || true
    if [[ -z "$f" ]]; then
      echo "[no such saved conversation #$num]"
      return 1
    fi
    rm -f "$f"
    echo "[deleted saved conversation $num: $f]"
  fi
}

undo_convo() {
  jq 'del(.[-1])' "$CONVO_FILE" > "$CONVO_FILE.tmp" && mv "$CONVO_FILE.tmp" "$CONVO_FILE"
  echo "[last message removed]"
}

run_bot() {
  local user_input="$1"
  local tmp_user="$(mktemp)"
  local tmp_payload="$(mktemp)"
  local tmp_reply="$(mktemp)"

  printf '%s\n' "$user_input" > "$tmp_user"

  jq --slurpfile convo "$CONVO_FILE" --slurpfile msg "$tmp_user" -n \
    --arg model "$MODEL" \
    '{
       model: $model,
       messages: ($convo[0] + [{role:"user", content:$msg[0]}])
     }' > "$tmp_payload"

  echo
  echo "-> Bot: Output"
  echo

  curl -s -X POST http://localhost:8080/v1/chat/completions \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @"$tmp_payload" \
    | tee "$tmp_reply" \
    | jq -r '.choices[0].message.content'

  local reply
  reply=$(jq -r '.choices[0].message.content' "$tmp_reply")

  if [[ "${NO_SAVE:-0}" -eq 0 ]]; then
    jq --arg c "$user_input" '. + [{role:"user", content:$c}]' "$CONVO_FILE" > "$CONVO_FILE.tmp" && mv "$CONVO_FILE.tmp" "$CONVO_FILE"
    jq --arg c "$reply" '. + [{role:"assistant", content:$c}]' "$CONVO_FILE" > "$CONVO_FILE.tmp" && mv "$CONVO_FILE.tmp" "$CONVO_FILE"
  fi

  cp "$tmp_payload" last_payload.json

  rm -f "$tmp_user" "$tmp_payload" "$tmp_reply"
}

show_convo() {
  jq -r 'to_entries[] | "\(.key+1)) [\(.value.role)] \(.value.content)"' "$CONVO_FILE"
}

resend_payload() {
  echo "[resending last payload]"
  curl -s -X POST http://localhost:8080/v1/chat/completions \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @last_payload.json \
    | tee last_reply.json \
    | jq -r '.choices[0].message.content'

  local reply
  reply=$(jq -r '.choices[0].message.content' last_reply.json)

  if [[ "${NO_SAVE:-0}" -eq 0 ]]; then
    jq --arg c "$reply" '. + [{role:"assistant", content:$c}]' "$CONVO_FILE" > "$CONVO_FILE.tmp" && mv "$CONVO_FILE.tmp" "$CONVO_FILE"
  fi
}

# --- Modes ---
if [[ "${1:-}" == "--one-run" ]]; then
  NO_SAVE=1
  shift
  run_bot "$*"
  exit 0
fi

if [[ ! -t 0 ]]; then
  NO_SAVE=1
  input=$(cat)
  run_bot "$input"
  exit 0
fi

# --- Interactive ---
while true; do
  echo
  echo "-> User: Input (multi-line OK). Special commands:"
  echo "  /save         -> save current conversation"
  echo "  /list         -> list saved conversations"
  echo "  /load <num>   -> load a saved conversation"
  echo "  /clear        -> clear current conversation"
  echo "  /clear <num>  -> delete saved conversation"
  echo "  /clear all    -> delete all saved conversations"
  echo "  /show         -> show conversation JSON"
  echo "  /undo         -> remove last message"
  echo "  /payload      -> show last payload sent"
  echo "  /resend       -> resend last payload"
  echo "  /history N    -> resend message N"
  echo "  /history last -> resend last message"
  echo "  Ctrl-D (EOF)  -> send to bot"
  echo "  Ctrl-C        -> exit"
  echo

  user_input=""
  while IFS= read -r line; do
    user_input+="$line"$'\n'
  done || true

  user_text_trimmed=$(echo "$user_input" | sed 's/[[:space:]]*$//')

  case "$user_text_trimmed" in
    /save) save_convo; continue ;;
    /list) list_convos; continue ;;
    /load\ *) load_convo "${user_text_trimmed#*/load }"; continue ;;
    /clear) clear_convo; continue ;;
    /clear\ all) clear_saved all; continue ;;
    /clear\ *) clear_saved "${user_text_trimmed#*/clear }"; continue ;;
    /show) show_convo; continue ;;
    /undo) undo_convo; continue ;;
    /payload) cat last_payload.json; continue ;;
    /resend) resend_payload; continue ;;
    /history\ *)
      arg="${user_text_trimmed#*/history }"
      len=$(jq length "$CONVO_FILE")
      if [[ "$arg" == "last" ]]; then
        if (( len == 0 )); then
          echo "[no messages in conversation]"
          continue
        fi
        idx=$((len-1))
        selected=$(jq -r ".[$idx]" "$CONVO_FILE")
      elif [[ "$arg" =~ ^[0-9]+$ ]]; then
        if (( arg < 1 || arg > len )); then
          echo "[invalid message number: $arg]"
          continue
        fi
        selected=$(jq -r ".[$((arg-1))]" "$CONVO_FILE")
      else
        echo "[invalid /history argument: $arg]"
        continue
      fi
      role=$(echo "$selected" | jq -r '.role')
      content=$(echo "$selected" | jq -r '.content')
      echo "[resending $role message]"
      run_bot "$content"
      continue
      ;;
  esac

  [[ -n "$user_text_trimmed" ]] && run_bot "$user_text_trimmed"
done

