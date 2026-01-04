# Known Issues

This document tracks known issues, bugs, and limitations in the LLM Gateway project.

## LiteLLM TypeError in Service Logger (Non-Blocking)

**Status**: Open
**Severity**: Low (Non-blocking, cosmetic)
**Impact**: Log noise only, no functional impact
**First Observed**: 2026-01-04

### Description

LiteLLM's internal service logger throws a `TypeError` when processing requests that are blocked by custom guardrails using `ModifyResponseException`.

### Error Message

```
LiteLLM.LoggingError: [Non-Blocking] Exception occurred while success logging
Traceback (most recent call last):
  File "/usr/lib/python3.13/site-packages/litellm/litellm_core_utils/litellm_logging.py", line 2525, in async_success_handler
    await callback.async_log_success_event(...)
  File "/usr/lib/python3.13/site-packages/litellm/_service_logger.py", line 314, in async_log_success_event
    raise e
  File "/usr/lib/python3.13/site-packages/litellm/_service_logger.py", line 297, in async_log_success_event
    _duration = end_time - start_time
                ~~~~~~~~~^~~~~~~~~~~~
TypeError: unsupported operand type(s) for -: 'datetime.datetime' and 'float'
```

### When It Occurs

This error occurs specifically when:
1. A custom guardrail (e.g., `DuckiesBunniesGuardrail`) raises `ModifyResponseException` to block a request
2. LiteLLM's service logger attempts to calculate request duration for metrics
3. The `start_time` is stored as a float but `end_time` is a datetime object

### Root Cause

Bug in LiteLLM's internal service logger (`_service_logger.py:297`). When handling custom guardrail exceptions, LiteLLM mixes data types for timing metadata:
- `end_time`: `datetime.datetime` object
- `start_time`: `float` (Unix timestamp)

This type mismatch causes the subtraction operation to fail.

### Impact Assessment

- **Functional Impact**: None - marked as `[Non-Blocking]`
- **User Experience**: No impact - requests are properly blocked/allowed
- **Guardrail Functionality**: Working correctly - all blocking/filtering logic functions as expected
- **Metrics**: Some internal LiteLLM metrics for blocked requests may not be recorded
- **Logs**: Creates ERROR messages in logs (cosmetic issue)

### Affected Components

- Custom guardrail: `config/custom_guardrail.py` (DuckiesBunniesGuardrail)
- LiteLLM service logger (upstream dependency)
- Occurs when guardrail calls `self.raise_passthrough_exception()`

### Workaround

None needed - this is a non-blocking error that does not affect functionality.

### Potential Solutions

1. **Wait for upstream fix** (Recommended)
   - Report to LiteLLM: https://github.com/BerriAI/litellm/issues
   - Check if already reported in LiteLLM issue tracker
   - This is a bug in LiteLLM's internal code

2. **Suppress error logging** (Not recommended)
   - Could filter these specific errors in logging config
   - Would hide potentially useful diagnostic information
   - Only consider if log volume becomes problematic

3. **Patch LiteLLM locally** (Not recommended)
   - Would require maintaining a fork or monkey-patching
   - Would break on LiteLLM updates
   - Overkill for a cosmetic issue

### Next Steps

- [ ] Search LiteLLM GitHub issues for existing reports
- [ ] Report to LiteLLM if not already tracked
- [ ] Monitor for fix in future LiteLLM releases
- [ ] Update this document when resolved

### References

- LiteLLM source: `/usr/lib/python3.13/site-packages/litellm/_service_logger.py:297`
- Custom guardrail: `config/custom_guardrail.py`
- Test script: `tools/test-guardrails.sh`

### Example Occurrence

```
🔍 DuckiesBunniesGuardrail: async_pre_call_hook CALLED! call_type=acompletion
⚠️ DuckiesBunniesGuardrail: MATCH FOUND in latest message! Pattern=\bduck(y|ies?|s)?\b
⚠️ DuckiesBunniesGuardrail: BLOCKING request - raising ModifyResponseException
INFO:     10.0.11.105:59174 - "POST /v1/chat/completions HTTP/1.1" 200 OK
13:29:59 - LiteLLM:ERROR: litellm_logging.py:2609 - LiteLLM.LoggingError: [Non-Blocking] Exception occurred while success logging
```

Note: Request completes successfully (200 OK) and guardrail blocks correctly. Error is purely in metrics logging.
