#!/usr/bin/env python3
"""Interactive chat with the fine-tuned phone agent model."""

from mlx_lm import load, generate
from mlx_lm.sample_utils import make_sampler

MODEL = "microsoft/Phi-4-mini-instruct"
ADAPTER = "adapters/phi4-mini"

SYSTEM = "You are a friendly, warm phone receptionist at Smith Plumbing. Keep responses to 1-2 sentences. Echo the caller's words back. Sound natural, not scripted."

def main():
    print("Loading model + adapter...")
    model, tokenizer = load(MODEL, adapter_path=ADAPTER)
    sampler = make_sampler(temp=0.7, top_p=0.9)
    print(f"Ready! You are calling Smith Plumbing. Type 'quit' to hang up.\n")

    history = []

    while True:
        caller = input("\033[92mYou: \033[0m").strip()
        if not caller or caller.lower() in ("quit", "exit", "bye"):
            print("\n\033[93mAgent:\033[0m Thanks for calling Smith Plumbing! Have a great day.")
            break

        history.append({"role": "user", "content": caller})

        messages = [{"role": "system", "content": SYSTEM}] + history
        prompt = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)

        response = generate(
            model, tokenizer, prompt=prompt,
            max_tokens=80, sampler=sampler,
            verbose=False
        )

        # Clean up response
        response = response.strip()
        if "<|end|>" in response:
            response = response[:response.index("<|end|>")]
        if "<|assistant|>" in response:
            response = response[response.index("<|assistant|>") + len("<|assistant|>"):]
        response = response.strip()

        print(f"\033[93mAgent:\033[0m {response}\n")
        history.append({"role": "assistant", "content": response})


if __name__ == "__main__":
    main()
