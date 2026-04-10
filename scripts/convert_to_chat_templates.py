#!/usr/bin/env python3
"""Convert training conversations to turn-level prompt/completion examples.

Instead of one example per conversation (which starts with an assistant turn
before any user turn — breaking Mistral/Gemma templates), this produces one
example per agent reply. Each example contains the full conversation history
up to that point as context, with the single agent reply as the completion.

This fixes the assistant-before-user bug and multiplies training signal:
100 conversations × ~6 agent turns each ≈ 600+ training examples.

Output formats:
  - mlx:     {"messages": [..., {"role": "assistant", "content": "target"}]}
  - phi4:    <|system|>...<|end|><|user|>...<|end|><|assistant|>...<|end|>
  - mistral: [INST] ... [/INST] response
  - gemma:   <start_of_turn>user\n...<end_of_turn><start_of_turn>model\n...<end_of_turn>
"""

import json
import argparse
from pathlib import Path

SYSTEM_PROMPT = """You are a friendly, warm phone receptionist at Smith Plumbing. You've worked here for years and you genuinely care about helping people.

YOUR VOICE:
- Warm and empathetic. "Oh no", "that's no fun", "we'll get that taken care of"
- Use natural filler: "let me check...", "alright", "sure thing"
- Keep it brief. 1-2 sentences max.
- Sound like you're talking, not reading a script

You are on a live phone call. Never break character. Never narrate your actions. Speak directly to the caller using "you" and "your". Echo the caller's actual words back to them."""


def conversation_to_turn_examples(conv):
    """Split one conversation into multiple turn-level training examples.

    For the opening greeting (agent speaks first with no prior user turn),
    we frame it as: system prompt asks the agent to greet, the "user" turn
    is "[phone rings]", and the agent's greeting is the completion.

    For all subsequent agent turns, the prompt is the full history up to
    that point (system + all prior user/assistant turns) and the completion
    is the single agent reply.
    """
    examples = []
    turns = conv["turns"]

    for i, turn in enumerate(turns):
        if turn["role"] != "agent":
            continue

        messages = [{"role": "system", "content": SYSTEM_PROMPT}]

        if i == 0:
            # Opening greeting: no prior caller turn yet.
            # Add a synthetic user turn so templates stay user→assistant.
            messages.append({"role": "user", "content": "[phone rings]"})
        else:
            # Build history from all prior turns
            for prior in turns[:i]:
                role = "assistant" if prior["role"] == "agent" else "user"
                messages.append({"role": role, "content": prior["text"]})

        # The target completion
        messages.append({"role": "assistant", "content": turn["text"]})

        examples.append({
            "messages": messages,
            "source_id": conv["id"],
            "phase": turn.get("phase", ""),
            "turn_index": i,
        })

    return examples


def messages_to_phi4(messages):
    """Phi4-mini chat template."""
    parts = []
    for msg in messages:
        parts.append(f"<|{msg['role']}|>\n{msg['content']}<|end|>")
    return "".join(parts)


def messages_to_mistral(messages):
    """Mistral 7B Instruct chat template."""
    parts = []
    system_msg = ""
    for msg in messages:
        if msg["role"] == "system":
            system_msg = msg["content"] + "\n\n"
        elif msg["role"] == "user":
            content = msg["content"]
            if system_msg:
                content = system_msg + content
                system_msg = ""
            parts.append(f"[INST] {content} [/INST]")
        elif msg["role"] == "assistant":
            parts.append(f" {msg['content']}")
    return "".join(parts)


def messages_to_gemma(messages):
    """Gemma4 chat template."""
    parts = []
    system_msg = ""
    for msg in messages:
        if msg["role"] == "system":
            system_msg = msg["content"] + "\n\n"
        elif msg["role"] == "user":
            content = msg["content"]
            if system_msg:
                content = system_msg + content
                system_msg = ""
            parts.append(f"<start_of_turn>user\n{content}<end_of_turn>")
        elif msg["role"] == "assistant":
            parts.append(f"<start_of_turn>model\n{msg['content']}<end_of_turn>")
    return "".join(parts)


FORMAT_CONVERTERS = {
    "phi4": messages_to_phi4,
    "mistral": messages_to_mistral,
    "gemma": messages_to_gemma,
}


def main():
    parser = argparse.ArgumentParser(
        description="Convert training conversations to turn-level chat template examples"
    )
    parser.add_argument("--input", "-i", required=True, help="Input JSON or JSONL file")
    parser.add_argument("--format", "-f", choices=["mlx", "phi4", "mistral", "gemma"],
                        default="mlx", help="Output format (default: mlx)")
    parser.add_argument("--output", "-o", help="Output file (default: auto-named)")
    args = parser.parse_args()

    # Load conversations
    input_path = Path(args.input)
    if input_path.suffix == ".jsonl":
        with open(input_path) as f:
            convos = [json.loads(line) for line in f if line.strip()]
    else:
        with open(input_path) as f:
            convos = json.load(f)

    # Convert to turn-level examples
    all_examples = []
    for conv in convos:
        all_examples.extend(conversation_to_turn_examples(conv))

    # Format output
    output_path = args.output or f"{input_path.stem}_{args.format}.jsonl"
    with open(output_path, "w") as f:
        for ex in all_examples:
            if args.format == "mlx":
                row = {"messages": ex["messages"]}
            else:
                converter = FORMAT_CONVERTERS[args.format]
                row = {"text": converter(ex["messages"]), "source_id": ex["source_id"]}
            f.write(json.dumps(row) + "\n")

    # Stats
    phases = {}
    for ex in all_examples:
        p = ex["phase"]
        phases[p] = phases.get(p, 0) + 1

    print(f"Converted {len(convos)} conversations → {len(all_examples)} turn-level examples")
    print(f"Format: {args.format} → {output_path}")
    print(f"Examples per phase: {json.dumps(phases, indent=2)}")


if __name__ == "__main__":
    main()
