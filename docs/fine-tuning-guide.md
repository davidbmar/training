# Fine-Tuning Local LLMs: A Complete Guide

A plain-English guide to how we take off-the-shelf AI models and teach them to be great phone receptionists. Written so that a college student studying AI/ML can follow every step.

## Table of Contents

- [The Big Picture](#the-big-picture)
- [Key Terms Glossary](#key-terms-glossary)
- [Why Fine-Tune Instead of Prompting?](#why-fine-tune-instead-of-prompting)
- [Our Hardware: Apple M3 Pro](#our-hardware-apple-m3-pro)
- [The Software Stack](#the-software-stack)
- [What is LoRA?](#what-is-lora)
- [The Full Pipeline](#the-full-pipeline)
- [Step-by-Step Walkthrough](#step-by-step-walkthrough)
- [How to Know If It Worked](#how-to-know-if-it-worked)
- [Common Pitfalls](#common-pitfalls)
- [Further Reading](#further-reading)

---

## The Big Picture

We have a phone agent that answers calls for a plumbing company. It uses a local AI model (running on your laptop, not in the cloud) to generate what the receptionist says. The problem: off-the-shelf models are generalists. They can write essays, answer trivia, and generate code — but they don't naturally sound like a warm, efficient plumbing receptionist.

**Fine-tuning** is the process of taking a general-purpose model and teaching it a specific skill by showing it hundreds of examples of how to do that skill well. It's like the difference between hiring someone who "speaks English" versus someone who's been trained as a receptionist — same underlying ability, but focused through practice.

```
Before fine-tuning:
  Caller: "My sink is leaking"
  Model:  "I understand you're experiencing a plumbing issue. There are several
           potential causes for a leaking sink, including worn washers, corroded
           valve seats, or loose connections..."  (too long, too formal, not helpful)

After fine-tuning:
  Caller: "My sink is leaking"
  Model:  "Oh no, a leaking sink — that's no fun. Is it a steady drip or
           more of a trickle?"  (warm, brief, moves toward booking)
```

The model's weights (its internal knowledge) actually change. It doesn't just get a better prompt — it *becomes* a better receptionist at the neural network level.

---

## Key Terms Glossary

Read this section first. Every term used in the rest of the guide is defined here.

### Models and Weights

**LLM (Large Language Model)**
An AI model trained on massive amounts of text that can generate human-like responses. Examples: GPT-4, Claude, Llama, Mistral, Phi. "Large" refers to the number of parameters — typically billions.

**Parameters**
The numbers inside a neural network that determine its behavior. When we say "Phi4-mini is a 3.8B model," that means it has 3.8 billion parameters. More parameters generally means more capable but slower and larger on disk.

**Weights**
Another word for parameters. "The model's weights" = "the model's parameters" = the billions of numbers that define what the model knows and how it responds. When we fine-tune, we modify some of these weights.

**Base Model**
The original, unmodified model as released by its creator (Microsoft for Phi4, Mistral AI for Mistral, Google for Gemma). This is our starting point before fine-tuning. Also called the "foundation model" or "pretrained model."

**Instruct Model / Chat Model**
A base model that has already been fine-tuned (by its creator) to follow instructions and have conversations. We start from instruct models, not raw base models, because they already know how to chat — we're just teaching them to chat *as a plumbing receptionist specifically*.

### Fine-Tuning Concepts

**Fine-Tuning**
The process of continuing a model's training on a smaller, specialized dataset. The model's weights are updated to reflect the new training data. Think of it as "additional education" — the model already went to school (pretraining), and now it's doing on-the-job training.

**Full Fine-Tuning**
Updating ALL of the model's parameters. For a 7B model, that's 7 billion numbers being modified. This requires enormous amounts of memory (often 4-8x the model size) and is typically done on expensive GPU clusters. We do NOT do this.

**LoRA (Low-Rank Adaptation)**
A clever technique that fine-tunes only a tiny fraction (~1-2%) of a model's parameters by adding small "adapter" matrices alongside the original weights. Instead of modifying 7 billion parameters, LoRA modifies ~100 million. This is what makes fine-tuning possible on a laptop. See the [dedicated LoRA section](#what-is-lora) below.

**LoRA Adapter**
The output of LoRA fine-tuning — a small file (typically 10-100 MB) containing only the modified parameters. The adapter sits on top of the original base model. To use the fine-tuned model, you load the base model + the adapter. Think of it like a "patch" that modifies the base model's behavior without replacing it.

**LoRA Rank**
A hyperparameter that controls how much the adapter can learn. Rank 4 = less learning capacity but faster training. Rank 16 = more learning capacity but slower and higher overfitting risk. We use rank 8 as a balance. Technically, it's the rank of the low-rank matrices in the adapter — but practically, just think "bigger rank = more expressive adapter."

**Epoch**
One complete pass through the entire training dataset. If we have 922 training examples and train for 3 epochs, the model sees each example 3 times. More epochs = more learning, but also more risk of memorization (overfitting).

**Batch Size**
How many training examples the model processes at once before updating its weights. Batch size 2 means "look at 2 examples, then update weights." Smaller batches = more frequent updates = less memory required. On our 36GB M3 Pro, we use batch size 2-4.

**Learning Rate**
How much the model's weights change in response to each training example. Too high = model learns too fast and becomes unstable (like cramming for an exam and getting confused). Too low = model barely learns anything. We use 1e-5 (0.00001), which is typical for LoRA fine-tuning.

**Overfitting**
When the model memorizes the training data instead of learning the underlying patterns. An overfitted model scores great on training examples but poorly on new conversations it hasn't seen. Signs: training loss keeps dropping but validation loss starts climbing. The cure: fewer epochs, lower LoRA rank, or more training data.

**Knowledge Distillation**
Using a large, expensive model (the "teacher") to generate training data that a small, cheap model (the "student") learns from. We use Claude (the teacher, ~100B+ parameters, runs in the cloud) to generate 170 phone conversations, then use those conversations to train Phi4-mini (the student, 3.8B parameters, runs on your laptop). The student can't match the teacher on everything, but it can match the teacher on this specific task.

### Model Formats

**GGUF (GPT-Generated Unified Format)**
The file format that Ollama uses to store and run models. It's a single file containing the model's weights, metadata, and tokenizer. When we fine-tune with MLX, we produce MLX-format adapters, which we then convert to GGUF so Ollama can use them.

**Quantization**
Compressing a model by using less precise numbers for its weights. A "full precision" model uses 32-bit floating point numbers (4 bytes each). Quantization reduces this to 4-bit (0.5 bytes each), making the model ~8x smaller on disk and ~4x faster, with only a small quality loss. When you see `q4_K_M` in an Ollama model name, that's 4-bit quantization. All our Ollama models are quantized.

**Chat Template**
The special formatting that each model family expects for conversations. Phi4 uses `<|user|>...<|end|>`, Mistral uses `[INST]...[/INST]`, Gemma uses `<start_of_turn>user...`. Getting this wrong means the model sees garbled input. Our conversion script (`convert_to_chat_templates.py`) handles this automatically.

**Tokenizer**
The component that converts text into numbers (tokens) that the model can process. "Hello, how are you?" might become `[15496, 11, 703, 527, 499, 30]`. Each model family has its own tokenizer. The tokenizer is baked into the GGUF file.

### Infrastructure

**MLX (Machine Learning eXploration)**
Apple's machine learning framework, designed specifically for Apple Silicon chips (M1, M2, M3, M4). It's like PyTorch or TensorFlow, but optimized for the Mac's unified memory architecture. This is why fine-tuning on a MacBook is possible — MLX can use all 36GB of your RAM as GPU memory.

**mlx-lm**
A Python library built on top of MLX that provides ready-to-use functions for loading, fine-tuning, and running LLMs. It handles the LoRA implementation, training loop, and model I/O so we don't have to write low-level ML code. This is our primary fine-tuning tool.

**Ollama**
A tool for running LLMs locally. It manages model downloads, quantization, and serving. Think of it as "Docker for AI models." Our phone agent uses Ollama to run models — so after fine-tuning, we need to get our trained model back into Ollama.

**Modelfile**
Ollama's configuration file for a model. It specifies which base model to use, what system prompt to include, and any parameter overrides (temperature, etc.). After fine-tuning, we create a Modelfile that points to our fine-tuned GGUF weights.

**Unified Memory**
Apple Silicon's architecture where the CPU and GPU share the same physical RAM. On a traditional PC, you have separate CPU RAM (32GB) and GPU VRAM (12GB). On Apple Silicon, the M3 Pro's 36GB is available to both. This is critical for fine-tuning because loading a 7B model requires ~14GB of memory, and the training process needs additional memory for gradients and optimizer state.

---

## Why Fine-Tune Instead of Prompting?

You might ask: "Why not just write a really good system prompt?" That's a fair question. Here's why fine-tuning is better for this use case:

### The System Prompt Problem

Right now, every time the phone agent generates a response, it sends a ~500-word system prompt to the model:

```
[System prompt: 500 words explaining persona, rules, examples]
[Conversation history: 200-400 words]
[Model generates: 20 words]
```

That's 700+ input tokens processed for every single 20-word reply. On a 3.8B model running locally, processing those input tokens takes real time — about 800-1200ms just for the prompt, before the model even starts generating.

### What Fine-Tuning Changes

After fine-tuning, the persona knowledge is baked into the model's weights. The system prompt shrinks from 500 words to ~50:

```
[System prompt: 50 words — just "You are Smith Plumbing receptionist"]
[Conversation history: 200-400 words]
[Model generates: 20 words]
```

That's a ~60% reduction in input tokens per turn, which directly translates to faster responses on the phone.

### The Quality Difference

| Aspect | Prompting Only | Fine-Tuned |
|--------|---------------|------------|
| Persona consistency | Drifts after long conversations | Stable — it's in the weights |
| Response length | Tends to be verbose despite instructions | Learns to be brief from examples |
| JSON format compliance | Frequently malformed with small models | Learns the format from repetition |
| Echo-back pattern | Sometimes paraphrases instead of echoing | Internalizes the echo pattern |
| Latency per turn | 800-1200ms prompt overhead | 200-400ms prompt overhead |
| Cost to run | $0 (local) | $0 (local) — same model, better behavior |

### When Prompting IS Enough

Fine-tuning isn't always the answer. For our large judge model (Gemma4 26B), prompting is sufficient — it's big enough to follow complex instructions without fine-tuning. We only fine-tune the small, fast models (3.8B-7B) that struggle with prompt-following.

---

## Our Hardware: Apple M3 Pro

### Why This Matters

Fine-tuning an LLM typically requires expensive NVIDIA GPUs (A100, H100) that cost $10,000+ each. Apple Silicon changes this equation because of **unified memory**.

### What We're Working With

| Spec | Value | Why It Matters |
|------|-------|---------------|
| **Chip** | Apple M3 Pro | 12-core CPU + 18-core GPU, both can access all RAM |
| **RAM** | 36 GB unified | Shared between CPU and GPU — no separate VRAM bottleneck |
| **Memory bandwidth** | 150 GB/s | How fast data moves to the GPU — directly affects token generation speed |

### Memory Budget During Fine-Tuning

Fine-tuning a model requires roughly this much memory:

```
Model weights (quantized):     ~4 GB  (for a 7B model in 4-bit)
LoRA adapter weights:          ~0.1 GB
Optimizer state:               ~0.3 GB
Gradient computation:          ~2 GB
Training batch:                ~1 GB
─────────────────────────────────────
Total:                         ~7.5 GB per model

Our available memory:          36 GB
Headroom for OS + apps:        ~8 GB
Available for training:        ~28 GB  (comfortable margin)
```

This is why LoRA is essential — full fine-tuning of a 7B model would need ~56 GB, far more than our 36 GB allows. LoRA keeps us well within budget.

### Speed Expectations

Based on our hardware and the seed doc benchmarks:

| Model | Base Inference | Training Time (3 epochs) | Adapter Size |
|-------|---------------|-------------------------|-------------|
| Phi4-mini 3.8B | ~2,602ms/turn | ~15 minutes | ~30 MB |
| Mistral 7B | ~4,463ms/turn | ~25 minutes | ~60 MB |
| Gemma4 E2B 7B | ~4,500ms/turn (est.) | ~25 minutes | ~60 MB |
| **Total** | | **~65 minutes** | **~150 MB** |

---

## The Software Stack

Here's every piece of software involved and how they connect:

```
┌─────────────────────────────────────────────────────────────────┐
│                    OUR FINE-TUNING PIPELINE                      │
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐       │
│  │  Training     │    │   MLX +      │    │   Ollama     │       │
│  │  Data         │───>│   mlx-lm     │───>│              │       │
│  │  (JSONL)      │    │  (fine-tune) │    │  (deploy)    │       │
│  └──────────────┘    └──────────────┘    └──────────────┘       │
│        │                    │                    │                │
│   922 turn-level      LoRA adapters        GGUF model           │
│   examples             (~60 MB)           ready to serve         │
│                             │                    │                │
│                    ┌────────┴────────┐           │                │
│                    │  Convert to     │           │                │
│                    │  GGUF format    │──────────>│                │
│                    └─────────────────┘           │                │
│                                                  │                │
│                                          ┌───────┴──────┐        │
│                                          │ Phone Agent   │        │
│                                          │ (uses Ollama  │        │
│                                          │  for inference)│       │
│                                          └──────────────┘        │
└─────────────────────────────────────────────────────────────────┘
```

### Software Requirements

| Software | Version | Purpose |
|----------|---------|---------|
| **Python 3.11+** | System | Runs all scripts |
| **MLX** | Already installed | Apple's ML framework (low-level) |
| **mlx-lm** | Needs install | High-level fine-tuning library for MLX |
| **Ollama** | Already installed | Model serving and deployment |
| **HuggingFace Hub** | Needs install | Downloads base model weights for fine-tuning |

**Why do we need HuggingFace if we already have the models in Ollama?**

Ollama stores models in GGUF format (quantized, ready to run). MLX needs the original unquantized weights in HuggingFace format to fine-tune. Think of GGUF as a "compiled" version — you can run it, but you can't edit it. HuggingFace weights are the "source code" that we can modify.

After fine-tuning, we convert back to GGUF so Ollama can serve the modified model.

---

## What is LoRA?

LoRA (Low-Rank Adaptation) is the technique that makes fine-tuning possible on consumer hardware. This section explains how it works at an intuitive level.

### The Problem LoRA Solves

A 7B model has ~7 billion parameters organized into large matrices (tables of numbers). Full fine-tuning means updating all 7 billion numbers, which requires:
- Loading all 7B weights into memory (~28 GB at full precision)
- Storing a copy of the gradients (~28 GB)
- Storing optimizer states (~28 GB)
- Total: ~84 GB — way more than our 36 GB

### The LoRA Insight

Researchers discovered that when you fine-tune a model on a specific task, the *changes* to the weight matrices are usually "low-rank" — meaning they can be approximated by much smaller matrices.

Imagine a weight matrix W that's 4096 × 4096 (about 16 million numbers). Instead of modifying W directly, LoRA adds two small matrices:

```
Original:  W                    (4096 × 4096 = 16,777,216 parameters)

LoRA:      W + A × B            where:
           A is (4096 × 8)      = 32,768 parameters
           B is (8 × 4096)      = 32,768 parameters
                                ─────────────────────
           Total LoRA params:   = 65,536 parameters  (0.4% of original!)
```

The "8" in the middle is the **LoRA rank**. A rank of 8 means each adapter matrix has 8 columns/rows. Higher rank = more expressive but more parameters.

### What This Means Practically

| Aspect | Full Fine-Tuning | LoRA (rank 8) |
|--------|-----------------|---------------|
| Parameters modified | 7,000,000,000 | ~100,000,000 (~1.5%) |
| Memory needed | ~84 GB | ~7.5 GB |
| Training time (7B) | Hours on GPU cluster | ~25 min on M3 Pro |
| Output size | 14 GB (full model copy) | ~60 MB (adapter only) |
| Quality | Best possible | 90-95% of full fine-tuning |

### Intuitive Analogy

Think of the base model as a skilled employee who just joined your company. Full fine-tuning is like retraining them from scratch on everything. LoRA is like giving them a small "cheat sheet" specific to your company — they keep all their existing skills and just reference the cheat sheet for company-specific behavior. The cheat sheet (adapter) is tiny compared to everything they know (base weights), but it's enough to make them great at this specific job.

---

## The Full Pipeline

Here's every step from training data to deployed model, in order:

```
Step 1: PREPARE DATA
  data/splits/train_mlx.jsonl (922 examples)
  data/splits/val_mlx.jsonl (159 examples)
         │
         ▼
Step 2: DOWNLOAD BASE WEIGHTS
  HuggingFace → microsoft/phi-4-mini-instruct
  HuggingFace → mistralai/Mistral-7B-Instruct-v0.3
  HuggingFace → google/gemma-2-2b-it  (or gemma-4-e2b when available)
         │
         ▼
Step 3: FINE-TUNE WITH MLX LoRA
  mlx_lm.lora --model <base> --data <train> --adapter-path <output>
  Repeat for each model (3 runs, ~65 min total)
         │
         ▼
Step 4: TEST THE ADAPTER
  mlx_lm.generate --model <base> --adapter-path <adapter>
  Quick sanity check: does it sound like a receptionist?
         │
         ▼
Step 5: FUSE ADAPTER INTO BASE MODEL
  mlx_lm.fuse --model <base> --adapter-path <adapter>
  Merges the LoRA adapter into the base weights
         │
         ▼
Step 6: CONVERT TO GGUF
  mlx_lm.convert --to-gguf
  Produces a .gguf file that Ollama can load
         │
         ▼
Step 7: IMPORT INTO OLLAMA
  ollama create smith-plumbing-phi4 -f Modelfile
  Creates an Ollama model from the GGUF + a Modelfile
         │
         ▼
Step 8: TOURNAMENT EVALUATION
  Run all 6 models (3 base + 3 fine-tuned) through
  the held-out test set, score with LLM judge
         │
         ▼
Step 9: DEPLOY WINNER
  Update .env: LLM_FAST=smith-plumbing-phi4
  The phone agent now uses the fine-tuned model
```

---

## Step-by-Step Walkthrough

### Step 1: Prepare Data (Already Done)

Our training data is already in the right format. The key file is `data/splits/train_mlx.jsonl`, where each line is a JSON object with a `messages` array:

```json
{
  "messages": [
    {"role": "system", "content": "You are a friendly, warm phone receptionist..."},
    {"role": "user", "content": "[phone rings]"},
    {"role": "assistant", "content": "Hi, Smith Plumbing, how can I help?"}
  ]
}
```

Each example trains the model to generate one specific assistant reply given the conversation history. We have 922 of these in the training set.

See [Training Methodology](training-methodology.md) for full details on how this data was generated and structured.

### Step 2: Install Dependencies

```bash
pip install mlx-lm huggingface_hub
```

`mlx-lm` brings in the fine-tuning tools. `huggingface_hub` handles downloading base model weights.

### Step 3: Download Base Weights

```bash
# These download the full-precision HuggingFace weights (~8-14 GB each)
huggingface-cli download microsoft/phi-4-mini-instruct
huggingface-cli download mistralai/Mistral-7B-Instruct-v0.3
huggingface-cli download google/gemma-2-2b-it
```

These are cached in `~/.cache/huggingface/` and reused across fine-tuning runs.

### Step 4: Fine-Tune with LoRA

The actual fine-tuning command for each model:

```bash
# Phi4-mini (~15 min)
python -m mlx_lm.lora \
  --model microsoft/phi-4-mini-instruct \
  --data data/splits/ \
  --train \
  --batch-size 2 \
  --lora-rank 8 \
  --num-layers 16 \
  --iters 600 \
  --learning-rate 1e-5 \
  --adapter-path adapters/phi4-mini

# Mistral 7B (~25 min)
python -m mlx_lm.lora \
  --model mistralai/Mistral-7B-Instruct-v0.3 \
  --data data/splits/ \
  --train \
  --batch-size 2 \
  --lora-rank 8 \
  --num-layers 16 \
  --iters 600 \
  --learning-rate 1e-5 \
  --adapter-path adapters/mistral-7b

# Gemma E2B (~25 min)
python -m mlx_lm.lora \
  --model google/gemma-2-2b-it \
  --data data/splits/ \
  --train \
  --batch-size 2 \
  --lora-rank 8 \
  --num-layers 16 \
  --iters 600 \
  --learning-rate 1e-5 \
  --adapter-path adapters/gemma-e2b
```

**What `--iters 600` means:** With 922 training examples and batch size 2, one epoch is ~461 iterations. 600 iterations ≈ 1.3 epochs. We can increase this to 1380 for 3 full epochs, but starting conservative reduces overfitting risk.

**What happens during training:** MLX loads the base model, attaches LoRA adapter matrices to each transformer layer, then runs through the training examples. For each batch, it:
1. Feeds the conversation history through the model
2. Compares the model's predicted next tokens against the actual assistant reply
3. Computes how wrong the predictions were (the "loss")
4. Updates only the LoRA adapter weights to reduce the loss

The loss should steadily decrease. If it plateaus, the model has learned what it can from this data.

### Step 5: Test the Adapter

Before converting, do a quick sanity check:

```bash
python -m mlx_lm.generate \
  --model microsoft/phi-4-mini-instruct \
  --adapter-path adapters/phi4-mini \
  --prompt "You are a receptionist at Smith Plumbing.\n\nUser: Hi, my kitchen sink is leaking pretty bad.\n\nAssistant:"
```

If it responds like a warm receptionist ("Oh no, a leaking sink — let's get that taken care of!"), the fine-tuning worked.

### Step 6: Fuse and Convert

```bash
# Merge adapter into base model
python -m mlx_lm.fuse \
  --model microsoft/phi-4-mini-instruct \
  --adapter-path adapters/phi4-mini \
  --save-path models/phi4-mini-fused

# Convert to GGUF for Ollama (4-bit quantization)
python -m mlx_lm.convert \
  --model models/phi4-mini-fused \
  --quantize q4_K_M \
  --to-gguf \
  --output models/smith-plumbing-phi4.gguf
```

**Fusing** permanently merges the LoRA adapter into the base model weights. After fusing, you have a standalone model that doesn't need the adapter file.

**Converting to GGUF** takes the fused model and packages it in the format Ollama expects, with 4-bit quantization to keep the file size manageable.

### Step 7: Import into Ollama

Create a Modelfile:

```dockerfile
# models/Modelfile.phi4
FROM ./smith-plumbing-phi4.gguf

PARAMETER temperature 0.7
PARAMETER top_p 0.9

SYSTEM """You are a friendly phone receptionist at Smith Plumbing."""
```

Then import:

```bash
ollama create smith-plumbing-phi4 -f models/Modelfile.phi4
```

Now `ollama run smith-plumbing-phi4` runs your fine-tuned model, and the phone agent can use it by setting `LLM_FAST=smith-plumbing-phi4` in the `.env` file.

### Steps 8-9: Evaluation and Deployment

See [Training Methodology](training-methodology.md) for the tournament evaluation design and deployment process.

---

## How to Know If It Worked

### During Training: Watch the Loss

```
Iter 100: train loss 2.41, val loss 2.38
Iter 200: train loss 1.89, val loss 1.92
Iter 300: train loss 1.52, val loss 1.58
Iter 400: train loss 1.31, val loss 1.40   ← gap growing slightly
Iter 500: train loss 1.18, val loss 1.35   ← gap growing more
Iter 600: train loss 1.08, val loss 1.33   ← starting to overfit
```

**Healthy training:** Both train and val loss decrease together.
**Overfitting:** Train loss keeps dropping but val loss plateaus or increases. The gap between them is the "generalization gap." If it exceeds ~0.5, stop training or reduce the LoRA rank.

### After Training: Tournament Evaluation

Run the 3 base models and 3 fine-tuned models through the same 21 held-out test conversations. Score each with the LLM judge on 6 phases × 3 dimensions = 18 quality metrics.

**Success criteria from the seed doc:**
1. At least one fine-tuned model scores >4.0/5 average
2. Fine-tuned model beats its base by >0.3 average
3. Post-tuning latency stays within 4-second budget
4. Test scores within 0.5 of training scores (no overfitting)

---

## Common Pitfalls

### "My model sounds great on training examples but terrible on new ones"
**Overfitting.** Reduce LoRA rank from 8 to 4, or stop training earlier (fewer iterations). More training data also helps.

### "The fine-tuned model generates gibberish or repeats itself"
**Wrong chat template.** Each model family expects a specific conversation format. If the training data uses Mistral's format but you're fine-tuning Phi4, the model learns garbage. Our `convert_to_chat_templates.py` script prevents this.

### "Training is extremely slow (hours instead of minutes)"
**Not using MLX.** Make sure you installed `mlx-lm`, not a PyTorch-based trainer. MLX is optimized for Apple Silicon; PyTorch on Mac falls back to CPU and is 10-50x slower.

### "Out of memory during training"
**Reduce batch size** to 1. If still failing, try a smaller LoRA rank (4 instead of 8). The 36GB M3 Pro should handle 7B models comfortably, but if you have other apps consuming memory, close them.

### "The model is good at greeting but terrible at scheduling"
**Phase imbalance.** Check the training data distribution — if match_propose has 5 examples but greeting has 100, the model barely learned scheduling. Generate more examples targeting the weak phase. See [Training Methodology](training-methodology.md) for how we balanced phases.

### "Ollama can't load my converted model"
**GGUF version mismatch.** Make sure `mlx-lm` and Ollama are both up to date. The GGUF format evolves, and older converters produce files that newer Ollama versions reject.

---

## Further Reading

### Our Project Docs
- [Conversation Phases](phases.md) — detailed breakdown of the 11 conversation phases
- [Training Methodology](training-methodology.md) — how the training data was generated, split, and validated
- [Scenario Matrix](../data/scenario_matrix.json) — the 8×7×8 scenario definitions
- [Training Data Explorer](html/seed-training-pipeline.html) — interactive HTML page to browse all 170 conversations
- [This guide as HTML](html/fine-tuning-guide.html) — rendered version with diagrams and glossary cards
- [README](../README.md) — project overview and quick start

### External Resources
- [LoRA: Low-Rank Adaptation of Large Language Models](https://arxiv.org/abs/2106.09685) — the original paper by Hu et al. (2021)
- [MLX Documentation](https://ml-explore.github.io/mlx/) — Apple's ML framework docs
- [mlx-lm GitHub](https://github.com/ml-explore/mlx-examples/tree/main/llms) — the fine-tuning library we use
- [Ollama Documentation](https://ollama.ai/docs) — model serving and Modelfile reference
- [QLoRA: Efficient Finetuning of Quantized LLMs](https://arxiv.org/abs/2305.14314) — quantized LoRA variant (related technique)

### Key Concepts to Study Further
- **Transformer architecture** — the neural network design all modern LLMs use
- **Attention mechanism** — how transformers decide which parts of the input to focus on
- **Tokenization** — how text becomes numbers (BPE, SentencePiece)
- **Gradient descent** — the optimization algorithm that updates weights during training
- **Quantization** — compressing model weights for faster inference
