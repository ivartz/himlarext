#!/usr/bin/env bash
set -euo pipefail

API_KEY="sk-proxy"
MODEL="my-agent"
CONV_FILE="conversation.json"
PAYLOAD_FILE="payload.json"
TMP_DIR="$(mktemp -d)"
SAVE_DIR="conversations"

mkdir -p "$SAVE_DIR"

cleanup() {
  rm -rf "$TMP_DIR" "$PAYLOAD_FILE"
}
trap cleanup EXIT
trap 'echo; echo "Interrupted. Exiting."; cleanup; exit 130' INT

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

usage() {
  cat <<EOF
Usage:
  $0                     # interactive mode
  $0 < input.txt         # read prompt from file/stdin
  echo "hello" | $0      # pipe prompt
  $0 --one-run "text"    # one run, direct input

Interactive commands:
  /show          -> show conversation pretty (colored, numbered)
  /save          -> save conversation
  /clear         -> clear conversation
  /clear <num>   -> delete a saved conversation by number
  /clear all     -> delete all saved conversations
  /undo          -> remove last user+assistant turn
  /list          -> list saved conversations
  /load <num>    -> load saved conversation by number
  /payload       -> show last payload sent
  /history <n>   -> resend user or assistant message #n
  /history last  -> resend last message (user or assistant)
EOF
  exit 1
}

# ---- Non-interactive ephemeral ----
send_ephemeral() {
  local input="$1"
  local tmp_convo="$TMP_DIR/convo_tmp.json"
  echo "[]" > "$tmp_convo"
  echo "$input" > "$TMP_DIR/user_input.txt"

  jq --rawfile content "$TMP_DIR/user_input.txt" \
     '. + [{"role":"user","content":$content}]' "$tmp_convo" > "$tmp_dir/conv_tmp2.json" || true
  mv "$tmp_dir/conv_tmp2.json" "$tmp_convo"

  jq -n --arg model "$MODEL" --slurpfile msgs "$tmp_convo" \
     '{model:$model, messages:$msgs[0]}' > "$TMP_DIR/payload_tmp.json"

  curl -s -X POST "http://158.39.201.249:4000/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @"$TMP_DIR/payload_tmp.json" | jq -r '.choices[0].message.content'
}

[[ $# -ge 2 && "$1" == "--one-run" ]] && { send_ephemeral "$2"; exit 0; }

if [ ! -t 0 ]; then
  input_text="$(cat)"
  [[ -n "$input_text" ]] && send_ephemeral "$input_text"
  exit 0
fi

[[ $# -ne 0 ]] && usage
[[ -f "$CONV_FILE" ]] || echo "[]" > "$CONV_FILE"
LAST_PAYLOAD_SENT=""

# ---- Functions ----
run_bot() {
  local input="$1"
  echo "$input" > "$TMP_DIR/user_input.txt"

  jq --rawfile content "$TMP_DIR/user_input.txt" \
     '. + [{"role":"user","content":$content}]' "$CONV_FILE" > "$TMP_DIR/conv_tmp.json"
  mv "$TMP_DIR/conv_tmp.json" "$CONV_FILE"

  jq -n --arg model "$MODEL" --slurpfile msgs "$CONV_FILE" \
     '{model:$model, messages:$msgs[0]}' > "$PAYLOAD_FILE"
  LAST_PAYLOAD_SENT="$PAYLOAD_FILE"

  response=$(curl -s -X POST "http://158.39.201.249:4000/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @"$PAYLOAD_FILE")

  bot_message=$(echo "$response" | jq -r '.choices[0].message.content')
  echo
  echo "-> Bot: Output"
  [[ -z "$bot_message" ]] && echo "[no content in response]" || printf "%s\n" "$bot_message"
  echo

  if [[ -n "$bot_message" ]]; then
    echo "$bot_message" > "$TMP_DIR/bot_message_raw.txt"
    jq --rawfile content "$TMP_DIR/bot_message_raw.txt" \
       '. + [{"role":"assistant","content":$content}]' "$CONV_FILE" > "$TMP_DIR/conv_tmp.json"
    mv "$TMP_DIR/conv_tmp.json" "$CONV_FILE"
  fi
}

list_convos() {
  local files=("$SAVE_DIR"/conversation-*.json)
  [[ -e "${files[0]}" ]] || { echo "[no saved conversations]"; return; }
  local i=1
  for f in "${files[@]}"; do
    echo "$i) $(basename "$f")"
    ((i++))
  done
}

load_convo() {
  local num="$1"
  local files=("$SAVE_DIR"/conversation-*.json)
  [[ -e "${files[0]}" ]] || { echo "[no saved conversations]"; return; }
  if (( num < 1 || num > ${#files[@]} )); then
    echo "[invalid number: $num]"
    return
  fi
  local file="${files[$((num-1))]}"
  jq -s '.[0] + .[1]' "$CONV_FILE" "$file" > "$TMP_DIR/conv_tmp.json"
  mv "$TMP_DIR/conv_tmp.json" "$CONV_FILE"
  echo "[loaded $(basename "$file") into current conversation]"
}

save_convo() {
  local ts
  ts=$(date +"%Y%m%d-%H%M%S")
  local backup="$SAVE_DIR/conversation-$ts.json"
  cp "$CONV_FILE" "$backup"
  echo "Conversation saved to $backup"
}

undo_turn() {
  local len
  len=$(jq length "$CONV_FILE")
  if (( len < 2 )); then
    echo "[nothing to undo]"
  else
    jq '.[0:-2]' "$CONV_FILE" > "$TMP_DIR/conv_tmp.json"
    mv "$TMP_DIR/conv_tmp.json" "$CONV_FILE"
    echo "[last user+assistant turn removed]"
  fi
}

# ---- Interactive loop ----
echo "Chat started."
while true; do
  echo
  echo "-> User: Input (multi-line OK). Special commands:"
  echo "  /show, /save, /clear, /undo, /list, /load <n>, /payload, /history <n>, /history last"
  echo "  Ctrl-D (EOF) -> send / resend last payload"
  echo "  Ctrl-C       -> exit"
  echo

  user_input=""
  while IFS= read -r line; do
    user_input+="$line"$'\n'
  done || true
  user_text_trimmed="$(echo "$user_input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  case "$user_text_trimmed" in
    "/show")
      echo
      echo "-> Conversation"
      len=$(jq length "$CONV_FILE")
      if (( len == 0 )); then
        echo "[empty]"
      else
        for idx in $(seq 0 $((len-1))); do
          msg=$(jq -c ".[$idx]" "$CONV_FILE")
          role=$(echo "$msg" | jq -r '.role')
          content=$(echo "$msg" | jq -r '.content')
          num=$((idx+1))
          if [[ "$role" == "user" ]]; then
            echo -e "${RED}[$num][user]:${NC}"
          else
            echo -e "${GREEN}[$num][assistant]:${NC}"
          fi
          echo "$content"
          echo
        done
      fi
      continue
      ;;
    "/save") save_convo; continue ;;
    "/payload")
      if [[ -n "$LAST_PAYLOAD_SENT" && -f "$LAST_PAYLOAD_SENT" ]]; then
        echo; cat "$LAST_PAYLOAD_SENT"; echo
      else
        echo "[no payload yet]"
      fi
      continue
      ;;
    /history\ *)
      num="${user_text_trimmed#*/history }"
      len=$(jq length "$CONV_FILE")
      if [[ "$num" == "last" ]]; then
        num=$len
      fi
      if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= len )); then
        content=$(jq -r ".[$((num-1))].content" "$CONV_FILE")
        role=$(jq -r ".[$((num-1))].role" "$CONV_FILE")
        echo "[resending $role message #$num]"
        run_bot "$content"
      else
        echo "[invalid /history arg: $num]"
      fi
      continue
      ;;
    "/undo") undo_turn; continue ;;
    "/list") list_convos; continue ;;
    /load\ *) load_convo "${user_text_trimmed#*/load }"; continue ;;
    /clear*)
      arg="${user_text_trimmed#"/clear"}"; arg="$(echo "$arg" | xargs)"
      if [[ -z "$arg" ]]; then
        echo "[]" > "$CONV_FILE"; echo "[current cleared]"
      elif [[ "$arg" == "all" ]]; then
        rm -f "$SAVE_DIR"/conversation-*.json; echo "[all cleared]"
      elif [[ "$arg" =~ ^[0-9]+$ ]]; then
        local files=("$SAVE_DIR"/conversation-*.json)
        if (( arg < 1 || arg > ${#files[@]} )); then
          echo "[invalid number: $arg]"
        else
          rm -f "${files[$((arg-1))]}"; echo "[conversation $arg deleted]"
        fi
      fi
      continue
      ;;
  esac

  if [[ -z "$user_text_trimmed" ]]; then
    if [[ -n "$LAST_PAYLOAD_SENT" && -f "$LAST_PAYLOAD_SENT" ]]; then
      echo "[resending last payload]"
      response=$(curl -s -X POST "http://158.39.201.249:4000/v1/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        --data-binary @"$LAST_PAYLOAD_SENT")
      bot_message=$(echo "$response" | jq -r '.choices[0].message.content')
      echo; echo "-> Bot: Output"; [[ -z "$bot_message" ]] && echo "[no content]" || echo "$bot_message"; echo
      if [[ -n "$bot_message" ]]; then
        echo "$bot_message" > "$TMP_DIR/bot_message_raw.txt"
        jq --rawfile content "$TMP_DIR/bot_message_raw.txt" \
           '. + [{"role":"assistant","content":$content}]' "$CONV_FILE" > "$TMP_DIR/conv_tmp.json"
        mv "$TMP_DIR/conv_tmp.json" "$CONV_FILE"
      fi
    else
      echo "[nothing to send]"
    fi
    continue
  fi

  run_bot "$user_input"
done

