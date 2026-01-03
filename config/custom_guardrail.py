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

        # Ensure messages alternate properly between user and assistant
        # After removing blocked pairs, we might have consecutive messages of the same role
        if len(cleaned_messages) > 1:
            alternating_messages = [cleaned_messages[0]]
            for msg in cleaned_messages[1:]:
                # Only add if role differs from previous message
                if msg.get("role") != alternating_messages[-1].get("role"):
                    alternating_messages.append(msg)
                else:
                    # Skip duplicate role - keep the latest one
                    print(f"🔍 DuckiesBunniesGuardrail: Skipping consecutive {msg.get('role')} message to maintain alternation")
                    alternating_messages[-1] = msg  # Replace previous with current (keep latest)

            if len(alternating_messages) != len(cleaned_messages):
                print(f"🔍 DuckiesBunniesGuardrail: Fixed alternation: {len(cleaned_messages)} -> {len(alternating_messages)} messages")
                cleaned_messages = alternating_messages
                data["messages"] = cleaned_messages

        # Final validation
        if not cleaned_messages:
            print(f"⚠️ DuckiesBunniesGuardrail: No messages left after sanitization!")
            # This shouldn't happen since we checked latest_user_message above
            # But if it does, return original data to avoid breaking the request
            return data

        # CRITICAL FIX: Force stream=false because post_call guardrails don't work with streaming
        # OpenWebUI sends stream=true by default, but LiteLLM's post_call hooks are never
        # called for streaming responses, which means blocked content bypasses the guardrail
        if data.get("stream", False):
            print(f"⚠️ DuckiesBunniesGuardrail: Forcing stream=false (was stream=true)")
            print(f"⚠️ DuckiesBunniesGuardrail: Streaming disabled to enable output filtering")
            data["stream"] = False

        print(f"🔍 DuckiesBunniesGuardrail: Conversation cleaned, sending {len(cleaned_messages)} messages to LLM")
        return data

    def _check_content_for_blocked_words(self, content: str, data: dict, hook_name: str):
        """
        Helper method to check content for blocked words and raise exception if found

        Args:
            content: The content to check
            data: Request data (for exception raising)
            hook_name: Name of the hook calling this (for logging)
        """
        if not content:
            return

        print(f"🔍 DuckiesBunniesGuardrail [{hook_name}]: Checking content: {content[:100]}...")

        # Check for duckies/bunnies in the content
        for pattern in self.patterns:
            if re.search(pattern, str(content), re.IGNORECASE):
                print(f"⚠️ DuckiesBunniesGuardrail [{hook_name}]: MATCH FOUND! Pattern={pattern}")
                print(f"⚠️ DuckiesBunniesGuardrail [{hook_name}]: BLOCKING - raising ModifyResponseException")

                # Raise passthrough exception - LiteLLM will return 200 with this message
                self.raise_passthrough_exception(
                    violation_message="⚠️ BLOCKED: The response contains mentions of duckies or bunnies. Discussions about cute animals may cause excessive happiness and distraction. Please ask a different question.",
                    request_data=data
                )

    async def async_moderation_hook(
        self,
        data: dict,
        user_api_key_dict: UserAPIKeyAuth,
        call_type: str,
    ):
        """
        DURING_CALL hook - runs on each streaming chunk to check accumulated content

        This is critical for streaming responses since post_call hooks don't execute
        on streaming chunks in LiteLLM.

        For each chunk, we check the accumulated message content and block if needed.
        """
        print(f"🔍 DuckiesBunniesGuardrail: async_moderation_hook CALLED! call_type={call_type}")

        # Extract the streaming response if present
        # For streaming, LiteLLM provides the accumulated message in data
        messages = data.get("messages", [])
        if not messages:
            return data

        # Check the last message (assistant's response being streamed)
        last_message = messages[-1]
        if last_message.get("role") == "assistant":
            content = last_message.get("content", "")
            self._check_content_for_blocked_words(content, data, "during_call/streaming")

        return data

    async def async_post_call_success_hook(
        self,
        user_api_key_dict: UserAPIKeyAuth,
        data: dict,
        response: dict,
    ):
        """
        Check LLM output AFTER calling LLM (non-streaming only)

        Note: This hook does NOT execute for streaming responses in LiteLLM.
        Use async_moderation_hook for streaming support.

        Args:
            user_api_key_dict: User API key information
            data: Request data
            response: Response data from LLM

        Raises:
            ModifyResponseException: If blocked content is detected in response (returns 200)
        """
        print(f"🔍 DuckiesBunniesGuardrail: async_post_call_success_hook CALLED!")

        # Extract response content from the LLM response
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

        # Check content using helper method
        self._check_content_for_blocked_words(content, data, "post_call/non-streaming")

        print(f"🔍 DuckiesBunniesGuardrail: No duckies/bunnies detected in LLM response")
        return response
