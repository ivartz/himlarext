#!/usr/bin/env bash
set -euo pipefail

API_URL="http://158.39.201.249:4000/v1/chat/completions"
API_KEY="sk-proxy"
MODEL="my-agent"
CONVO_FILE="conversation.json"
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
NC='\033[0m' # No Color

usage() {
  cat <<EOF
Usage:
  $0                     # interactive mode
  $0 < input.txt         # read prompt from file/stdin
  echo "hello" | $0      # pipe prompt
  $0 --one-run "text"    # one run, direct input

Interactive commands:
  /show        -> show conversation pretty (colored, numbered)
  /save        -> save conversation
  /clear       -> clear conversation
  /clear <num> -> delete a saved conversation by number
  /clear all   -> delete all saved conversations
  /undo        -> remove last message
  /list        -> list saved conversations
  /load <num>  -> load saved conversation by number
  /payload     -> show last payload sent
  /history <n> -> resend user or assistant message #n
EOF
  exit 1
}

# ---- Non-interactive ephemeral mode ----
send_ephemeral() {
  local input="$1"
  local TMP_CONVO="$TMP_DIR/convo_tmp.json"
  echo "[]" > "$TMP_CONVO"

  echo "$input" > "$TMP_DIR/user_input.txt"
  jq -Rs '{role:"user", content:.}' "$TMP_DIR/user_input.txt" > "$TMP_DIR/user_message.json"
  jq -s '.[0] + [.[1]]' "$TMP_CONVO" "$TMP_DIR/user_message.json" > "$TMP_DIR/convo_tmp2.json"
  mv "$TMP_DIR/convo_tmp2.json" "$TMP_CONVO"

  jq -n --arg model "$MODEL" --slurpfile msgs "$TMP_CONVO" '{model:$model, messages:$msgs[0]}' > "$TMP_DIR/payload_tmp.json"

  curl -s -X POST "$API_URL" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @"$TMP_DIR/payload_tmp.json" | jq -r '.choices[0].message.content'
}

# ---- One-run mode ----
[[ $# -ge 2 && "$1" == "--one-run" ]] && { send_ephemeral "$2"; exit 0; }

# ---- Stdin/Pipes ----
if [ ! -t 0 ]; then
  input_text="$(cat)"
  [[ -n "$input_text" ]] && send_ephemeral "$input_text"
  exit 0
fi

[[ $# -ne 0 ]] && usage
[[ -f "$CONVO_FILE" ]] || echo "[]" > "$CONVO_FILE"
LAST_PAYLOAD_SENT=""

# ---- Functions ----
run_bot() {
  local input="$1"
  local user_file="$TMP_DIR/user_message.json"
  local bot_file="$TMP_DIR/bot_message.json"

  echo "$input" > "$TMP_DIR/user_input.txt"
  jq -Rs '{role:"user", content:.}' "$TMP_DIR/user_input.txt" > "$user_file"
  jq -s '.[0] + [.[1]]' "$CONVO_FILE" "$user_file" > "$TMP_DIR/conv_tmp.json"
  mv "$TMP_DIR/conv_tmp.json" "$CONVO_FILE"

  jq -n --arg model "$MODEL" --slurpfile msgs "$CONVO_FILE" '{model:$model, messages:$msgs[0]}' > "$PAYLOAD_FILE"
  LAST_PAYLOAD_SENT="$PAYLOAD_FILE"

  response=$(curl -s -X POST "$API_URL" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @"$PAYLOAD_FILE")
  #echo 'see here:'
  #echo "$response"
  #echo 'done'
  echo "$response" | jq -r '.choices[0].message.content' > "$TMP_DIR/bot_message.txt"
  bot_message=$(<"$TMP_DIR/bot_message.txt")

  echo
  echo "-> Bot: Output"
  [[ -z "$bot_message" ]] && echo "[no content in response]" || printf "%s\n" "$bot_message"
  echo

  if [[ -n "$bot_message" ]]; then
    echo "$bot_message" > "$TMP_DIR/bot_message_raw.txt"
    jq -Rs '{role:"assistant", content:.}' "$TMP_DIR/bot_message_raw.txt" > "$bot_file"
    jq -s '.[0] + [.[1]]' "$CONVO_FILE" "$bot_file" > "$TMP_DIR/conv_tmp.json"
    mv "$TMP_DIR/conv_tmp.json" "$CONVO_FILE"
  fi
}

list_conversations() {
  mapfile -t files < <(ls -1 "$SAVE_DIR"/conversation-*.json 2>/dev/null | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "[no saved conversations]"
    return
  fi
  echo "Saved conversations:"
  for i in "${!files[@]}"; do
    echo "$((i+1))) $(basename "${files[$i]}")"
  done
}

load_conversation() {
  local num="$1"
  mapfile -t files < <(ls -1 "$SAVE_DIR"/conversation-*.json 2>/dev/null | sort)
  if [[ $num -lt 1 || $num -gt ${#files[@]} ]]; then
    echo "[invalid number: $num]"
    return
  fi
  local file="${files[$((num-1))]}"
  jq -s '.[0] + .[1]' "$CONVO_FILE" "$file" > "$TMP_DIR/conv_tmp.json"
  mv "$TMP_DIR/conv_tmp.json" "$CONVO_FILE"
  echo "[loaded $(basename "$file") into current conversation]"
}

save_conversation() {
  timestamp=$(date +"%Y%m%d-%H%M%S")
  backup="$SAVE_DIR/conversation-$timestamp.json"
  cp "$CONVO_FILE" "$backup"
  echo "Conversation saved to $backup"
}

undo_message() {
  len=$(jq length "$CONVO_FILE")
  if (( len < 1 )); then
    echo "[nothing to undo]"
  else
    jq '.[0:-1]' "$CONVO_FILE" > "$TMP_DIR/conv_tmp.json"
    mv "$TMP_DIR/conv_tmp.json" "$CONVO_FILE"
    echo "[removed last message]"
  fi
}

# ---- Interactive loop ----
echo "Chat started."
while true; do
  echo
  echo "-> User: Input (multi-line OK). Special commands:"
  echo "  /show        -> show conversation pretty (colored, numbered)"
  echo "  /save        -> save conversation"
  echo "  /clear       -> clear conversation"
  echo "  /clear <num> -> delete a saved conversation by number"
  echo "  /clear all   -> delete all saved conversations"
  echo "  /undo        -> remove last message"
  echo "  /list        -> list saved conversations"
  echo "  /load <num>  -> load saved conversation by number"
  echo "  /payload     -> show last payload sent"
  echo "  /history <n> -> resend user or assistant message #n"
  echo "  Ctrl-D (EOF) -> send to bot / resend last payload if empty"
  echo

  user_input=""
  while IFS= read -r -e line; do
      user_input+="$line"$'\n'
  done || true

  user_text_trimmed="$(echo "$user_input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  case "$user_text_trimmed" in
    "/show")
      echo
      echo "-> Conversation (pretty & numbered)"
      len=$(jq length "$CONVO_FILE")
      if (( len == 0 )); then
        echo "[conversation empty]"
      else
        for idx in $(seq 0 $((len-1))); do
          msg=$(jq -c ".[$idx]" "$CONVO_FILE")
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
    "/save")
      save_conversation
      continue
      ;;
    "/payload")
      if [[ -n "$LAST_PAYLOAD_SENT" && -f "$LAST_PAYLOAD_SENT" ]]; then
        echo
        echo "-> Last Payload (raw):"
        cat "$LAST_PAYLOAD_SENT"
        echo
      else
        echo "[no payload sent yet]"
      fi
      continue
      ;;
    /history\ *)
      num="${user_text_trimmed#*/history }"
      if [[ "$num" =~ ^[0-9]+$ ]]; then
        len=$(jq length "$CONVO_FILE")
        if (( num < 1 || num > len )); then
          echo "[invalid message number: $num]"
          continue
        fi
        selected=$(jq -r ".[$((num-1))]" "$CONVO_FILE")
        role=$(echo "$selected" | jq -r '.role')
        content=$(echo "$selected" | jq -r '.content')
        echo "[resending $role message #$num]"
        run_bot "$content"
      else
        echo "[invalid /history number: $num]"
      fi
      continue
      ;;
    /clear*)
      arg="${user_text_trimmed#"/clear"}"
      arg="$(echo "$arg" | xargs)"
      if [[ -z "$arg" ]]; then
        echo "[]" > "$CONVO_FILE"
        echo "[current conversation cleared]"
      elif [[ "$arg" == "all" ]]; then
        rm -f "$SAVE_DIR"/conversation-*.json
        echo "[all saved conversations cleared]"
      elif [[ "$arg" =~ ^[0-9]+$ ]]; then
        mapfile -t files < <(ls -1 "$SAVE_DIR"/conversation-*.json 2>/dev/null | sort)
        if (( arg < 1 || arg > ${#files[@]} )); then
          echo "[invalid number: $arg]"
        else
          rm -f "${files[$((arg-1))]}"
          echo "[saved conversation $arg deleted]"
        fi
      else
        echo "[invalid /clear argument: $arg]"
      fi
      continue
      ;;
    "/undo")
      undo_message
      continue
      ;;
    "/list")
      list_conversations
      continue
      ;;
    /load\ *)
      num="${user_text_trimmed#*/load }"
      if [[ "$num" =~ ^[0-9]+$ ]]; then
        load_conversation "$num"
      else
        echo "[invalid load number: $num]"
      fi
      continue
      ;;
  esac

  if [[ -z "$user_text_trimmed" ]]; then
    if [[ -n "$LAST_PAYLOAD_SENT" && -f "$LAST_PAYLOAD_SENT" ]]; then
      echo "[resending last payload]"
      response=$(curl -s -X POST "$API_URL" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        --data-binary @"$LAST_PAYLOAD_SENT")

      echo
      echo "-> Bot: Output"
      bot_message=$(echo "$response" | jq -r '.choices[0].message.content')
      [[ -z "$bot_message" ]] && echo "[no content in response]" || printf "%s\n" "$bot_message"
      echo

      if [[ -n "$bot_message" ]]; then
        echo "$bot_message" > "$TMP_DIR/bot_message_raw.txt"
        jq -Rs '{role:"assistant", content:.}' "$TMP_DIR/bot_message_raw.txt" > "$TMP_DIR/bot_message.json"
        jq -s '.[0] + [.[1]]' "$CONVO_FILE" "$TMP_DIR/bot_message.json" > "$TMP_DIR/conv_tmp.json"
        mv "$TMP_DIR/conv_tmp.json" "$CONVO_FILE"
      fi
    else
      echo "[no input, nothing to send]"
    fi
    continue
  fi

  run_bot "$user_input"
done

