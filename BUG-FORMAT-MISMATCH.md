# LiteLLM Response Formats: JSON Dict vs SSE

## Overview

LiteLLM supports two different response formats that caused issues when implementing Arena Mode in OpenWebUI. This document explains the differences and why they matter.

---

## The Two Formats

### 1. JSON Dict Format (Non-Streaming)

**When used:** `stream: false`

**Structure:**
```json
{
  "id": "chatcmpl-123",
  "object": "chat.completion",
  "created": 1234567890,
  "model": "gpt-4",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Complete response here"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 10,
    "completion_tokens": 20,
    "total_tokens": 30
  }
}
```

**Key characteristics:**
- Single complete response
- Content at: `choices[0].message.content`
- Object type: `chat.completion`
- Content-Type: `application/json`

---

### 2. SSE Format (Streaming)

**When used:** `stream: true`

**Structure:**
```
data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4","choices":[{"index":0,"delta":{"role":"assistant","content":"First"},"finish_reason":null}]}

data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4","choices":[{"index":0,"delta":{"content":" chunk"},"finish_reason":null}]}

data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

**Key characteristics:**
- Multiple line-delimited chunks
- Content at: `choices[0].delta.content`
- Object type: `chat.completion.chunk`
- Content-Type: `text/event-stream`
- Terminates with `data: [DONE]`

---

## Key Differences Summary

| Aspect | JSON Dict | SSE Streaming |
|--------|-----------|---------------|
| Response count | Single | Multiple chunks |
| Content field | `message.content` | `delta.content` |
| Object type | `chat.completion` | `chat.completion.chunk` |
| Complete on receive | Yes | No (must concatenate) |
| HTTP Content-Type | `application/json` | `text/event-stream` |

---

## The Content Filtering Problem

### What Happened

1. **Streaming Behavior:**
   - **Arena Mode:** When enabled, OpenWebUI **always forces** `stream=true` for any model in the arena configuration
   - **Regular requests:** Clients (including OpenWebUI) typically request `stream=true` for better UX (progressive text display)
   - **Current state:** Arena Mode is **disabled**, but we still handle streaming requests from clients

2. **LiteLLM's Guardrail Hook Limitation:**
   - The `async_post_call_success_hook` only executes for **non-streaming** responses
   - Streaming responses bypass this hook entirely
   - This hook is where content filtering happens

3. **The Mismatch:**
   ```
   Client sends stream=true → SSE format → Hook skipped → No content filtering ❌
   ```

### Why Content Filtering Broke

**Non-streaming (works):**
```python
async def async_post_call_success_hook(data, response):
    content = response["choices"][0]["message"]["content"]  # ✅ Can check content
    if blocked_word in content:
        raise Exception("Blocked!")
```

**Streaming (broken):**
```python
async def async_post_call_success_hook(data, response):
    # ❌ This hook NEVER EXECUTES for streaming responses!
    # Content is sent directly to client in chunks
```

---

## The Solution

### Current Solution

**Force all responses to be non-streaming (regardless of client request):**

1. **In litellm_config.yaml:**
   ```yaml
   model_list:
     - model_name: gpt-4
       litellm_params:
         model: bedrock/us.anthropic.claude-3-5-sonnet-20241022-v2:0
         stream: false  # Default to non-streaming
   ```

2. **In guardrail pre-call hook:**
   ```python
   # Intercept and force stream=false for ALL requests
   # This ensures async_post_call_success_hook executes
   data['stream'] = False
   ```

3. **Arena Mode status:**
   ```dockerfile
   ENV ENABLE_EVALUATION_ARENA_MODELS=false  # Currently disabled
   ```

### Trade-offs

**Pros:**
- ✅ Content filtering works reliably
- ✅ Complete responses available for guardrails
- ✅ Simpler error handling

**Cons:**
- ❌ Higher latency (user waits for complete response)
- ❌ No progressive text display in UI
- ❌ Cannot use Arena Mode (would require streaming)

---

## Current State

**As of January 2026:**
- ✅ Arena Mode: **DISABLED** (`ENABLE_EVALUATION_ARENA_MODELS=false`)
- ✅ All models: Configured with `stream: false` in litellm_config.yaml
- ✅ Guardrail: Forces `stream: false` for ALL incoming requests (intercepts client `stream=true`)
- ✅ Result: All responses use JSON Dict format, content filtering works

**This means:**
- Clients can request `stream=true`, but guardrail forces it to `stream=false`
- All responses are complete JSON objects (not SSE streams)
- `async_post_call_success_hook` executes for every request
- Content filtering works reliably

---

## References

- **Config:** `litellm_config.yaml` - Model streaming settings
- **Guardrail:** `config/custom_guardrail.py` - Hook implementation
- **Bug:** `LITELLM-BUG.md` - Streaming exception handling issue
