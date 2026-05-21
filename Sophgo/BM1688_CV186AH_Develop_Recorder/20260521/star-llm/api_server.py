#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import time
import uuid
import json
import argparse
import numpy as np
import base64
from io import BytesIO
from PIL import Image
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
import uvicorn
from pydantic import BaseModel
from typing import List, Dict, Any, Optional, Union
from pipeline import Qwen3_5


class Qwen3_5_API(Qwen3_5):

    def __init__(self, args):
        super().__init__(args)

    def convert_openai_messages(self, messages):
        """Convert OpenAI-format messages to Qwen3-VL internal format.
        Returns (converted_messages, media_type)."""
        converted = []
        media_type = "text"

        for msg in messages:
            role = msg["role"]
            content = msg.get("content", "")

            if isinstance(content, str):
                converted.append({
                    "role": role,
                    "content": [{"type": "text", "text": content}]
                })
            elif isinstance(content, list):
                new_content = []
                for item in content:
                    if item["type"] == "text":
                        new_content.append({"type": "text", "text": item["text"]})
                    elif item["type"] == "image_url":
                        url = item["image_url"]["url"]
                        if url.startswith("data:image"):
                            _, data = url.split(",", 1)
                            image = Image.open(BytesIO(base64.b64decode(data)))
                        else:
                            image = url
                        new_content.append({
                            "type": "image",
                            "image": image,
                            "min_pixels": 4 * 32 * 32,
                            "max_pixels": self.model.MAX_PIXELS,
                        })
                        media_type = "image"
                    elif item["type"] == "video_url":
                        url = item["video_url"]["url"]
                        new_content.append({
                            "type": "video",
                            "video": url,
                            "fps": 1.0,
                            "min_pixels": 4 * 32 * 32,
                            "max_pixels": int(self.model.MAX_PIXELS * self.video_ratio),
                            "total_pixels": self.total_pixels,
                        })
                        media_type = "video"
                    else:
                        new_content.append(item)
                        if item.get("type") == "image":
                            media_type = "image"
                        elif item.get("type") == "video":
                            media_type = "video"
                converted.append({"role": role, "content": new_content})

        return converted, media_type

    def _run_prefill(self, inputs, media_type):
        """Run prefill stage, return first token."""
        self.model.forward_embed(inputs.input_ids.numpy())
        if media_type == "image":
            self.vit_process_image(inputs)
            position_ids = self.get_rope_index(inputs.input_ids, inputs.image_grid_thw,
                                               self.ID_IMAGE_PAD)
            self.max_posid = int(position_ids.max())
            return self.forward_prefill(position_ids.numpy())
        elif media_type == "video":
            self.vit_process_video(inputs)
            position_ids = self.get_rope_index(inputs.input_ids, inputs.video_grid_thw,
                                               self.ID_VIDEO_PAD)
            self.max_posid = int(position_ids.max())
            return self.forward_prefill(position_ids.numpy())
        else:
            token_len = inputs.input_ids.numel()
            position_ids = 3 * [i for i in range(token_len)]
            self.max_posid = token_len - 1
            return self.forward_prefill(np.array(position_ids, dtype=np.int32))

    def chat(self, messages, media_type="text", max_tokens=None):
        """Run inference and return (text, token_count, ftl, tps)."""
        self.model.clear_history()
        self.history_max_posid = 0

        inputs = self.process(messages, media_type)
        token_len = inputs.input_ids.numel()
        if token_len > self.model.MAX_INPUT_LENGTH:
            raise ValueError(
                f"Input length {token_len} exceeds max {self.model.MAX_INPUT_LENGTH}")

        first_start = time.time()
        token = self._run_prefill(inputs, media_type)
        first_end = time.time()

        # Decode tokens incrementally (handles multi-byte chars correctly)
        full_word_tokens = []
        text = ""
        tok_num = 0
        while token not in [self.ID_IM_END] and self.model.history_length < self.model.SEQLEN:
            if max_tokens is not None and tok_num >= max_tokens:
                break
            full_word_tokens.append(token)
            word = self.tokenizer.decode(full_word_tokens, skip_special_tokens=True)
            if "\ufffd" not in word:
                if len(full_word_tokens) == 1:
                    pre_word = word
                    word = self.tokenizer.decode(
                        [token, token], skip_special_tokens=True)[len(pre_word):]
                text += word
                full_word_tokens = []
            self.max_posid += 1
            position_ids = np.array(
                [self.max_posid, self.max_posid, self.max_posid], dtype=np.int32)
            token = self.model.forward_next(position_ids)
            tok_num += 1

        if full_word_tokens:
            text += self.tokenizer.decode(full_word_tokens, skip_special_tokens=True)

        self.history_max_posid = self.max_posid + 2
        first_duration = first_end - first_start
        next_duration = time.time() - first_end
        tps = tok_num / next_duration if next_duration > 0 else 0
        print(f"FTL: {first_duration:.3f} s, TPS: {tps:.3f} tokens/s, tokens: {tok_num}")
        return text, tok_num, first_duration, tps

    def chat_stream(self, messages, media_type="text", max_tokens=None):
        """Run inference and yield text tokens incrementally."""
        self.model.clear_history()
        self.history_max_posid = 0

        inputs = self.process(messages, media_type)
        token_len = inputs.input_ids.numel()
        print(f"[DEBUG] input token_len={token_len}")
        if token_len > self.model.MAX_INPUT_LENGTH:
            print(f"Input length {token_len} exceeds max {self.model.MAX_INPUT_LENGTH}")
            yield f"Input length {token_len} exceeds max {self.model.MAX_INPUT_LENGTH}"
            return

        token = self._run_prefill(inputs, media_type)

        full_word_tokens = []
        tok_num = 0
        while token not in [self.ID_IM_END] and self.model.history_length < self.model.SEQLEN:
            if max_tokens is not None and tok_num >= max_tokens:
                break
            full_word_tokens.append(token)
            word = self.tokenizer.decode(full_word_tokens, skip_special_tokens=True)
            if "\ufffd" not in word:
                if len(full_word_tokens) == 1:
                    pre_word = word
                    word = self.tokenizer.decode(
                        [token, token], skip_special_tokens=True)[len(pre_word):]
                full_word_tokens = []
                yield word
            self.max_posid += 1
            position_ids = np.array(
                [self.max_posid, self.max_posid, self.max_posid], dtype=np.int32)
            token = self.model.forward_next(position_ids)
            tok_num += 1

        if full_word_tokens:
            yield self.tokenizer.decode(full_word_tokens, skip_special_tokens=True)

        self.history_max_posid = self.max_posid + 2


# ---------------------------------------------------------------------------
# FastAPI app & OpenAI-compatible endpoints
# ---------------------------------------------------------------------------

app = FastAPI(title="Qwen3.5 API", version="1.0.0")

parser = argparse.ArgumentParser()
parser.add_argument('-m', '--model_path', type=str, required=True,
                    help='path to the bmodel file')
parser.add_argument('-c', '--config_path', type=str, default="../config",
                    help='path to the processor file')
parser.add_argument('--video_ratio', type=float, default=0.25,
                    help='Set video ratio, default is 0.25')
parser.add_argument('-d', '--devid', type=int, default=0, help='device ID to use')
args = parser.parse_args()

model = Qwen3_5_API(args)


class ChatCompletionMessage(BaseModel):
    role: str
    content: Union[str, List[Dict[str, Any]], None] = None


class ChatCompletionRequest(BaseModel):
    model: str = "qwen3.5"
    messages: List[ChatCompletionMessage]
    max_tokens: Optional[int] = None
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    stream: Optional[bool] = False


@app.get("/")
async def root():
    return {"message": "Qwen3.5 API Server is running!"}


@app.get("/health")
async def health_check():
    return {"status": "healthy", "model": args.model_path}


@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [{"id": "qwen3.5", "object": "model", "owned_by": "sophgo"}],
    }


@app.post("/v1/chat/completions")
async def chat_completions(request: ChatCompletionRequest):
    try:
        raw_messages = [{"role": m.role, "content": m.content} for m in request.messages]
        print(f"[DEBUG] raw request messages: {json.dumps(raw_messages, ensure_ascii=False, default=str)}")
        converted_messages, media_type = model.convert_openai_messages(raw_messages)
        print(f"[DEBUG] converted messages: {json.dumps(converted_messages, ensure_ascii=False, default=str)}")

        if request.stream:
            return StreamingResponse(
                _generate_stream(converted_messages, media_type, request.model,
                                 request.max_tokens),
                media_type="text/event-stream",
            )

        text, tok_num, ftl, tps = model.chat(converted_messages, media_type,
                                              request.max_tokens)
        completion_id = f"chatcmpl-{uuid.uuid4().hex[:12]}"

        return {
            "id": completion_id,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": request.model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }],
            "usage": {
                "prompt_tokens": -1,
                "completion_tokens": tok_num,
                "total_tokens": -1,
            },
        }

    except Exception as e:
        return {"error": {"message": str(e), "type": "invalid_request_error"}}


def _generate_stream(messages, media_type, model_name, max_tokens):
    """SSE stream generator for OpenAI-compatible streaming."""
    completion_id = f"chatcmpl-{uuid.uuid4().hex[:12]}"
    created = int(time.time())

    for token_text in model.chat_stream(messages, media_type, max_tokens):
        chunk = {
            "id": completion_id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model_name,
            "choices": [{
                "index": 0,
                "delta": {"content": token_text},
                "finish_reason": None,
            }],
        }
        yield f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n"

    # Final chunk with finish_reason
    final = {
        "id": completion_id,
        "object": "chat.completion.chunk",
        "created": created,
        "model": model_name,
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    }
    yield f"data: {json.dumps(final, ensure_ascii=False)}\n\n"
    yield "data: [DONE]\n\n"


# example curl commands:
#
# Text only:
#   curl -X POST "http://localhost:8000/v1/chat/completions" \
#     -H "Content-Type: application/json" \
#     -d '{"model":"qwen3-vl","messages":[{"role":"user","content":"What is the capital of France?"}]}'
#
# With image (base64):
#   curl -X POST "http://localhost:8000/v1/chat/completions" \
#     -H "Content-Type: application/json" \
#     -d '{"model":"qwen3-vl","messages":[{"role":"user","content":[
#       {"type":"text","text":"Describe this image"},
#       {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,/9j/4AAQ..."}}
#     ]}]}'
#
# Streaming:
#   curl -X POST "http://localhost:8000/v1/chat/completions" \
#     -H "Content-Type: application/json" \
#     -d '{"model":"qwen3-vl","messages":[{"role":"user","content":"Hello"}],"stream":true}'

if __name__ == "__main__":
    port = int(os.getenv("STARLLM_PORT", "8000"))
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")
