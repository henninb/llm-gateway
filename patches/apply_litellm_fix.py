#!/usr/bin/env python3
"""
Apply fix for LiteLLM ModifyResponseException streaming bug
See: docs/litellm-bug-modifyresponseexception-streaming.md
"""

import sys

PROXY_SERVER_PATH = "/usr/lib/python3.13/site-packages/litellm/proxy/proxy_server.py"

# The code to insert after the line: _chat_response.choices[0].finish_reason = "content_filter"
FIX_CODE = '''
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
'''

def apply_fix():
    """Apply the fix to proxy_server.py"""
    try:
        with open(PROXY_SERVER_PATH, 'r') as f:
            lines = f.readlines()

        # Find the line to insert after
        marker_line = '        _chat_response.choices[0].finish_reason = "content_filter"  # type: ignore\n'

        new_lines = []
        fixed = False

        for i, line in enumerate(lines):
            new_lines.append(line)

            if line == marker_line and not fixed:
                # Insert the fix code after this line
                new_lines.append(FIX_CODE)
                fixed = True
                print(f"✅ Fix applied at line {i+1}")

        if not fixed:
            print("❌ ERROR: Could not find marker line to insert fix")
            print(f"Looking for: {marker_line.strip()}")
            sys.exit(1)

        # Write the patched file
        with open(PROXY_SERVER_PATH, 'w') as f:
            f.writelines(new_lines)

        print(f"✅ Successfully patched {PROXY_SERVER_PATH}")
        return 0

    except Exception as e:
        print(f"❌ ERROR: {e}")
        return 1

if __name__ == "__main__":
    sys.exit(apply_fix())
