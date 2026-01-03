"""
FastAPI Proxy for LiteLLM - Handles Guardrail 400 Errors

This proxy sits between OpenWebUI and LiteLLM to convert 400 Bad Request
errors from guardrails into proper 200 OK OpenAI chat completion responses.

This prevents chat context corruption in OpenWebUI while maintaining guardrail blocking.
"""

import time
import uuid
from typing import AsyncIterator

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse
import json

app = FastAPI(title="LiteLLM Guardrail Proxy")

LITELLM_URL = "http://litellm:4000"


async def stream_with_error_handling(
    response: httpx.Response,
    model: str
) -> AsyncIterator[str]:
    """Stream response from LiteLLM, converting to error message if needed"""
    async for chunk in response.aiter_bytes():
        yield chunk


def create_error_response(error_message: str, model: str, stream: bool = False):
    """Create a proper OpenAI chat completion response from an error message"""

    completion_id = f"chatcmpl-{uuid.uuid4().hex[:8]}"
    created = int(time.time())

    if stream:
        # Streaming response format (SSE)
        chunk = {
            "id": completion_id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "delta": {"role": "assistant", "content": error_message},
                    "finish_reason": None,
                }
            ],
        }
        finish_chunk = {
            "id": completion_id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "delta": {},
                    "finish_reason": "stop",
                }
            ],
        }

        # Return SSE formatted stream
        return f"data: {json.dumps(chunk)}\n\ndata: {json.dumps(finish_chunk)}\n\ndata: [DONE]\n\n"
    else:
        # Non-streaming response format
        return {
            "id": completion_id,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": error_message},
                    "finish_reason": "stop",
                }
            ],
            "usage": {
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0,
            },
        }


@app.get("/health")
async def health():
    """Health check endpoint"""
    return {"status": "ok", "service": "litellm-guardrail-proxy"}


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"])
async def proxy(request: Request, path: str):
    """Proxy all requests to LiteLLM, handling guardrail 400 errors"""

    # Build target URL
    url = f"{LITELLM_URL}/{path}"

    # Get request body
    body = await request.body()

    # Parse request to check if streaming
    is_streaming = False
    model = "unknown"
    if body:
        try:
            data = json.loads(body)
            is_streaming = data.get("stream", False)
            model = data.get("model", "unknown")
        except:
            pass

    # Forward request to LiteLLM
    async with httpx.AsyncClient() as client:
        try:
            response = await client.request(
                method=request.method,
                url=url,
                headers={k: v for k, v in request.headers.items() if k.lower() != "host"},
                content=body,
                params=request.query_params,
                timeout=600.0,
            )

            # Check if this is a 400 error (likely from guardrail)
            if response.status_code == 400:
                error_data = response.json()
                error_message = error_data.get("error", {}).get("message", "Request blocked by guardrail")

                print(f"🛡️ Guardrail blocked request: {error_message}")
                print(f"🔄 Converting 400 to 200 OK with error message in response")

                # Convert to proper OpenAI response
                if is_streaming:
                    content = create_error_response(error_message, model, stream=True)
                    return Response(
                        content=content,
                        status_code=200,
                        media_type="text/event-stream",
                    )
                else:
                    return Response(
                        content=json.dumps(create_error_response(error_message, model, stream=False)),
                        status_code=200,
                        media_type="application/json",
                    )

            # For non-400 responses, pass through as-is
            if is_streaming and response.status_code == 200:
                return StreamingResponse(
                    response.aiter_bytes(),
                    status_code=response.status_code,
                    headers=dict(response.headers),
                    media_type=response.headers.get("content-type"),
                )
            else:
                return Response(
                    content=response.content,
                    status_code=response.status_code,
                    headers=dict(response.headers),
                    media_type=response.headers.get("content-type"),
                )

        except httpx.RequestError as e:
            return Response(
                content=json.dumps({"error": f"Proxy error: {str(e)}"}),
                status_code=502,
                media_type="application/json",
            )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
