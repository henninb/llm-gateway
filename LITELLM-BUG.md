# LiteLLM Bug: ModifyResponseException in Pre-Call Hooks with Streaming

## Summary

LiteLLM v1.80.11 has a bug where `ModifyResponseException` raised from pre-call guardrail hooks causes a 500 Internal Server Error for streaming requests due to a missing `litellm_logging_obj`.

## Bug Details

**Affected Versions**: LiteLLM 1.80.11 (possibly earlier versions, tested on 1.80.11)
**Docker Image**: `ghcr.io/berriai/litellm:main-v1.80.11` (pinned in Dockerfile)
**Component**: `/usr/lib/python3.13/site-packages/litellm/proxy/proxy_server.py`
**Line**: 5105-5109
**Error**: `AttributeError: 'NoneType' object has no attribute 'model_call_details'`
**Status**: Unresolved upstream as of 2026-01-03
**Patch Applied**: Yes, automatically during Docker build via `patches/apply_litellm_fix.py`

## Root Cause

When a custom guardrail raises `ModifyResponseException` during the pre-call hook with `on_flagged_action: "passthrough"`, the exception is caught at line 5088 in `proxy_server.py`. However, for streaming requests, the code attempts to create a `CustomStreamWrapper` with:

```python
_streaming_response = litellm.CustomStreamWrapper(
    completion_stream=_iterator,
    model=e.model,
    custom_llm_provider="cached_response",
    logging_obj=data.get("litellm_logging_obj", None),  # ← Returns None
)
```

The `litellm_logging_obj` doesn't exist in `data` during pre-call hooks because it's only initialized later in the request processing pipeline. When `CustomStreamWrapper.__init__` tries to access `self.logging_obj.model_call_details`, it fails with `AttributeError` because `logging_obj` is `None`.

## Stack Trace

```
File "/usr/lib/python3.13/site-packages/litellm/proxy/proxy_server.py", line 5105, in chat_completion
    _streaming_response = litellm.CustomStreamWrapper(
        completion_stream=_iterator,
        model=e.model,
        custom_llm_provider="cached_response",
        logging_obj=data.get("litellm_logging_obj", None),
    )
File "/usr/lib/python3.13/site-packages/litellm/litellm_core_utils/streaming_handler.py", line 88, in __init__
    **self.logging_obj.model_call_details.get("litellm_params", {})
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
AttributeError: 'NoneType' object has no attribute 'model_call_details'
```

## Reproduction

### Configuration

**litellm_config.yaml:**
```yaml
guardrails:
  - guardrail_name: "duckies-bunnies-detector"
    litellm_params:
      guardrail: custom_guardrail.DuckiesBunniesGuardrail
      mode: "pre_call"
      default_on: true
      on_flagged_action: "passthrough"  # Enable passthrough mode
```

**custom_guardrail.py:**
```python
class DuckiesBunniesGuardrail(CustomGuardrail):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        # Check for blocked content
        if contains_blocked_content(data["messages"][-1]["content"]):
            # Raise passthrough exception
            self.raise_passthrough_exception(
                violation_message="⚠️ BLOCKED: Your message contains blocked content.",
                request_data=data
            )
        return data
```

### Request

```bash
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{
    "model": "llama3-2-3b",
    "messages": [{"role": "user", "content": "blocked content"}],
    "stream": true  # ← Bug only occurs with streaming
  }'
```

### Expected Behavior

- HTTP 200 OK
- Streaming response with violation message
- `finish_reason: "content_filter"`

### Actual Behavior

- HTTP 500 Internal Server Error
- Exception: `AttributeError: 'NoneType' object has no attribute 'model_call_details'`

## Non-Streaming Behavior

✅ **Non-streaming requests work correctly** - The same guardrail with `"stream": false` returns HTTP 200 with the violation message as expected.

## Impact

- Custom guardrails with `on_flagged_action: "passthrough"` cannot be used with streaming requests
- This affects any client that uses streaming by default (OpenWebUI, many chat interfaces)
- Forces developers to either:
  1. Use `BadRequestError` (returns 400, breaks some clients)
  2. Implement a separate proxy layer to transform responses
  3. Disable streaming globally

## Comparison with Working Guardrails

The official `grayswan` guardrail uses the same pattern:

```python
# From /usr/lib/python3.13/site-packages/litellm/proxy/guardrails/guardrail_hooks/grayswan/grayswan.py
if hook_type in [GuardrailEventHooks.pre_call, GuardrailEventHooks.during_call]:
    self.raise_passthrough_exception(
        violation_message=violation_message,
        request_data=data,
        detection_info=detection_info,
    )
```

This confirms that the pattern is intended to work, but the streaming handler has a bug.

## Our Fix

We apply a patch during Docker build that initializes `litellm_logging_obj` before creating `CustomStreamWrapper`.

**Location**: `patches/apply_litellm_fix.py`

The Python script automatically patches `/usr/lib/python3.13/site-packages/litellm/proxy/proxy_server.py` by inserting the following code after line 5099 (`_chat_response.choices[0].finish_reason = "content_filter"`):

```python
# FIX: Initialize litellm_logging_obj if it doesn't exist (for pre-call guardrail exceptions)
# This fixes AttributeError when ModifyResponseException is raised from pre-call hooks with streaming
if data.get("litellm_logging_obj") is None:
    import time
    import uuid
    from litellm.litellm_core_utils.litellm_logging import Logging as LiteLLMLoggingObj
    data["litellm_logging_obj"] = LiteLLMLoggingObj(
        model=e.model,
        messages=[],  # No messages sent to LLM (blocked by guardrail)
        stream=data.get("stream", False),
        call_type="acompletion",
        start_time=time.time(),
        litellm_call_id=str(uuid.uuid4()),
        function_id=str(uuid.uuid4()),
    )
```

**Applied via Dockerfile:**
```dockerfile
# Apply fix for ModifyResponseException streaming bug in LiteLLM 1.80.11
# See LITELLM-BUG.md for details
COPY patches/apply_litellm_fix.py /tmp/
RUN python3 /tmp/apply_litellm_fix.py && rm /tmp/apply_litellm_fix.py
```

Build output confirms successful patching:
```
✅ Fix applied at line 5099
✅ Successfully patched /usr/lib/python3.13/site-packages/litellm/proxy/proxy_server.py
```

## Testing the Fix

After applying the patch:

```bash
# Test streaming with blocked content
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{
    "model": "llama3-2-3b",
    "messages": [{"role": "user", "content": "Tell me about duckies"}],
    "stream": true
  }'

# Expected: HTTP 200 OK with SSE stream containing blocked message
# Actual before patch: HTTP 500 Internal Server Error
# Actual after patch: HTTP 200 OK ✅
```

## When to Remove This Patch

Monitor LiteLLM releases for a fix to this issue. Once LiteLLM properly handles `ModifyResponseException` in pre-call hooks for streaming requests:

1. **Update Dockerfile**: Change `FROM ghcr.io/berriai/litellm:main-v1.80.11` to the fixed version (e.g., `:main-latest` or specific newer version)
2. **Remove patch lines** from Dockerfile (lines that copy and run `apply_litellm_fix.py`)
3. **Test thoroughly** to ensure the bug is actually fixed upstream
4. **Delete patch files**: `patches/apply_litellm_fix.py` (optional, can keep for reference)

## Related Files

**LiteLLM Source (affected by bug):**
- `/usr/lib/python3.13/site-packages/litellm/proxy/proxy_server.py` (lines 5088-5120)
- `/usr/lib/python3.13/site-packages/litellm/litellm_core_utils/streaming_handler.py` (line 88)
- `/usr/lib/python3.13/site-packages/litellm/integrations/custom_guardrail.py` (lines 138-174)

**Our Project Files (implementing fix):**
- `Dockerfile` - Pins to v1.80.11 and applies the patch
- `patches/apply_litellm_fix.py` - Python script that patches proxy_server.py
- `config/litellm_config.yaml` - Contains `on_flagged_action: "passthrough"`
- `config/custom_guardrail.py` - Uses `raise_passthrough_exception()`
- `LITELLM-BUG.md` - This documentation

## Upstream Issue

Consider filing an issue with LiteLLM to get this fixed upstream:
- **Repository**: https://github.com/BerriAI/litellm
- **Title suggestion**: "ModifyResponseException in pre-call hooks causes 500 error for streaming requests"
- **Include**: This documentation, reproduction steps, and our proposed fix
- **Reference**: Custom guardrails with `on_flagged_action: "passthrough"` + streaming

## References

- LiteLLM CustomGuardrail documentation: Uses `raise_passthrough_exception()` in examples
- LiteLLM GitHub: https://github.com/BerriAI/litellm
- LiteLLM version: 1.80.11
- Docker image: `ghcr.io/berriai/litellm:main-v1.80.11`
- Python version: 3.13
- Issue discovered: 2026-01-03
- Patch implemented: 2026-01-03
