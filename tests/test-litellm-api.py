#!/usr/bin/env python3
"""
LiteLLM API Test Script

Tests all configured LiteLLM models via the OpenAI-compatible API.
Demonstrates proper IRSA authentication and multi-provider access.

Usage:
    # Test local deployment
    python tests/test-litellm-api.py

    # Test production deployment
    LITELLM_ENDPOINT=https://openwebui.bhenning.com python tests/test-litellm-api.py

    # Test custom endpoint
    LITELLM_ENDPOINT=http://192.168.10.40:4000 python tests/test-litellm-api.py
"""

import os
import sys
import requests
import json
from typing import Dict, List, Tuple

# ANSI color codes
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'  # No Color

# Configuration
ENDPOINT = os.environ.get("LITELLM_ENDPOINT", "http://localhost:4000")
API_KEY = os.environ.get("LITELLM_MASTER_KEY")

# Load API key from .secrets file if not in environment
if not API_KEY and os.path.exists(".secrets"):
    with open(".secrets") as f:
        for line in f:
            if line.startswith("LITELLM_MASTER_KEY="):
                API_KEY = line.split("=", 1)[1].strip()
                break

if not API_KEY:
    print(f"{Colors.RED}ERROR: LITELLM_MASTER_KEY not set{Colors.NC}")
    print("Set it via: export LITELLM_MASTER_KEY=your-key")
    print("Or create a .secrets file with: LITELLM_MASTER_KEY=your-key")
    sys.exit(1)

# Model configurations
MODELS = [
    # Perplexity Models
    ("perplexity-sonar", "Perplexity Sonar", "What is 2+2?"),
    ("perplexity-sonar-pro", "Perplexity Sonar Pro", "Explain quantum computing in one sentence"),

    # Amazon Nova Models
    ("nova-micro", "Amazon Nova Micro", "Say hello"),
    ("nova-lite", "Amazon Nova Lite", "What is AI?"),
    ("nova-pro", "Amazon Nova Pro", "Explain machine learning briefly"),

    # Meta Llama Models
    ("llama3-2-1b", "Meta Llama 3.2 1B", "Hi there"),
    ("llama3-2-3b", "Meta Llama 3.2 3B", "Hello, how are you?"),
]

def test_model(model_id: str, model_name: str, prompt: str) -> Tuple[bool, str]:
    """
    Test a single model via the LiteLLM API.

    Args:
        model_id: Model identifier (e.g., "nova-pro")
        model_name: Human-readable model name
        prompt: Test prompt to send

    Returns:
        Tuple of (success: bool, message: str)
    """
    url = f"{ENDPOINT}/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json"
    }
    payload = {
        "model": model_id,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 50
    }

    try:
        response = requests.post(url, headers=headers, json=payload, timeout=30)

        # Check for HTTP errors
        if response.status_code != 200:
            return False, f"HTTP {response.status_code}: {response.text[:100]}"

        data = response.json()

        # Check for API errors
        if "error" in data:
            error_msg = data["error"].get("message", str(data["error"]))

            # Check for specific Anthropic approval error
            if "use case details have not been submitted" in error_msg:
                return False, "NEEDS APPROVAL - Submit use case at AWS Bedrock console"

            return False, f"API Error: {error_msg}"

        # Check for valid response
        if "choices" in data and len(data["choices"]) > 0:
            content = data["choices"][0]["message"]["content"]
            preview = content[:60] + "..." if len(content) > 60 else content
            return True, f"Response: {preview}"
        else:
            return False, "Unexpected response format"

    except requests.exceptions.Timeout:
        return False, "Request timeout (30s)"
    except requests.exceptions.ConnectionError:
        return False, "Connection failed - is LiteLLM running?"
    except Exception as e:
        return False, f"Exception: {str(e)}"

def main():
    """Run all model tests and report results."""
    print(f"{Colors.BLUE}LiteLLM API Test Suite{Colors.NC}")
    print(f"Endpoint: {ENDPOINT}")
    print(f"Testing {len(MODELS)} models...")
    print()

    results: List[Tuple[str, str, bool, str]] = []
    passed = 0
    failed = 0

    # Test each model
    for model_id, model_name, prompt in MODELS:
        print(f"Testing {model_name}... ", end="", flush=True)

        success, message = test_model(model_id, model_name, prompt)
        results.append((model_id, model_name, success, message))

        if success:
            print(f"{Colors.GREEN}OK{Colors.NC}")
            print(f"  {message}")
            passed += 1
        else:
            print(f"{Colors.RED}FAILED{Colors.NC}")
            print(f"  {message}")
            failed += 1

        print()

    # Print summary
    print("=" * 60)
    print("TEST SUMMARY")
    print("=" * 60)
    print(f"Total tests: {len(MODELS)}")
    print(f"{Colors.GREEN}Passed: {passed}{Colors.NC}")
    print(f"{Colors.RED}Failed: {failed}{Colors.NC}")
    print()

    # List failed models
    if failed > 0:
        print("Failed models:")
        for model_id, model_name, success, message in results:
            if not success:
                print(f"  - {model_name} ({model_id})")
        print()

    # Print model categories
    print("Model Categories:")
    print("  ✓ Perplexity: 2 models (API key required)")
    print("  ✓ Amazon Nova: 3 models (AWS native, no payment validation)")
    print("  ✓ Meta Llama: 2 models (may need AWS Bedrock approval)")
    print()

    # Exit status
    if failed > 0:
        print(f"{Colors.YELLOW}Some tests failed. See details above.{Colors.NC}")
        sys.exit(1)
    else:
        print(f"{Colors.GREEN}All tests passed!{Colors.NC}")
        sys.exit(0)

if __name__ == "__main__":
    main()
