# LiteLLM Streaming Bug with Guardrails

## The Problem

LiteLLM v1.80.11 crashes with a **500 Internal Server Error** when:
- A guardrail blocks content during the pre-call hook
- The request uses `stream: true`
- The guardrail uses `on_flagged_action: "passthrough"`

**Error:** `AttributeError: 'NoneType' object has no attribute 'model_call_details'`

---

## Why It Happens

**The sequence:**
1. Client sends request with `stream: true`
2. Guardrail blocks content in pre-call hook
3. LiteLLM raises `ModifyResponseException` to return blocked message
4. LiteLLM tries to create streaming response wrapper
5. **CRASH** - `litellm_logging_obj` is `None` because it's only created *after* pre-call hooks

**The broken code:**
```python
# proxy_server.py line 5105
_streaming_response = litellm.CustomStreamWrapper(
    logging_obj=data.get("litellm_logging_obj", None),  # ← Returns None!
)

# streaming_handler.py line 88
**self.logging_obj.model_call_details.get(...)  # ← Crashes!
```

---

## When Does It Break?

| Scenario | Works? |
|----------|--------|
| Non-streaming + guardrail blocks | ✅ Yes |
| Streaming + guardrail allows | ✅ Yes |
| Streaming + guardrail blocks | ❌ **500 Error** |

---

## Impact

**Who's affected:**
- OpenWebUI Arena Mode (always uses `stream=true`)
- OpenWebUI regular mode (typically uses `stream=true` for better UX)
- Any client requesting `stream=true`
- Any custom guardrail using `on_flagged_action: "passthrough"`

**Workarounds before our fix:**
1. ❌ Return 400 error instead (breaks some clients)
2. ❌ Add separate proxy layer (complexity)
3. ❌ Force `stream=false` globally (no progressive text display)

---

## Our Fix

**Patch location:** `patches/apply_litellm_fix.py`

**What it does:**
Initializes the missing `litellm_logging_obj` before creating the streaming wrapper

```python
# Applied at proxy_server.py line 5099
if data.get("litellm_logging_obj") is None:
    from litellm.litellm_core_utils.litellm_logging import Logging as LiteLLMLoggingObj
    data["litellm_logging_obj"] = LiteLLMLoggingObj(
        model=e.model,
        messages=[],
        stream=data.get("stream", False),
        call_type="acompletion",
        start_time=time.time(),
        litellm_call_id=str(uuid.uuid4()),
        function_id=str(uuid.uuid4()),
    )
```

**Applied automatically during Docker build:**
```dockerfile
COPY patches/apply_litellm_fix.py /tmp/
RUN python3 /tmp/apply_litellm_fix.py
```

---

## Reproduction

**Config:**
```yaml
# litellm_config.yaml
guardrails:
  - guardrail_name: "content-filter"
    litellm_params:
      mode: "pre_call"
      on_flagged_action: "passthrough"  # Required for bug
```

**Request:**
```bash
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{
    "model": "llama3-2-1b",
    "messages": [{"role": "user", "content": "blocked content"}],
    "stream": true  # Required for bug
  }'
```

**Result:**
- **Before patch:** 500 Internal Server Error
- **After patch:** 200 OK with blocked message ✅

---

## When to Remove Patch

**Check if LiteLLM fixes this upstream:**
1. Monitor releases at https://github.com/BerriAI/litellm
2. Test with newer versions
3. Update Dockerfile to remove `@sha256:...` pin
4. Remove patch application lines

**Currently pinned to:**
```dockerfile
FROM ghcr.io/berriai/litellm:main-latest@sha256:fff53d2f...
```

**After upstream fix:**
```dockerfile
FROM ghcr.io/berriai/litellm:main-latest
```

---

## Quick Reference

**Bug status:** Unresolved upstream (as of 2026-01-03)
**Affected version:** LiteLLM 1.80.11
**Our patch:** `patches/apply_litellm_fix.py`
**Applied:** Automatically during Docker build

**Files involved:**
- `Dockerfile` - Applies the patch
- `patches/apply_litellm_fix.py` - Patch script
- `config/litellm_config.yaml` - Guardrail config
- `config/custom_guardrail.py` - Uses passthrough mode
