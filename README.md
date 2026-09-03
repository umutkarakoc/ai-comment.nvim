# ai-comment.nvim

Edit your code by writing comments.

[demo.webm](https://github.com/user-attachments/assets/03d72d08-06cb-46fb-be38-b6c7c0836b2d)

```
sum the array with a for loop ai!
```

Press Esc. Done.

## What it does

Two markers, two behaviours:

- A comment ending with `ai!` tells the AI to edit the file.
- A comment ending with `ai?` asks a question, and the answer is inserted right below as a comment.

It uses whatever model you pick on any OpenAI-compatible endpoint. There's no
wrapper around a specific vendor SDK — it just calls the chat completions API
directly with curl.

## Why

Sometimes you're mid-thought in a function and you know exactly what you want the code to become. You don't want to leave the file, open a chat, paste a prompt, copy the result, and paste it back. You just want to write the intent where the code would go, and have it done.

## Usage

Edit mode:

```rust
fn main() {
    let mut total = 0;
    // sum every number in 1..=10 ai!
    println!("{total}");
}
```

Press Esc. The AI rewrites the file:

```rust
fn main() {
    let mut total = 0;
    for i in 1..=10 {
        total += i;
    }
    println!("{total}");
}
```

Question mode:

```rust
// what does this line do? ai?
let n: usize = items.iter().filter(|x| x > 3).count();
```

The answer lands as comments below the question:

```rust
// what does this line do? ai?
// Counts the elements in `items` that are greater than 3.
let n: usize = items.iter().filter(|x| x > 3).count();
```

The question line stays. The `ai!` line does not — it's removed as part of the edit.

## Installation

lazy.nvim:

```lua
{ "umutkarakoc/ai-comment.nvim", config = function() require("ai-comment").setup({}) end }
```

## Requirements

- Neovim 0.11+ (uses `vim.system`)
- `OPENAI_API_KEY` or `OPENROUTER_API_KEY` in your environment

## Configuration

All values listed with their defaults. You rarely need to change any of them.

```lua
require("ai-comment").setup({
  model = "deepseek/deepseek-v4-flash", -- any OpenAI-compatible model id
  url = "https://openrouter.ai/api/v1/chat/completions", -- any OpenAI-compatible endpoint
  api_key = vim.env.OPENAI_API_KEY or vim.env.OPENROUTER_API_KEY,
  max_tokens = 16384, -- output limit
  history_size = 10,  -- conversation turns remembered per buffer
  edit_marker = "ai!", -- comment ending triggers an AI edit
  ask_marker = "ai?",  -- comment ending asks the AI
})
```

The API key is read in this order: `OPENAI_API_KEY`, then
`OPENROUTER_API_KEY`. Override `api_key` directly if you want something else
(for example a local server key or a per-project one).

`AI_COMMENT_MODEL` and `AI_COMMENT_URL` environment variables override the
model and endpoint without touching the config file.

## Behaviour notes

- **History.** Each buffer keeps its own conversation history, so follow-up instructions can reference previous edits. Capped at `history_size` turns.
- **git diff context.** If the file is in a git repo with uncommitted changes, the diff is sent instead of the whole file. Saves tokens on large files.
- **Latency.** When the endpoint is OpenRouter, `provider.sort = "latency"` is sent so it routes to the fastest provider for the model.
- **Truncation guard.** If the model hits `max_tokens`, the response is discarded instead of clobbering your file with a partial copy.
- **Short-response guard.** A response that halves your file is probably a mistake. It's rejected.
- `u` undoes everything.

## Commands

- `:AIComment` — run the marker on the current line.

## Triggers

- Leaving insert mode (Esc) on a marker line.
- `:AIComment`.

## License

MIT
