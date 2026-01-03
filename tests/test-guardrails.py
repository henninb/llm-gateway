#!/usr/bin/env python3
"""
Custom Guardrails Test Script

Tests the DuckiesBunniesGuardrail with comprehensive scenarios:

PRE_CALL TESTS (Input Filtering):
1. Direct blocking - user messages containing "duckies" or "bunnies" should be blocked
2. Bypass prevention - conversation history should be sanitized to prevent bypass
3. Normal conversation - regular messages should work fine

POST_CALL TESTS (Output Filtering):
4. Output filtering (non-streaming) - LLM responses with blocked words should be filtered
5. Output filtering (streaming) - Same as above but with streaming enabled
6. Indirect bypass attempt - questions that elicit blocked responses ("what is bird that quacks?")

The guardrail should:
- Block direct mentions of ducks/bunnies in user input (pre_call hook)
- Sanitize conversation history to prevent LLM from seeing blocked content
- Block LLM responses containing ducks/bunnies (post_call hook)
- Block indirect bypass attempts where input is clean but output contains blocked words
- Work correctly for both streaming and non-streaming requests
- Allow normal conversations to proceed

Tests with both Bedrock (llama3-2-3b) and Perplexity (perplexity-sonar) models

Usage:
    # Test local deployment
    python tests/test-guardrails.py

    # Test specific endpoint
    LITELLM_ENDPOINT=http://192.168.10.40:4000 python tests/test-guardrails.py
"""

import os
import sys
import requests
import json
from typing import Dict, Any, List

# Configuration
LITELLM_URL = os.getenv("LITELLM_URL", "http://localhost:4000")
API_KEY = os.getenv("LITELLM_MASTER_KEY", "sk-1234")

# Test both Bedrock and Perplexity models
MODELS_TO_TEST = [
    "llama3-2-3b",      # Bedrock model
    "perplexity-sonar"  # Perplexity model
]

def call_llm(messages: List[Dict[str, str]], model: str, stream: bool = False) -> Dict[str, Any]:
    """Make a chat completion request to LiteLLM

    Args:
        messages: List of message dicts with 'role' and 'content'
        model: Model name to use
        stream: Whether to use streaming mode

    Returns:
        dict with 'choices' key on success, or 'error' key on 400 error
    """
    url = f"{LITELLM_URL}/v1/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {API_KEY}"
    }
    payload = {
        "model": model,
        "messages": messages,
        "max_tokens": 100,
        "stream": stream
    }

    if stream:
        # For streaming, we need to handle SSE responses
        response = requests.post(url, headers=headers, json=payload, timeout=30, stream=True)

        # Collect all chunks
        full_content = ""
        for line in response.iter_lines():
            if line:
                line_str = line.decode('utf-8')
                if line_str.startswith("data: "):
                    data_str = line_str[6:]
                    if data_str.strip() == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data_str)
                        delta = chunk.get("choices", [{}])[0].get("delta", {})
                        content = delta.get("content", "")
                        full_content += content
                    except json.JSONDecodeError:
                        pass

        # Return in same format as non-streaming
        return {
            "status_code": response.status_code,
            "data": {
                "choices": [{
                    "message": {
                        "content": full_content
                    }
                }]
            }
        }
    else:
        response = requests.post(url, headers=headers, json=payload, timeout=30)

        # Return response regardless of status code
        return {
            "status_code": response.status_code,
            "data": response.json()
        }

def test_direct_block(model: str) -> bool:
    """Test that direct mentions of ducks/bunnies are blocked"""
    print(f"\n{'='*70}")
    print(f"Test 1 ({model}): Direct mention should be blocked")
    print('='*70)

    result = call_llm([
        {"role": "user", "content": "Tell me about duckies"}
    ], model)

    print(f"Status: {result['status_code']}")

    if result['status_code'] == 200:
        content = result['data'].get('choices', [{}])[0].get('message', {}).get('content', '')
        print(f"Response: {content[:150]}...")

        if "BLOCKED" in content:
            print("✅ PASS: Request blocked (200 OK with BLOCKED message)")
            return True
        else:
            print("❌ FAIL: Should have been blocked")
            return False
    else:
        print(f"❌ FAIL: Unexpected status {result['status_code']}")
        return False

def test_bypass_prevention(model: str) -> bool:
    """Test that the bypass scenario is prevented via history sanitization"""
    print(f"\n{'='*70}")
    print(f"Test 2 ({model}): Bypass prevention (history sanitization)")
    print('='*70)
    print("Simulating conversation:")
    print("  1. User: 'duckies and bunnies' → BLOCKED")
    print("  2. User: 'why no duckies?' → BLOCKED")
    print("  3. User: 'hi' → Should respond normally WITHOUT mentioning ducks/bunnies")
    print()

    # Simulate the conversation history that would exist after two blocked attempts
    result = call_llm([
        {"role": "user", "content": "duckies and bunnies"},
        {"role": "assistant", "content": "⚠️ BLOCKED: Your message mentions duckies or bunnies. Discussions about cute animals may cause excessive happiness and distraction. Please rephrase your question."},
        {"role": "user", "content": "why no duckies?"},
        {"role": "assistant", "content": "⚠️ BLOCKED: Your message mentions duckies or bunnies. Discussions about cute animals may cause excessive happiness and distraction. Please rephrase your question."},
        {"role": "user", "content": "hi"}
    ], model)

    print(f"Status: {result['status_code']}")

    if result['status_code'] == 200:
        content = result['data'].get('choices', [{}])[0].get('message', {}).get('content', '').lower()
        print(f"Response: {content[:200]}...")

        # Check if response mentions blocked topics (bad - bypass worked)
        blocked_keywords = ['duck', 'bunny', 'rabbit', 'cute animal']
        mentions_blocked_topic = any(keyword in content for keyword in blocked_keywords)

        # Check if it's a BLOCKED message (also bad - shouldn't block "hi")
        is_blocked_message = "blocked" in content and "⚠️" in result['data'].get('choices', [{}])[0].get('message', {}).get('content', '')

        if mentions_blocked_topic:
            print("❌ FAIL: Response mentions ducks/bunnies (history sanitization failed)")
            print(f"   LLM saw blocked content in conversation history!")
            return False
        elif is_blocked_message:
            print("❌ FAIL: False positive - blocked 'hi' message")
            return False
        else:
            print("✅ PASS: Normal response without mentioning blocked topics")
            print("   History sanitization working correctly!")
            return True
    else:
        print(f"❌ FAIL: Unexpected status {result['status_code']}")
        return False

def test_normal_conversation(model: str) -> bool:
    """Test that normal conversations work fine"""
    print(f"\n{'='*70}")
    print(f"Test 3 ({model}): Normal conversation (no blocking)")
    print('='*70)

    result = call_llm([
        {"role": "user", "content": "What is 2+2?"}
    ], model)

    print(f"Status: {result['status_code']}")

    if result['status_code'] == 200:
        content = result['data'].get('choices', [{}])[0].get('message', {}).get('content', '')
        print(f"Response: {content[:150]}...")

        if "BLOCKED" not in content:
            print("✅ PASS: Normal conversation allowed")
            return True
        else:
            print("❌ FAIL: False positive blocking")
            return False
    else:
        print(f"❌ FAIL: Unexpected status {result['status_code']}")
        return False

def test_output_filtering_non_streaming(model: str) -> bool:
    """Test that LLM responses containing blocked words are filtered (post_call hook, non-streaming)"""
    print(f"\n{'='*70}")
    print(f"Test 4 ({model}): Output filtering - non-streaming (post_call hook)")
    print('='*70)
    print("Asking: 'What's another name for rabbit?'")
    print("Expected: LLM would naturally say 'bunny', but post_call hook should block it")
    print()

    result = call_llm([
        {"role": "user", "content": "What's another name for rabbit?"}
    ], model, stream=False)

    print(f"Status: {result['status_code']}")

    if result['status_code'] == 200:
        content = result['data'].get('choices', [{}])[0].get('message', {}).get('content', '')
        print(f"Response: {content[:150]}...")

        # Check if the response was blocked
        if "BLOCKED" in content:
            print("✅ PASS: LLM output blocked (post_call hook working)")
            return True
        else:
            # Check if response contains blocked words (should not happen)
            blocked_keywords = ['bunny', 'bunnies', 'duck', 'ducky', 'duckies', 'rabbit']
            if any(keyword in content.lower() for keyword in blocked_keywords):
                print("❌ FAIL: Response contains blocked words (post_call hook not working)")
                print(f"   Response should have been blocked but wasn't!")
                return False
            else:
                print("⚠️  UNCERTAIN: Response doesn't contain blocked words")
                print("   (This might pass if LLM didn't naturally use 'bunny')")
                # This is still a pass, just uncertain
                return True
    else:
        print(f"❌ FAIL: Unexpected status {result['status_code']}")
        return False

def test_output_filtering_streaming(model: str) -> bool:
    """Test that LLM responses containing blocked words are filtered (post_call hook, streaming)"""
    print(f"\n{'='*70}")
    print(f"Test 5 ({model}): Output filtering - streaming (post_call hook)")
    print('='*70)
    print("Asking: 'What's another name for rabbit?' with streaming=true")
    print("Expected: LLM would naturally say 'bunny', but post_call hook should block it")
    print("This tests the LiteLLM streaming bug fix")
    print()

    result = call_llm([
        {"role": "user", "content": "What's another name for rabbit?"}
    ], model, stream=True)

    print(f"Status: {result['status_code']}")

    if result['status_code'] == 200:
        content = result['data'].get('choices', [{}])[0].get('message', {}).get('content', '')
        print(f"Response: {content[:150]}...")

        # Check if the response was blocked
        if "BLOCKED" in content:
            print("✅ PASS: LLM output blocked in streaming mode (post_call hook + patch working)")
            return True
        else:
            # Check if response contains blocked words (should not happen)
            blocked_keywords = ['bunny', 'bunnies', 'duck', 'ducky', 'duckies', 'rabbit']
            if any(keyword in content.lower() for keyword in blocked_keywords):
                print("❌ FAIL: Response contains blocked words (post_call hook not working in streaming)")
                print(f"   Response should have been blocked but wasn't!")
                return False
            else:
                print("⚠️  UNCERTAIN: Response doesn't contain blocked words")
                print("   (This might pass if LLM didn't naturally use 'bunny')")
                # This is still a pass, just uncertain
                return True
    else:
        print(f"❌ FAIL: Unexpected status {result['status_code']}")
        return False

def test_indirect_bypass_attempt(model: str) -> bool:
    """Test that indirect questions that elicit blocked responses are caught (post_call hook)"""
    print(f"\n{'='*70}")
    print(f"Test 6 ({model}): Indirect bypass - 'what is bird that quacks?' (post_call hook)")
    print('='*70)
    print("Asking: 'what is bird that quacks?'")
    print("Expected: Input passes pre_call (no blocked words), but LLM response")
    print("          contains 'duck/mallard' which should be blocked by post_call hook")
    print()

    result = call_llm([
        {"role": "user", "content": "what is bird that quacks?"}
    ], model, stream=False)

    print(f"Status: {result['status_code']}")

    if result['status_code'] == 200:
        content = result['data'].get('choices', [{}])[0].get('message', {}).get('content', '')
        print(f"Response: {content[:150]}...")

        # Check if the response was blocked
        if "BLOCKED" in content:
            print("✅ PASS: Indirect bypass blocked (post_call hook caught LLM response)")
            return True
        else:
            # Check if response contains blocked words (should not happen)
            blocked_keywords = ['duck', 'ducky', 'duckies', 'mallard']
            if any(keyword in content.lower() for keyword in blocked_keywords):
                print("❌ FAIL: Response contains blocked words (post_call hook not working)")
                print(f"   LLM responded with information about ducks but wasn't blocked!")
                return False
            else:
                print("⚠️  UNCERTAIN: Response doesn't contain blocked words")
                print("   (This might pass if LLM gave a different answer)")
                # This is still a pass, just uncertain
                return True
    else:
        print(f"❌ FAIL: Unexpected status {result['status_code']}")
        return False

def main():
    """Run all test cases for all models"""
    print("╔" + "="*68 + "╗")
    print("║" + " "*20 + "GUARDRAIL TEST SUITE" + " "*28 + "║")
    print("╚" + "="*68 + "╝")
    print(f"\nLiteLLM URL: {LITELLM_URL}")
    print(f"Models to test: {', '.join(MODELS_TO_TEST)}\n")

    all_results = []

    for model in MODELS_TO_TEST:
        print(f"\n{'#'*70}")
        print(f"# TESTING MODEL: {model}")
        print(f"{'#'*70}")

        model_results = []

        # PRE_CALL TESTS (Input Filtering)
        print(f"\n{'*'*70}")
        print("* PRE_CALL TESTS (Input Filtering)")
        print(f"{'*'*70}")

        # Test 1: Direct blocking
        model_results.append(test_direct_block(model))

        # Test 2: Bypass prevention
        model_results.append(test_bypass_prevention(model))

        # Test 3: Normal conversation
        model_results.append(test_normal_conversation(model))

        # POST_CALL TESTS (Output Filtering)
        print(f"\n{'*'*70}")
        print("* POST_CALL TESTS (Output Filtering)")
        print(f"{'*'*70}")

        # Test 4: Output filtering - non-streaming
        model_results.append(test_output_filtering_non_streaming(model))

        # Test 5: Output filtering - streaming
        model_results.append(test_output_filtering_streaming(model))

        # Test 6: Indirect bypass attempt
        model_results.append(test_indirect_bypass_attempt(model))

        # Model summary
        passed = sum(model_results)
        total = len(model_results)
        print(f"\n{'-'*70}")
        print(f"Model '{model}' Results: {passed}/{total} tests passed")
        print(f"{'-'*70}")

        all_results.extend(model_results)

    # Final summary
    print(f"\n{'='*70}")
    print("FINAL SUMMARY")
    print('='*70)
    total_passed = sum(all_results)
    total_tests = len(all_results)
    print(f"Total: {total_passed}/{total_tests} tests passed")
    print(f"Failed: {total_tests - total_passed}/{total_tests}")

    if total_passed == total_tests:
        print("\n🎉 All tests passed!")
        sys.exit(0)
    else:
        print(f"\n⚠️  {total_tests - total_passed} test(s) failed")
        sys.exit(1)

if __name__ == "__main__":
    main()
