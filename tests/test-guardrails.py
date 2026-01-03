#!/usr/bin/env python3
"""
Test script for Duckies and Bunnies Guardrail
Tests that the guardrail properly blocks messages and prevents bypasses
Tests with both Bedrock (llama3-2-3b) and Perplexity (perplexity-sonar) models
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

def call_llm(messages: List[Dict[str, str]], model: str) -> Dict[str, Any]:
    """Make a chat completion request to LiteLLM

    Args:
        messages: List of message dicts with 'role' and 'content'
        model: Model name to use

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
        "max_tokens": 100
    }

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

        # Test 1: Direct blocking
        model_results.append(test_direct_block(model))

        # Test 2: Bypass prevention
        model_results.append(test_bypass_prevention(model))

        # Test 3: Normal conversation
        model_results.append(test_normal_conversation(model))

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
