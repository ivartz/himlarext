#!/usr/bin/env bash
set -euo pipefail

API_KEY="sk-proxy"
MODEL="my-agent"
CONVO_FILE="conversation.json"
PAYLOAD_FILE="payload.json"
TMP_FILE="$(mktemp)"
TMP_OUT="$(mktemp)"
SAVE_DIR="conversations"

mkdir -p "$SAVE_DIR"

cleanup() {
  rm -f "$TMP_FILE" "$TMP_OUT" "$PAYLOAD_FILE"
}
trap cleanup EXIT
trap 'echo; echo "Interrupted. Exiting."; cleanup; exit 130' INT

usage() {
  cat <<EOF
Usage:
  $0                     # interactive mode
  $0 < input.txt         # read prompt from file/stdin
  echo "hello" | $0      # pipe prompt
  $0 --one-run "text"    # one run, direct input

Interactive commands:
  /show          -> show conversation JSON
  /save          -> backup conversation
  /clear         -> clear conversation
  /undo          -> remove last user+assistant turn
  /list          -> list saved conversations
  /load <num>    -> load saved conversation by number
EOF
  exit 1
}

# Initialize conversation file if missing
[[ -f "$CONVO_FILE" ]] || echo "[]" > "$CONVO_FILE"

# ---- Functions ----
run_bot() {
  local input="$1"

  # Append user message
  jq ". + [{\"role\": \"user\", \"content\": $(jq -Rs . <<<"$input") }]" "$CONVO_FILE" > "$TMP_OUT"
  mv "$TMP_OUT" "$CONVO_FILE"

  # Build payload with full conversation
  jq -n --arg model "$MODEL" --slurpfile msgs "$CONVO_FILE" \
    '{model: $model, messages: $msgs[0]}' > "$PAYLOAD_FILE"

  # Call backend
  response=$(curl -s -X POST "http://158.39.201.249:4000/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @"$PAYLOAD_FILE")

  bot_message=$(echo "$response" | jq -r '.choices[0].message.content')

  echo
  echo "-> Bot: Output"
  [[ -z "$bot_message" ]] && echo "[no content in response]" || printf "%s\n" "$bot_message"
  echo

  # Append bot message
  [[ -n "$bot_message" ]] && jq ". + [{\"role\": \"assistant\", \"content\": $(jq -Rs . <<<"$bot_message") }]" "$CONVO_FILE" > "$TMP_OUT" && mv "$TMP_OUT" "$CONVO_FILE"
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
  jq -s 'add' "$CONVO_FILE" "$file" > "$TMP_OUT"
  mv "$TMP_OUT" "$CONVO_FILE"
  echo "[loaded $(basename "$file") into current conversation]"
}

save_conversation() {
  timestamp=$(date +"%Y%m%d-%H%M%S")
  backup="$SAVE_DIR/conversation-$timestamp.json"
  cp "$CONVO_FILE" "$backup"
  echo "Conversation saved to $backup"
}

undo_turn() {
  len=$(jq length "$CONVO_FILE")
  if (( len < 2 )); then
    echo "[nothing to undo]"
  else
    jq '.[0:-2]' "$CONVO_FILE" > "$TMP_OUT"
    mv "$TMP_OUT" "$CONVO_FILE"
    echo "[last user+assistant turn removed]"
  fi
}

# ---- One-run mode ----
[[ $# -ge 2 && "$1" == "--one-run" ]] && { run_bot "$2"; exit 0; }

# ---- Stdin/Pipes ----
if [ ! -t 0 ]; then
  input_text="$(cat)"
  [[ -n "$input_text" ]] && run_bot "$input_text"
  exit 0
fi

[[ $# -ne 0 ]] && usage

echo "Chat started."
echo

while true; do
  echo
  echo "-> User: Input (multi-line OK). Special commands:"
  echo "  /show        -> show conversation JSON"
  echo "  /save        -> backup conversation"
  echo "  /clear       -> clear conversation"
  echo "  /undo        -> remove last user+assistant turn"
  echo "  /list        -> list saved conversations"
  echo "  /load <num>  -> load saved conversation by number"
  echo "  Ctrl-D (EOF) -> send to bot"
  echo "  Ctrl-C       -> exit"
  echo

  user_input=""
  echo "Enter your message (Ctrl-D to send, arrow keys/backspace work):"
  while IFS= read -r -e line; do
    user_input+="$line"$'\n'
  done

  user_text_trimmed=$(echo "$user_input" | xargs -0)

  case "$user_text_trimmed" in
    "/show")
      echo
      echo "-> Conversation JSON"
      [[ "$(jq length "$CONVO_FILE")" -eq 0 ]] && echo "[conversation empty]" || jq . "$CONVO_FILE"
      continue
      ;;
    "/save")
      save_conversation
      continue
      ;;
    "/clear")
      echo "[]" > "$CONVO_FILE"
      echo "[conversation cleared]"
      continue
      ;;
    "/undo")
      undo_turn
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

  [[ -z "$user_text_trimmed" ]] && continue
  run_bot "$user_input"
done

