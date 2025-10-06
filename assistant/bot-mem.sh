#!/usr/bin/env bash
set -euo pipefail

API_KEY="sk-proxy"
MODEL="my-agent"
CONVO_FILE="conversation.json"
PAYLOAD_FILE="payload.json"
TMP_FILE="$(mktemp)"
TMP_OUT="$(mktemp)"

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
  /show   -> show conversation JSON
  /clear  -> backup + clear conversation
  /undo   -> remove last user+assistant turn
EOF
  exit 1
}

# Initialize conversation file if missing
if [[ ! -f "$CONVO_FILE" ]]; then
  echo "[]" > "$CONVO_FILE"
fi

run_bot() {
  local input="$1"

  # Append user message
  jq ". + [{\"role\": \"user\", \"content\": $(jq -Rs . <<<"$input") }]" "$CONVO_FILE" > "$TMP_OUT"
  mv "$TMP_OUT" "$CONVO_FILE"

  # Build payload with full conversation
  jq -n --arg model "$MODEL" --slurpfile msgs "$CONVO_FILE" \
    '{model: $model, messages: $msgs[0]}' > "$PAYLOAD_FILE"

  # Call API
  response=$(curl -s -X POST "http://158.39.201.249:4000/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @"$PAYLOAD_FILE")

  bot_message=$(echo "$response" | jq -r '.choices[0].message.content')

  echo
  echo "-> Bot: Output"
  echo
  if [[ -z "$bot_message" ]]; then
    echo "[no content in response]"
  else
    printf "%s\n" "$bot_message"
  fi
  echo

  # Append assistant reply to conversation
  if [[ -n "$bot_message" ]]; then
    jq ". + [{\"role\": \"assistant\", \"content\": $(jq -Rs . <<<"$bot_message") }]" "$CONVO_FILE" > "$TMP_OUT"
    mv "$TMP_OUT" "$CONVO_FILE"
  fi
}

# ---- One-run mode ----
if [[ $# -ge 2 && "$1" == "--one-run" ]]; then
  run_bot "$2"
  exit 0
fi

# ---- Handle stdin/pipes ----
if [ ! -t 0 ]; then
  input_text="$(cat)"
  [[ -n "$input_text" ]] && run_bot "$input_text"
  exit 0
fi

# ---- Interactive mode ----
if [[ $# -ne 0 ]]; then
  usage
fi

echo "Chat started."
echo

while true; do
  echo
  echo "-> User: Input (multi-line OK). Special commands:"
  echo "  /show        -> show conversation JSON"
  echo "  /clear       -> backup + clear conversation"
  echo "  /undo        -> remove last user+assistant turn"
  echo "  Ctrl-D (EOF) -> send to bot"
  echo "  Ctrl-C       -> exit"
  echo

  if ! cat > "$TMP_FILE"; then
    echo -e "\nExiting."
    exit 0
  fi

  user_text="$(<"$TMP_FILE")"
  user_text_trimmed=$(echo "$user_text" | xargs -0)

  case "$user_text_trimmed" in
    "/show")
      echo
      echo "-> Conversation JSON"
      if [[ "$(jq length "$CONVO_FILE")" -eq 0 ]]; then
        echo "[conversation empty]"
      else
        jq . "$CONVO_FILE"
      fi
      continue
      ;;
    "/clear")
      timestamp=$(date +"%Y%m%d-%H%M%S")
      backup="conversation-$timestamp.json"
      cp "$CONVO_FILE" "$backup"
      echo "Conversation saved to $backup"
      echo "[]" > "$CONVO_FILE"
      echo "[conversation cleared]"
      continue
      ;;
    "/undo")
      len=$(jq length "$CONVO_FILE")
      if (( len < 2 )); then
        echo "[nothing to undo]"
      else
        jq '.[0:-2]' "$CONVO_FILE" > "$TMP_OUT"
        mv "$TMP_OUT" "$CONVO_FILE"
        echo "[last user+assistant turn removed]"
      fi
      continue
      ;;
  esac

  [[ -z "$user_text_trimmed" ]] && continue

  run_bot "$user_text"
done

