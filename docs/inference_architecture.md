# Inference Architecture: Native MoE Decode, No Speculative Decoding

Target: Ornith-1.5-35B-A3B on modern NVIDIA GPU hardware (e.g. RTX 5090 32 GB), served by SGLang
on `127.0.0.1:30000` with continuous batching and RadixAttention at a 256k (262,144-token) context.

## Decision

Speculative decoding (`d-flash`, `eagle-3`, any draft model) is **unsupported and prohibited in
`config/systemd/opencode-sglang-ornith-35b.service`**. `tests/test_sglang_service.sh` enforces this.

## Rationale

1. **Native MoE decode is already fast.** 35B total parameters, only ~3B active per token (A3B). On
   modern tensor cores single-stream decode is not bandwidth-starved; observed throughput is
   roughly 80-120+ tokens/s without a draft model.
2. **VRAM ceiling.** `--mem-fraction-static 0.88` reserves about 29,424 MiB (~28.7 GB) of the 32 GB card
   for NVFP4 weights (~17.5 GB) plus the 256k KV/state pool. A draft model (e.g. Ornith 9B NVFP4,
   ~5 GB) would push the total to ~34 GB and crash with CUDA OOM. FP8 weights alone (~35 GB) are
   unviable for the same reason.
3. **Hybrid linear attention.** Ornith-1.5 is `model_type: qwen3_5_moe`, mixing `linear_attn` recurrent
   state with `self_attn`. Eagle-3 / d-flash style speculation assumes a plain transformer KV cache and
   cannot verify or roll back recurrent linear-attention state without corrupting generation.
4. **No draft checkpoints.** No validated FP8/NVFP4 Eagle-3 draft for Ornith-1.5 is published.

## VRAM budget (RTX 5090, 32 GB)

| Item | Approx. |
| --- | --- |
| NVFP4 weights (35B MoE) | ~17.5 GB |
| KV cache + recurrent state pool (256k) | ~11-12 GB |
| SGLang static pool total (`0.88`) | ~28.7 GB (29,424 MiB) |
| Remaining for CUDA graphs/activations/desktop | ~3.3 GB |

## Serving mode

Pure continuous batching, `--max-running-requests 1`, `--chunked-prefill-size 2048`, RadixAttention
prefix caching, `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` to avoid fragmentation. Both the
35B and 9B OpenCode roles hit this single endpoint; SGLang does not enforce the request `model` field,
so no cold weight swap occurs. If an OOM occurs, the watchdog (Task 3.3) steps context down
256k -> 128k -> 64k -> 32k.

## Telemetry proof

Verify on the live host:

```bash
curl -s http://127.0.0.1:30000/v1/models          # max_model_len 262144
nvidia-smi --query-gpu=memory.used,memory.total --format=csv   # ~29.4 GB used
```
