"""
Custom LiteLLM Guardrail: Duckies and Bunnies Detector
Blocks users when they mention duckies or bunnies
"""

import re
from typing import Literal
from litellm.integrations.custom_guardrail import CustomGuardrail
from litellm.proxy._types import UserAPIKeyAuth


class DuckiesBunniesGuardrail(CustomGuardrail):
    """
    Custom guardrail that detects mentions of duckies and bunnies
    and blocks the request before calling the LLM
    """

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.patterns = [
            r'\bduck(y|ies?|s)?\b',
            r'\bbunny|bunnies\b',
            r'\brabbit(s)?\b'
        ]

    async def async_pre_call_hook(
        self,
        user_api_key_dict: UserAPIKeyAuth,
        cache: dict,
        data: dict,
        call_type: Literal["completion", "embeddings", "image_generation", "moderation", "audio_transcription"],
    ):
        """
        Check user input BEFORE calling LLM and sanitize conversation history

        This hook:
        1. Blocks if the latest user message contains ducks/bunnies
        2. Removes ALL messages containing ducks/bunnies from conversation history
           (prevents LLM from seeing blocked content in context)

        Args:
            user_api_key_dict: User API key information
            cache: Cache dictionary
            data: Request data containing messages
            call_type: Type of API call

        Raises:
            BadRequestError: If blocked content is detected in latest message (returns 400)
        """
        print(f"🔍 DuckiesBunniesGuardrail: async_pre_call_hook CALLED! call_type={call_type}")

        # Only check completion requests
        if call_type not in ["completion", "acompletion"]:
            print(f"🔍 DuckiesBunniesGuardrail: Skipping non-completion call_type={call_type}")
            return data

        # Extract messages from request data
        messages = data.get("messages", [])

        if not messages:
            print(f"🔍 DuckiesBunniesGuardrail: No messages found in request data")
            return data

        print(f"🔍 DuckiesBunniesGuardrail: Checking {len(messages)} total messages")

        # Find the LAST user message
        last_user_message = None
        for message in reversed(messages):
            if message.get("role") == "user":
                last_user_message = message
                break

        # Check if LATEST user message contains blocked content
        if last_user_message:
            content = last_user_message.get("content", "")
            print(f"🔍 DuckiesBunniesGuardrail: Checking latest user message: {content[:100]}...")

            for pattern in self.patterns:
                if re.search(pattern, str(content), re.IGNORECASE):
                    print(f"⚠️ DuckiesBunniesGuardrail: MATCH FOUND in latest message! Pattern={pattern}")
                    print(f"⚠️ DuckiesBunniesGuardrail: BLOCKING request - raising ModifyResponseException")

                    # Raise passthrough exception - LiteLLM will return 200 with this message
                    self.raise_passthrough_exception(
                        violation_message="⚠️ BLOCKED: Your message mentions duckies or bunnies. Discussions about cute animals may cause excessive happiness and distraction. Please rephrase your question.",
                        request_data=data
                    )

        # SANITIZE conversation history - remove message PAIRS containing blocked content
        # This maintains valid conversation structure (user/assistant alternation)
        cleaned_messages = []
        removed_count = 0
        i = 0

        while i < len(messages):
            message = messages[i]
            content = str(message.get("content", ""))
            contains_blocked = False

            # Check if this message contains blocked content
            for pattern in self.patterns:
                if re.search(pattern, content, re.IGNORECASE):
                    contains_blocked = True
                    break

            if contains_blocked and message.get("role") == "user":
                # User message with blocked content - remove it AND the following assistant response
                print(f"🔍 DuckiesBunniesGuardrail: Removing blocked user message: {content[:50]}...")
                removed_count += 1

                # Also remove the next message if it's an assistant response (BLOCKED or otherwise)
                if i + 1 < len(messages) and messages[i + 1].get("role") == "assistant":
                    assistant_content = messages[i + 1].get("content", "")
                    print(f"🔍 DuckiesBunniesGuardrail: Removing corresponding assistant response: {assistant_content[:50]}...")
                    removed_count += 1
                    i += 2  # Skip both messages
                else:
                    i += 1  # Skip only user message
            elif contains_blocked and message.get("role") == "assistant":
                # Assistant message with blocked content (but not paired with user message above)
                # This shouldn't happen, but skip it anyway
                print(f"🔍 DuckiesBunniesGuardrail: Removing orphan assistant message: {content[:50]}...")
                removed_count += 1
                i += 1
            else:
                # Clean message - keep it
                cleaned_messages.append(message)
                i += 1

        if removed_count > 0:
            print(f"🔍 DuckiesBunniesGuardrail: Removed {removed_count} messages from conversation history")
            data["messages"] = cleaned_messages

        # Ensure conversation starts with a user message (required by most LLMs)
        if cleaned_messages and cleaned_messages[0].get("role") != "user":
            print(f"⚠️ DuckiesBunniesGuardrail: Conversation doesn't start with user message, removing leading assistant messages")
            while cleaned_messages and cleaned_messages[0].get("role") == "assistant":
                removed_msg = cleaned_messages.pop(0)
                print(f"🔍 DuckiesBunniesGuardrail: Removed leading assistant message: {removed_msg.get('content', '')[:50]}...")

        # Final validation
        if not cleaned_messages:
            print(f"⚠️ DuckiesBunniesGuardrail: No messages left after sanitization!")
            # This shouldn't happen since we checked latest_user_message above
            # But if it does, return original data to avoid breaking the request
            return data

        print(f"🔍 DuckiesBunniesGuardrail: Conversation cleaned, sending {len(cleaned_messages)} messages to LLM")
        return data

    async def async_post_call_success_hook(
        self,
        user_api_key_dict: UserAPIKeyAuth,
        data: dict,
        response: dict,
    ):
        """
        Check LLM output AFTER calling LLM and raise exception if blocked content detected

        This catches cases where users bypass the input filter by asking indirectly
        (e.g., "hi" after being blocked for asking about ducks)

        Args:
            user_api_key_dict: User API key information
            data: Request data
            response: Response data from LLM

        Raises:
            ModifyResponseException: If blocked content is detected in response (returns 200)
        """
        print(f"🔍 DuckiesBunniesGuardrail: async_post_call_success_hook CALLED!")

        # Extract response content from the LLM response
        try:
            # Handle both streaming and non-streaming responses
            choices = response.get("choices", [])
            if not choices:
                print(f"🔍 DuckiesBunniesGuardrail: No choices in response")
                return response

            # Get the assistant's message content
            first_choice = choices[0]
            message = first_choice.get("message", {})
            content = message.get("content", "")

            if not content:
                print(f"🔍 DuckiesBunniesGuardrail: No content in response message")
                return response

            print(f"🔍 DuckiesBunniesGuardrail: Checking LLM response: {content[:100]}...")

            # Check for duckies/bunnies in the LLM's response
            for pattern in self.patterns:
                if re.search(pattern, str(content), re.IGNORECASE):
                    print(f"⚠️ DuckiesBunniesGuardrail: MATCH FOUND in LLM response! Pattern={pattern}")
                    print(f"⚠️ DuckiesBunniesGuardrail: BLOCKING response - raising ModifyResponseException")

                    # Raise passthrough exception - LiteLLM will return 200 with this message
                    self.raise_passthrough_exception(
                        violation_message="⚠️ BLOCKED: The response contains mentions of duckies or bunnies. Discussions about cute animals may cause excessive happiness and distraction. Please ask a different question.",
                        request_data=data
                    )

            print(f"🔍 DuckiesBunniesGuardrail: No duckies/bunnies detected in LLM response")
            return response

        except Exception as e:
            # Don't block on parsing errors, just log and pass through
            print(f"⚠️ DuckiesBunniesGuardrail: Error checking response: {e}")
            return response
