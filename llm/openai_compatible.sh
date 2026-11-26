#!/usr/bin/env bash
# LLM adapter for any OpenAI-compatible chat completions endpoint.
# Reads the prompt on standard input and prints the model's reply.
#
#   export ASS_LLM_CMD="$PWD/llm/openai_compatible.sh"
#   export ASS_LLM_BASE_URL="https://your-provider.example/v1"   # must be https
#   export ASS_LLM_API_KEY="..."
#   export ASS_LLM_MODEL="your-model-name"
#
# Temperature and token budget come from ASS_LLM_TEMPERATURE (default 0.3) and
# ASS_LLM_MAX_TOKENS (default 2000), the values used in the paper.
set -eu
: "${ASS_LLM_BASE_URL:?set ASS_LLM_BASE_URL}"
: "${ASS_LLM_API_KEY:?set ASS_LLM_API_KEY}"
: "${ASS_LLM_MODEL:?set ASS_LLM_MODEL}"
case "$ASS_LLM_BASE_URL" in https://*) ;; *) echo "ASS_LLM_BASE_URL must use https" >&2; exit 1 ;; esac

prompt="$(cat)"
# The system role is kept separate from everything else (prompt isolation).
system="$(printf '%s\n' "$prompt" | awk '/^### SYSTEM$/{f=1;next} /^### CONSTRAINTS$/{f=0} f')"
user="$(printf '%s\n' "$prompt" | awk '/^### CONSTRAINTS$/{f=1} f')"

jq -n --arg model "$ASS_LLM_MODEL" --arg system "$system" --arg user "$user" \
      --argjson temperature "${ASS_LLM_TEMPERATURE:-0.3}" --argjson max_tokens "${ASS_LLM_MAX_TOKENS:-2000}" \
  '{model:$model,temperature:$temperature,max_tokens:$max_tokens,
    messages:[{role:"system",content:$system},{role:"user",content:$user}]}' \
| curl -sS --fail --max-time 120 "$ASS_LLM_BASE_URL/chat/completions" \
    -H "Authorization: Bearer $ASS_LLM_API_KEY" -H "Content-Type: application/json" -d @- \
| jq -er '.choices[0].message.content'
