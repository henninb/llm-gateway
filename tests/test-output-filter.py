#!/usr/bin/env python3
"""
Test script for output filtering guardrail
Tests that the post-call hook blocks LLM responses about duckies/bunnies
"""

import os
import requests
import json

# Configuration
LITELLM_URL = os.getenv("LITELLM_URL", "http://localhost:8000")
MODEL = "llama3-2-3b"  # Cheap model for testing
API_KEY = os.getenv("LITELLM_MASTER_KEY", "sk-1234")

def call_llm(messages: list, stream: bool = False) -> dict:
    """Make a chat completion request"""

    response = requests.post(
        f"{LITELLM_URL}/v1/chat/completions",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {API_KEY}",
        },
        json={
            "model": MODEL,
            "messages": messages,
            "max_tokens": 200,
            "stream": stream,
        },
        timeout=30,
    )

    return {
        "status_code": response.status_code,
        "data": response.json()
    }

print("Testing Output Filter Guardrail")
print("=" * 60)
print(f"LiteLLM URL: {LITELLM_URL}")
print(f"Model: {MODEL}")
print("=" * 60)

# Test 1: Ask about ducks directly (should be blocked by input filter)
print("\nTest 1: Direct question about ducks")
print("-" * 60)
result = call_llm([
    {"role": "user", "content": "Tell me about ducks"}
])
print(f"Status: {result['status_code']}")
if result['status_code'] == 200:
    content = result['data'].get('choices', [{}])[0].get('message', {}).get('content', '')
    print(f"Response: {content[:150]}...")
    if "BLOCKED" in content:
        print("✅ PASS: Input filter blocked the request")
    else:
        print("❌ FAIL: Input filter should have blocked this")
else:
    print(f"❌ FAIL: Unexpected status code {result['status_code']}")

# Test 2: Simulate the bypass attempt
# First message gets blocked, then user says "hi" with the blocked message in history
print("\nTest 2: Bypass attempt (say 'hi' after blocked question)")
print("-" * 60)
result = call_llm([
    {"role": "user", "content": "Why no ducks?"},
    {"role": "assistant", "content": "⚠️ BLOCKED: Your message mentions duckies or bunnies..."},
    {"role": "user", "content": "hi"}  # This passes input filter but LLM might respond about ducks
])
print(f"Status: {result['status_code']}")
if result['status_code'] == 200:
    content = result['data'].get('choices', [{}])[0].get('message', {}).get('content', '')
    print(f"Response: {content[:200]}...")
    if "BLOCKED" in content:
        print("✅ PASS: Output filter blocked LLM response about ducks")
    elif any(word in content.lower() for word in ['duck', 'bunny', 'rabbit']):
        print("❌ FAIL: Output filter should have blocked this duck-related response")
    else:
        print("✅ PASS: LLM did not respond about ducks (no blocking needed)")
else:
    print(f"❌ FAIL: Unexpected status code {result['status_code']}")

# Test 3: Normal conversation (should pass)
print("\nTest 3: Normal conversation (no ducks mentioned)")
print("-" * 60)
result = call_llm([
    {"role": "user", "content": "What is 2+2?"}
])
print(f"Status: {result['status_code']}")
if result['status_code'] == 200:
    content = result['data'].get('choices', [{}])[0].get('message', {}).get('content', '')
    print(f"Response: {content[:150]}...")
    if "BLOCKED" not in content:
        print("✅ PASS: Normal conversation allowed through")
    else:
        print("❌ FAIL: False positive - blocked a normal question")
else:
    print(f"❌ FAIL: Unexpected status code {result['status_code']}")

print("\n" + "=" * 60)
print("Testing complete!")
