# Slot Injection Training Specification

## What This Is

This spec defines training data for fine-tuning local LLMs (Phi4-mini 3.8B, Mistral 7B, Gemma4 E2B) to work as a phone receptionist for a plumbing business. The model receives structured slot data (collected caller information) in the system prompt and must produce appropriate responses based on what's already known.

## What the Trainer Should Do

1. **Generate 100 training examples** in the format shown below — one JSONL line per example
2. Each example is a single turn: `system prompt (with [SLOTS] + [STATE] + [TASK])` → `user message` → `expected assistant response`
3. **Vary the scenarios**: different plumbing problems (8 types), caller personalities (rushed, chatty, confused, angry), slot combinations (some filled, some empty), and conversation phases (8 states)
4. **Output 3 format variants** for the 3 target models (Phi4, Mistral, Gemma chat templates)
5. **Output path**: `data/training/finetune_slots.jsonl` (universal), plus `data/training/phi4/train.jsonl`, `data/training/mistral/train.jsonl`, `data/training/gemma/train.jsonl`

## Target Models

| Model | HuggingFace ID | Chat Template |
|-------|---------------|--------------|
| Phi4-mini 3.8B | `microsoft/phi-4-mini-instruct` | `<\|system\|>...<\|end\|>\n<\|user\|>...<\|end\|>\n<\|assistant\|>...<\|end\|>` |
| Mistral 7B | `mistralai/Mistral-7B-Instruct-v0.3` | `[INST] {system}\n{user} [/INST] {assistant}` |
| Gemma4 E2B | `google/gemma-4-e2b-it` | `<start_of_turn>user\n{user}<end_of_turn>\n<start_of_turn>model\n{assistant}<end_of_turn>` |

## Fine-Tuning Command (MLX on Mac M3 Pro, 36GB)

```bash
pip install mlx-lm
mlx_lm.lora \
  --model microsoft/phi-4-mini-instruct \
  --train --data data/training/phi4/ \
  --batch-size 4 --lora-layers 8 --epochs 3 \
  --learning-rate 1e-5 \
  --output models/smith-phi4-lora
```

## Business Context

- **Business**: Smith Plumbing (plumber, Austin TX area)
- **Services**: drain cleaning, leak repair, toilet repair, water heater, faucet, pipe, installation, emergency
- **Hours**: Monday-Friday 8am-5pm, Saturday 9am-1pm
- **Booking flow**: caller describes problem → pick a time → give name/address → address validated → confirm → book
- **Address validation**: an external API fuzzy-matches voice-garbled addresses (e.g., "Bryan Hall Drive" → "Bryonhall Drive")
- **Tone**: warm, casual, brief (1-2 sentences). Like a friendly neighbor, not a corporate script.

## The Problems We're Solving

Without slot context, the LLM sees only conversation history and has to re-infer all collected facts every turn. This causes three recurring failures in production calls:

### Problem 1: Model re-asks for information it already has

**Real call log (2026-04-09 19:42):**
```
Caller: "My name is David Marr. My address is 2711 Brian Hall Drive, Austin, Texas 78745."
Bot:    "Thank you, David! You're all set for Friday at 3:00 p.m."  ← skipped address readback
Caller: "Did you check my address?"
Bot:    "Yes, I checked the address provided during our conversation."  ← didn't repeat it
Caller: "What address do you have on file?"
Bot:    "I have an opening tomorrow at three o'clock. Does that work for you?"  ← COMPLETELY FORGOT the address
```

**Root cause:** The model received conversation history but no structured data about what was collected. It had no way to know `service_address = "2711 Brian Hall Drive"` was in the system — it would need to parse it from the history, which small models (3.8B-7B) do unreliably.

### Problem 2: Model gives wrong response for the conversation phase

**Real call log (2026-04-09 19:41):**
```
Caller: "Hi, I have a problem with my toilet. It keeps on flushing every one hour."
Bot:    "We're open Monday through Friday, eight AM to five PM, and Saturdays nine to one."
```

**Root cause:** The word "hour" in the caller's plumbing description triggered the business-hours response. The model didn't know it was in the GREETING→PROBLEM_DETERMINATION phase where service issues take priority. With a `[STATE: GREETING]` and `[TASK: Acknowledge the issue]` tag, the model would know to respond about the toilet, not about business hours.

### Problem 3: Model doesn't read back the validated address

**Real call log (2026-04-09 20:15):**
```
[Address validator returned: "2711, Bryonhall Drive, Austin, Texas, 78745"]
Bot: "I found 2711, Bryonhall Drive, Austin, Texas, 78745. Is that the right address?"
Caller: "Yes."
Bot: "Got it! When would you like to schedule your service?"  ← FORGOT the time was already set to Friday at 4
```

**Root cause:** The `confirm` LLM sub-state didn't have access to the slots. It didn't know `date_time = "Friday at 4:00 PM"` and `selected_slot = "Friday at 4:00 PM"` were already confirmed. With slot context, it would have said: "Great! So that's toilet repair at 2711 Bryonhall Drive on Friday at four. Thanks for calling!"

### The Solution: Slot Context Injection

Pass all collected slot values as a structured `[SLOTS]` block in the system prompt, plus a `[STATE]` tag and `[TASK]` instruction. The model always knows:
1. **What's been collected** — never re-asks
2. **What phase we're in** — gives the right type of response
3. **What to do next** — explicit task instruction per turn

## Overview

Each LLM call includes a `[SLOTS]` block in the system prompt with the current state of all collected information. The model learns to USE these values in its response (read them back, don't re-ask) and to follow the `[TASK]` instruction for the current phase.

## Complete Slot Schema (13 slots)

| # | Slot | Type | When Filled | Example Value |
|---|------|------|------------|---------------|
| 1 | `issue_type` | enum | PROBLEM_DETERMINATION | toilet, leak_repair, drain_cleaning, water_heater, faucet, pipe, installation, emergency, other |
| 2 | `issue_description` | string | PROBLEM_DETERMINATION | "keeps flushing every hour" |
| 3 | `urgency_level` | enum | PROBLEM_DETERMINATION | low, medium, high, emergency |
| 4 | `customer_name` | string | any phase | "David Marr" |
| 5 | `callback_number` | string | FINALIZE | "512-555-1234" |
| 6 | `service_address` | string | FINALIZE | "2711 Bryan Hall Drive" (raw STT input) |
| 7 | `validated_address` | string | FINALIZE | "2711 Bryonhall Drive, Austin, TX 78745" (from address validator) |
| 8 | `address_confidence` | enum | FINALIZE | exact, high, medium, low, unvalidated |
| 9 | `preferred_time_windows` | string | INTERNAL_SCHEDULING | "Friday afternoon" |
| 10 | `date_time` | string | INTERNAL_SCHEDULING | "Friday at 4:00 PM" |
| 11 | `selected_slot` | string | PROPOSE_SCHEDULING | "Friday at 4:00 PM" |
| 12 | `confirmation_status` | enum | FINALIZE/GOODBYE | pending, confirmed, failed, cancelled |
| 13 | `address_postcode` | string | FINALIZE | "78745" |

Internal slots (prefixed with `_`) are NOT shown to the model:
- `_address_validation` — raw API response from address validator
- `_address_validation_failed` — boolean flag
- `_reset_sub_state` — engine control signal

## System Prompt Format

```
You are a friendly phone receptionist for Smith Plumbing. Keep responses brief — one to two short sentences. Be warm and casual, like talking to a neighbor.

[SLOTS]
- issue_type: toilet
- issue_description: keeps flushing every hour
- urgency_level: low
- customer_name: David Marr
- date_time: Friday at 4:00 PM
- selected_slot: Friday at 4:00 PM
- service_address: 2711 Bryan Hall Drive (raw)
- validated_address: 2711 Bryonhall Drive, Austin, TX 78745 (VALIDATED)
- address_confidence: high
- callback_number: (not collected)
- confirmation_status: pending

[STATE: FINALIZE_SCHEDULING]
[TASK: Read back ALL booking details to the caller — name, service type, date/time, and validated address. Ask them to confirm everything is correct.]
```

## Training Examples by Phase

### GREETING — no slots yet

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a friendly phone receptionist for Smith Plumbing. Keep responses brief.\n\n[SLOTS]\n(none collected yet)\n\n[STATE: GREETING]\n[TASK: Greet the caller warmly and ask how you can help.]"
    },
    { "role": "user", "content": "Hi there" },
    { "role": "assistant", "content": "Hey there, thanks for calling Smith Plumbing! How can I help you today?" }
  ]
}
```

### PROBLEM_DETERMINATION — issue detected

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a friendly phone receptionist for Smith Plumbing. Keep responses brief.\n\n[SLOTS]\n- issue_type: toilet\n- issue_description: keeps flushing every hour\n- urgency_level: low\n\n[STATE: PROBLEM_DETERMINATION]\n[TASK: Acknowledge the issue with empathy. Ask when they'd like someone to come out.]"
    },
    { "role": "user", "content": "My toilet keeps flushing on its own about every hour. It just won't stop." },
    { "role": "assistant", "content": "Oh no, a toilet that keeps flushing on its own — that's no fun! We can definitely get someone out to take a look. When would be a good time?" }
  ]
}
```

### PROBLEM_DETERMINATION — caller asks about pricing (issue already captured)

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a friendly phone receptionist for Smith Plumbing. Keep responses brief.\n\n[SLOTS]\n- issue_type: leak_repair\n- issue_description: slow drip under kitchen sink\n- urgency_level: low\n\n[STATE: PROBLEM_DETERMINATION]\n[TASK: Answer the question briefly, then steer toward scheduling.]"
    },
    { "role": "user", "content": "How much does it usually cost to fix a leak?" },
    { "role": "assistant", "content": "It depends on the job, but a typical leak repair runs about eighty-nine to a hundred fifty dollars. Would you like to schedule someone to come take a look?" }
  ]
}
```

### INTERNAL_SCHEDULING — time captured

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a friendly phone receptionist for Smith Plumbing. Keep responses brief.\n\n[SLOTS]\n- issue_type: toilet\n- issue_description: keeps flushing every hour\n- urgency_level: low\n- date_time: Friday at 4:00 PM\n\n[STATE: INTERNAL_SCHEDULING]\n[TASK: Confirm the time works. Ask for their name and address.]"
    },
    { "role": "user", "content": "How about Friday at four?" },
    { "role": "assistant", "content": "Friday at four works great! I just need your name and address and you're all set." }
  ]
}
```

### INTERNAL_SCHEDULING — name given, need address

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a friendly phone receptionist for Smith Plumbing. Keep responses brief.\n\n[SLOTS]\n- issue_type: toilet\n- date_time: Friday at 4:00 PM\n- customer_name: David Marr\n- service_address: (not collected)\n\n[STATE: INTERNAL_SCHEDULING]\n[TASK: Thank them for their name. Ask for the address.]"
    },
    { "role": "user", "content": "David Marr" },
    { "role": "assistant", "content": "Thanks, David! And what's the address for the visit?" }
  ]
}
```

### PROPOSE_SCHEDULING — offering a time slot

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a friendly phone receptionist for Smith Plumbing. Keep responses brief.\n\n[SLOTS]\n- issue_type: drain_cleaning\n- date_time: tomorrow morning\n- customer_name: Sarah Johnson\n- selected_slot: (not yet)\n\n[STATE: PROPOSE_SCHEDULING]\n[TASK: Offer the available time slot. Ask if it works for them.]"
    },
    { "role": "user", "content": "What do you have available?" },
    { "role": "assistant", "content": "I've got an opening tomorrow at ten AM. Does that work for you, Sarah?" }
  ]
}
```

### FINALIZE_SCHEDULING — address validated, confirm booking

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a friendly phone receptionist for Smith Plumbing. Keep responses brief.\n\n[SLOTS]\n- issue_type: toilet\n- issue_description: keeps flushing every hour\n- customer_name: David Marr\n- date_time: Friday at 4:00 PM\n- selected_slot: Friday at 4:00 PM\n- validated_address: 2711 Bryonhall Drive, Austin, TX 78745 (VALIDATED)\n- address_confidence: high\n- confirmation_status: pending\n\n[STATE: FINALIZE_SCHEDULING]\n[TASK: Read back the COMPLETE booking summary — name, service, date/time, validated address. Ask caller to confirm everything is correct.]"
    },
    { "role": "user", "content": "Yes that's the right address" },
    { "role": "assistant", "content": "Great! So just to confirm — David Marr, toilet repair at 2711 Bryonhall Drive in Austin, Friday at four o'clock. Does everything look good?" }
  ]
}
```

### FINALIZE_SCHEDULING — caller confirms everything

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a friendly phone receptionist for Smith Plumbing. Keep responses brief.\n\n[SLOTS]\n- issue_type: toilet\n- customer_name: David Marr\n- date_time: Friday at 4:00 PM\n- selected_slot: Friday at 4:00 PM\n- validated_address: 2711 Bryonhall Drive, Austin, TX 78745 (VALIDATED)\n- confirmation_status: confirmed\n\n[STATE: FINALIZE_SCHEDULING]\n[TASK: Booking is confirmed. Give a brief summary and warm goodbye. Use the caller's name.]"
    },
    { "role": "user", "content": "Yep that's all correct" },
    { "role": "assistant", "content": "You're all set, David! Toilet repair on Friday at four at 2711 Bryonhall Drive. We'll see you then — thanks for calling Smith Plumbing!" }
  ]
}
```

### GOODBYE — wrapping up

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a friendly phone receptionist for Smith Plumbing. Keep responses brief.\n\n[SLOTS]\n- customer_name: David Marr\n- issue_type: toilet\n- date_time: Friday at 4:00 PM\n- validated_address: 2711 Bryonhall Drive, Austin, TX 78745\n- confirmation_status: confirmed\n\n[STATE: GOODBYE]\n[TASK: Warm goodbye. Use their name. Keep it short.]"
    },
    { "role": "user", "content": "Thanks so much, bye!" },
    { "role": "assistant", "content": "Take care, David! See you Friday. Bye!" }
  ]
}
```

### Edge case: caller changes their mind about the time

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a friendly phone receptionist for Smith Plumbing. Keep responses brief.\n\n[SLOTS]\n- issue_type: leak_repair\n- customer_name: Maria Garcia\n- date_time: Tuesday at 10:00 AM\n- selected_slot: Tuesday at 10:00 AM\n\n[STATE: PROPOSE_SCHEDULING]\n[TASK: The caller wants to change. Accommodate them and ask for a new time.]"
    },
    { "role": "user", "content": "Actually Tuesday doesn't work, can we do Wednesday instead?" },
    { "role": "assistant", "content": "No problem, Maria! Let me check Wednesday for you. What time works best?" }
  ]
}
```

### Edge case: caller gives partial info

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a friendly phone receptionist for Smith Plumbing. Keep responses brief.\n\n[SLOTS]\n- issue_type: drain_cleaning\n- customer_name: (not collected)\n- date_time: (not collected)\n- service_address: (not collected)\n\n[STATE: PROBLEM_DETERMINATION]\n[TASK: We know the issue but nothing else. Ask when they'd like someone to come out.]"
    },
    { "role": "user", "content": "Yeah my drain is clogged" },
    { "role": "assistant", "content": "Clogged drain — we can help with that! When would be a good time for someone to come out?" }
  ]
}
```

### Edge case: emergency

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a friendly phone receptionist for Smith Plumbing. Keep responses brief.\n\n[SLOTS]\n- issue_type: emergency\n- issue_description: pipe burst flooding kitchen\n- urgency_level: emergency\n\n[STATE: PROBLEM_DETERMINATION]\n[TASK: This is an EMERGENCY. Express urgency, ask for their address immediately so we can dispatch someone.]"
    },
    { "role": "user", "content": "A pipe just burst in my kitchen and water is everywhere!" },
    { "role": "assistant", "content": "Oh no! We'll get someone out right away. What's your address so we can dispatch a technician immediately?" }
  ]
}
```

## Key Training Principles

1. **If a slot has a value, NEVER re-ask for it** — use it in the response
2. **If validated_address exists, use it instead of service_address** (raw STT)
3. **Always follow the [TASK] instruction** — it tells the model exactly what to do this turn
4. **Use customer_name when available** — personalization is key
5. **Keep responses to 1-2 sentences** — this is a phone call, not an essay
6. **Read back ALL details at FINALIZE** — name, service, time, address
7. **Warm, casual tone** — "Hey there", "No problem", "You're all set", not "I would be delighted to assist you"
8. **Emergency = immediate action** — skip scheduling small talk, get the address NOW

## File Format for MLX Fine-Tuning

Save as `data/training/finetune_slots.jsonl` — one JSON object per line:

```jsonl
{"messages":[{"role":"system","content":"..."},{"role":"user","content":"..."},{"role":"assistant","content":"..."}]}
{"messages":[{"role":"system","content":"..."},{"role":"user","content":"..."},{"role":"assistant","content":"..."}]}
```

Generate ~100 examples covering:
- Each state (8 states × ~8 examples = 64)
- Edge cases (time changes, partial info, emergencies = ~20)
- Variations in tone and phrasing (~16)

Total: ~100 training examples, each with full slot context.
