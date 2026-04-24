# CAI Community Runtime — OpenCode with Qwen via Cloudera AI Inference

Run [OpenCode](https://github.com/anomalyco/opencode) (open-source terminal coding agent) inside a **Cloudera AI (CAI)** workspace. Point it at **Cloudera AI Inference service (CAII)** with an **OpenAI-compatible** route ([overview](https://docs.cloudera.com/machine-learning/cloud/ai-inference/topics/ml-caii-use-caii.html)); this README currently centers **`Qwen/Qwen3.6-27B`** as the suggested HF model. This image does **not** bundle local GPU inference.

---

## What you can deploy on CAII (relevant to Qwen)

Per [Supported Model Artifact Formats](https://docs.cloudera.com/machine-learning/cloud/ai-inference/topics/ml-caii-supported-model-artifact-formats.html), CAII supports:

- **NVIDIA NIM**–packaged LLMs (and other modalities).
- **Hugging Face transformer** models served by the **vLLM** engine.
- **ONNX** predictive models from Cloudera AI Workbench (not applicable to Qwen chat).

You **cannot** assume arbitrary artifacts (for example **GGUF-only** checkpoints for llama.cpp) are importable into CAII; align with the formats above and your platform’s Model Hub entries.

To pull a Hugging Face model into the registry, use **Model Hub → Import** ([doc](https://docs.cloudera.com/machine-learning/cloud/model-hub/topics/ml-import-model-hugging-face.html), technical preview). Gated models need an HF token and license acceptance on huggingface.co.

---

## Recommended Qwen model (current default)

**Suggested for now:** [`Qwen/Qwen3.6-27B`](https://huggingface.co/Qwen/Qwen3.6-27B) — **27B multimodal** (vision + language), strong **agentic coding** and long context in Qwen’s benchmarks, Apache-2.0. The model card targets **vLLM ≥ 0.19.0** and documents serving with **`--reasoning-parser qwen3`** and, for OpenCode-style tool use, **`--enable-auto-tool-choice --tool-call-parser qwen3_coder`**. Set **`CAII_MODEL`** to the same string your CAII route registers (usually `Qwen/Qwen3.6-27B`).

**Before you import:** confirm your **CAII Hugging Face runtime** image bundles a **new enough vLLM + transformers** stack for Qwen3.6; if the server is too old, the endpoint will fail at startup regardless of GPU size. Match **tensor parallel size**, **`--max-model-len`**, and GPU count to your **resource profile** (the card’s examples use high parallelism and large context; scale down for smaller clusters). For **text-only** workloads you can use **`--language-model-only`** on vLLM to reduce VRAM (see the model card).

### If you have **2× GPU** (e.g. 2× L40S on `g6e.12xlarge`)

1. **Resource profile** — Request **2 GPUs** on the endpoint so the pod actually sees two devices.

2. **Tensor parallel** — Set **`--tensor-parallel-size 2`** in **vLLM Args** so weights shard across **both** GPUs. Without this, vLLM often loads on **one** GPU and you get **OOM** or unstable behavior.

3. **Context cap** — Do **not** start with the card’s **262k** context on two consumer/datacenter GPUs. Begin with a **much smaller** **`--max-model-len`** (for example **32768** or **65536**) and **raise only after** `kserve-container` logs show stable headroom. KV cache grows with context; this is usually the first knob when 2× GPU is “enough for weights” but not for long chats.

4. **Precision** — Prefer a **FP8** registry variant if Model Hub lists **`Qwen/Qwen3.6-27B-FP8`** (or equivalent); it materially improves fit vs BF16 on **2×48 GB**-class setups.

5. **Vision** — If you only need **text / code**, add **`--language-model-only`** so vLLM skips the vision encoder and frees VRAM for the LM + KV.

6. **OpenCode + tools** — When CAII allows vLLM flags, align tool calling with the [model card](https://huggingface.co/Qwen/Qwen3.6-27B), for example:

   ```text
   --tensor-parallel-size 2 --max-model-len 65536 --reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder
   ```

   Tune **`--max-model-len`** (and add **`--language-model-only`** or **FP8**) per your OOM logs. If you **cannot** set server args, use this repo’s default **`tool_call: false`** (see below) so OpenCode still talks to the model.

7. **If it still does not fit** — Reduce **`max-model-len`**, insist on **FP8**, or fall back to a **smaller** Qwen (see the table below) until the stack is healthy.

### Other Qwen options (HF [Qwen org](https://huggingface.co/Qwen))

| Model | When to use |
|-------|-------------|
| **`Qwen/Qwen3-Coder-30B-A3B-Instruct`** (+ **‑FP8** if listed) | MoE coder specialist; can be **tight on 48 GB** or older vLLM—see troubleshooting below. |
| **`Qwen/Qwen3-Coder-Next`** | Newest coder-focused **~80B** class; only if your platform explicitly supports it. |
| **`Qwen/Qwen2.5-Coder-32B-Instruct`** | **Older vLLM** stacks where Qwen3.6 is not supported yet. |

Your **OpenCode `CAII_MODEL`** value must match whatever id your CAII **OpenAI** route expects (often the Hugging Face repo id), not only the endpoint hostname.

---

## When an HF + vLLM model (e.g. **`Qwen3-Coder-30B-A3B-Instruct`**) stays **In-progress** (503 / 500 / restarts)

Adding **CPU/RAM** alone rarely fixes HF+vLLM startup failures. The predictor pod can still return **503** (not ready) or **500** (application error) while **`kserve-container`** crashes, restarts, or never finishes loading the engine.

### 1. Read **`kserve-container` logs** first

In CAII, open **Logs** for the main app container (not only `queue-proxy` / Istio). Search for **`CUDA out of memory`**, **`OOM`**, **`EngineDeadError`**, **`ImportError`**, **`ValueError`**, or **unsupported architecture**. That single source usually tells you whether the issue is **VRAM**, **vLLM/transformers compatibility**, or **model config**.

### 2. Two GPUs do not automatically split the model

If your **resource profile** requests **2× GPU**, vLLM still defaults to **tensor parallel size 1** unless you tell it otherwise. The server may keep loading the **full** weights onto **one** GPU (same failure mode as before).

In **Advanced Options → vLLM Args** (exact syntax depends on your CAII / Hugging Face server version—confirm in Cloudera docs), you typically need **tensor parallelism across both devices**, for example:

```text
--tensor-parallel-size 2
```

If your UI expects a different delimiter or multiple lines, follow the product documentation for **huggingface (KServe) vLLM arguments**.

Also consider capping context so KV cache fits after load, for example:

```text
--max-model-len 32768
```

(Tune down if you still hit OOM after weights load.)

### 3. Try a different **model artifact** (easier to serve or better match)

| Approach | HF model id (typical) | When to use |
|----------|------------------------|-------------|
| **Current default** | `Qwen/Qwen3.6-27B` | Prefer this **if your CAII stack meets vLLM ≥ 0.19.0** and you want a **single strong** open-weight line for coding + multimodal (see [model card](https://huggingface.co/Qwen/Qwen3.6-27B)). |
| **FP8 weights** | `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8` | Less VRAM per GPU for the **30B MoE coder** if your registry lists it. |
| **Smaller coder (sanity check)** | e.g. `Qwen/Qwen2.5-Coder-7B-Instruct` | Proves **HF + vLLM + OpenCode** end-to-end on a tiny checkpoint. |
| **NVIDIA NIM** | Curated models your org exposes | If [NIM](https://docs.cloudera.com/machine-learning/cloud/ai-inference/topics/ml-caii-supported-model-artifact-formats.html) is available, it can avoid “latest HF + pinned vLLM” mismatches. |

### 4. **500** vs **503** in readiness probes

- **503** often means “server not ready yet” **or** repeatedly failing readiness while the process restarts.
- **500** usually means the HTTP server answered but the **health / ready handler hit an internal error**—again, **`kserve-container` logs** are decisive.

### 5. OpenCode side

None of this changes how you set **`CAII_OPENAI_BASE_URL`**, **`CAII_API_TOKEN`**, and **`CAII_MODEL`** once the endpoint is **Ready** and **Test Model** succeeds. Until then, fix serving first; OpenCode is not the bottleneck.

---

## Using the image in CAI

### 1. Register the runtime

**Admin → Runtime Catalog → Add Runtime** and enter your built image tag.

### 2. Configure environment variables (project or session)

| Variable | Description |
|----------|-------------|
| `CAII_OPENAI_BASE_URL` | OpenAI-compatible **base URL including `/v1`** for your inference route (see CAII / KServe OpenAI docs for your deployment). |
| `CAII_API_TOKEN` | Bearer token your gateway expects (store as a secret in CML where possible). |
| `CAII_MODEL` | Model id for `POST .../chat/completions` (must match the served name). **Example:** `Qwen/Qwen3.6-27B`. |
| `CAII_MODEL_SUPPORTS_TOOLS` | Optional. Set to `true` / `1` / `yes` only if your CAII deployment enables vLLM tool calling (`--enable-auto-tool-choice` and `--tool-call-parser`). If unset, this runtime writes **`"tool_call": false`** for the CAII model so OpenCode avoids `tool_choice: "auto"` (see below). |

### 3. Start OpenCode

In a terminal:

```bash
opencode-caii
```

That writes `~/.config/opencode/opencode.json` from the env vars (credentials stay in `{env:...}` indirection) and launches OpenCode. You can also run `opencode-sync-config` once, then `opencode` normally.

For non-interactive use:

```bash
opencode-caii run "Summarize this repository."
```

See [OpenCode install & config](https://opencode.ai/docs) and [providers / custom OpenAI-compatible endpoints](https://opencode.ai/docs/providers).

### OpenCode error: `"auto" tool choice requires --enable-auto-tool-choice and --tool-call-parser`

OpenCode is a **coding agent**: it sends **OpenAI tool / function-calling** traffic (`tool_choice: "auto"`). **vLLM** only accepts that if the server was started with **tool-call** flags. **NIM** endpoints (for example Llama Nemotron) often ship with this already wired; **Hugging Face + vLLM** deployments on CAII usually **do not**, so chat fails even when the endpoint is **Running**.

**Fix (CAII → model version → Advanced Options → vLLM Args):** add at least:

```text
--enable-auto-tool-choice --tool-call-parser hermes
```

For **Qwen2.5**-family models (including many **Qwen2-VL** / `Qwen2.5-*` instruct checkpoints), vLLM documents **Hermes-style** templates and recommends the **`hermes`** parser ([vLLM tool calling — Qwen](https://docs.vllm.ai/en/latest/features/tool_calling/#qwen-models)).

For **`Qwen3-Coder-*`** checkpoints, vLLM documents **`qwen3_xml`** instead:

```text
--enable-auto-tool-choice --tool-call-parser qwen3_xml
```

For **`Qwen/Qwen3.6-27B`** (and the Qwen3.6 family on the [official model card](https://huggingface.co/Qwen/Qwen3.6-27B)), Qwen recommends **vLLM ≥ 0.19.0**, a **`qwen3`** reasoning parser for default “thinking” behavior, and **`qwen3_coder`** (not `hermes`) for **tool use**, for example:

```text
--reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_coder
```

The card’s full examples also set **`--tensor-parallel-size`** and **`--max-model-len`** to match your GPU count and memory; your CAII profile must align with those constraints.

Exact flag names and supported parser values depend on the **vLLM version** inside your **huggingface** runtime image (`huggingfaceserver:…`). If a parser is rejected at startup, check that image’s vLLM release notes or try the closest option your version lists (`vllm serve --help` in a debug context). Redeploy the model after saving vLLM args.

#### If you **cannot** change CAII (OpenCode–only workaround)

This repository’s `opencode-sync-config` / `opencode-caii` writes `provider.caii.models.<CAII_MODEL>.**tool_call**: **false** by default. OpenCode uses that flag to treat the model as **not tool-capable**, which avoids sending the OpenAI **`tool_choice: "auto"`** pattern that triggers the vLLM error above.

**Trade-off:** you lose **agentic tool use** against that endpoint (no automatic `read` / `edit` / `bash` over the wire in the same way). You still get a useful **chat-style** assistant inside OpenCode for questions and explanations.

After someone enables tool calling on the server, set **`CAII_MODEL_SUPPORTS_TOOLS=true`**, run **`opencode-sync-config`** again, and restart OpenCode so the generated config **omits** `tool_call: false`.

---

## Building the image

```bash
docker build --pull --rm \
  -f Dockerfile \
  -t <your-registry>/cai-opencode-qwen-caii:2.0.0 .
```

---

## Repository structure

```
Dockerfile          CAI JupyterLab runtime + Node 20 + OpenCode + ttyd
scripts/startup.sh  Profile hook: CAII env banner, opencode-caii / opencode-sync-config
```

---

## License

MIT © 2026 Kevin Talbert
