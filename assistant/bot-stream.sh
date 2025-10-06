#!/bin/bash
: '
Usage:
  ./bot.sh
  ./bot.sh < input.txt        # read prompt from file/stdin
  echo "hello" | ./bot.sh     # pipe prompt
  ./bot.sh --one-run "text"   # one run, direct input
'

API_URL="http://158.39.201.249:4000/v1/chat/completions"
API_KEY="sk-proxy"
MODEL="my-agent"

one_run=""
conversation_json="$(mktemp)"   # JSON array of messages

cleanup() {
  rm -f "$conversation_json" payload.json
}
trap cleanup EXIT

# Initialize conversation file
echo "[]" > "$conversation_json"

# Parse args
if [ "$1" == "--one-run" ]; then
  one_run=1
  shift
fi

# Load input from arg, stdin, or nothing
if [ -n "$1" ]; then
  jq --arg text "$1" '. += [{"role":"user","content":$text}]' "$conversation_json" > tmp.json && mv tmp.json "$conversation_json"
elif [ ! -t 0 ]; then
  text="$(cat)"
  jq --arg text "$text" '. += [{"role":"user","content":$text}]' "$conversation_json" > tmp.json && mv tmp.json "$conversation_json"
fi

send_to_bot() {
  jq -n \
    --arg model "$MODEL" \
    --slurpfile msgs "$conversation_json" \
    '{model:$model, stream:true, messages:$msgs[0]}' > payload.json

  response=""
  curl -sN "$API_URL" \
    -H "Authorization: Bearer '"$API_KEY"'" \
    -H "Content-Type: application/json" \
    --data-binary @payload.json |
    while IFS= read -r line; do
      if [[ "$line" =~ ^data: ]]; then
        data="${line#data: }"
        [[ "$data" == "[DONE]" ]] && break
        content=$(jq -r '.choices[0].delta.content // empty' <<< "$data")
        if [ -n "$content" ]; then
          printf "%s" "$content"
          response+="$content"
        fi
      fi
    done
  echo

  if [ -n "$response" ]; then
    jq --arg text "$response" '. += [{"role":"assistant","content":$text}]' "$conversation_json" > tmp.json && mv tmp.json "$conversation_json"
  fi
}

# If one-run mode
if [ -n "$one_run" ]; then
  send_to_bot
  exit
fi

# Interactive loop
while true; do
  echo
  echo "-> User: Input (multi-line OK). Special commands:"
  echo "  /show        -> show conversation JSON"
  echo "  /clear       -> clear conversation"
  echo "  /undo        -> remove last message"
  echo "  Ctrl-D (EOF) -> send to bot"
  echo "  Ctrl-C       -> exit"
  echo

  user_input=""
  while IFS= read -r line; do
    case "$line" in
      "/show")
        jq . "$conversation_json"
        ;;
      "/clear")
        echo "[]" > "$conversation_json"
        echo "[conversation cleared]"
        ;;
      "/undo")
        jq 'if length>0 then del(.[-1]) else . end' "$conversation_json" > tmp.json && mv tmp.json "$conversation_json"
        echo "[last message removed]"
        ;;
      *)
        if [ -z "$user_input" ]; then
          user_input="$line"
        else
          user_input="$user_input\n$line"
        fi
        ;;
    esac
  done

  if [ -n "$user_input" ]; then
    jq --arg text "$user_input" '. += [{"role":"user","content":$text}]' "$conversation_json" > tmp.json && mv tmp.json "$conversation_json"
  fi

  echo
  echo "-> Bot: Output"
  echo
  send_to_bot
done

