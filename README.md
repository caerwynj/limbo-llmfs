# llmfs

A Styx file server for Inferno OS that provides an LLM interface over the filesystem. It connects to the [OpenRouter](https://openrouter.ai) API for inference, exposing chat completions, multi-turn conversations, and tool calling through the standard read/write file paradigm.

Written in Limbo. Uses `mhttp.m` for HTTPS and `json.m` for request/response serialization.

## Building

Requires [Inferno OS](https://github.com/9mirrors/infern) (64-bit) with TLS 1.3 support.

```sh
limbo llmfs.b
cp llmfs.dis $INFERNO/dis/
```

## Usage

Inside the Inferno emulator:

```sh
ndb/cs                          # start connection server for DNS
llmfs -k <api-key>              # start the file server
```

This mounts a filesystem at `/n/llm` with the following layout:

```
/n/llm/clone                    open and read to create a new connection
/n/llm/info                     model metadata
/n/llm/N/ctl                    read returns N; write accepts commands
/n/llm/N/data                   one-shot raw prompt interface
/n/llm/N/status                 connection state: Idle, Prompting, Generating, Done
/n/llm/N/system                 system prompt (R/W any time)
/n/llm/N/tools                  tool definitions in markdown (R/W any time)
/n/llm/N/tool_choice            "auto" | "none" | "required" | <fnname>
/n/llm/N/messages/clone         allocate a new turn slot
/n/llm/N/messages/M/role        user|developer|assistant|tool
/n/llm/N/messages/M/content     message text
/n/llm/N/messages/M/name        optional name field
/n/llm/N/messages/M/tool_call_id   id of the assistant tool_call this turn answers
/n/llm/N/messages/M/tool_calls  read-only; JSON array set by the API on assistant turns
/n/llm/N/messages/M/finish_reason  read-only; stop|tool_calls|length|...
```

### One-shot interface (no tools, no history)

```sh
id=`{cat /n/llm/clone}
echo -n 'What is 2+2? Reply with just the number.' > /n/llm/$id/data
cat /n/llm/$id/data
```

### Multi-turn chat

`system` and `tools` are written once (or whenever you want — they're snapshotted on each `ctl send`). Append turns under `messages/`, then `echo send > ctl` to fire the request. The assistant's reply lands as a new turn.

```sh
id=`{cat /n/llm/clone}
echo -n 'You are terse.' > /n/llm/$id/system
m=`{cat /n/llm/$id/messages/clone}
echo -n user                  > /n/llm/$id/messages/$m/role
echo -n 'Capital of France?'  > /n/llm/$id/messages/$m/content
echo send > /n/llm/$id/ctl
cat /n/llm/$id/messages/1/content     # blocks until generation done
```

### Tool calling

Tools are declared in markdown in the `tools` file. One H1 per tool; body is the description; a fenced ```json``` block is the parameter JSON Schema.

```sh
cat > /n/llm/$id/tools <<'EOF'
# get_weather
Get the current weather for a location.

```json
{"type":"object",
 "properties":{"location":{"type":"string","description":"City"}},
 "required":["location"]}
```
EOF
```

After `send`, if the assistant decides to call a tool, the new assistant turn will have `finish_reason=tool_calls` and a JSON array in `tool_calls`:

```
[{"id":"call_abc","type":"function",
  "function":{"name":"get_weather","arguments":"{\"location\":\"Paris\"}"}}]
```

Execute each call locally, then append a `role=tool` turn with the matching `tool_call_id`:

```sh
m=`{cat /n/llm/$id/messages/clone}
echo -n call_abc        > /n/llm/$id/messages/$m/tool_call_id
echo -n '{"temp_c":12}' > /n/llm/$id/messages/$m/content
echo send > /n/llm/$id/ctl
```

Loop until `finish_reason=stop`.

### Context-length management

`messages/` grows without bound. Two ways to keep requests inside the model's `context_length` (visible in `/n/llm/info`):

| Mechanism | Where |
|---|---|
| `ctl trim N` / `ctl trim keep K` | drop oldest non-empty turns |
| `remove` on `messages/M` | drop a single turn (gaps allowed) |
| `ctl transform on` (default) | OpenRouter's `middle-out` transform drops middle messages server-side when over context |

`system` and `tools` are not affected by `trim` or `remove`.

### Ctl commands

Write to `/n/llm/N/ctl`:

| Command | Description |
|---------|-------------|
| `temp 0.7` | Set temperature (0.0-2.0) |
| `top 0.9` | Set top_p (0.0-1.0) |
| `max_tokens 100` | Limit output tokens |
| `seed 42` | Set sampling seed |
| `model openai/gpt-4.1-nano` | Set model for this connection |
| `tool_choice auto` | Set tool_choice (auto, none, required, or fnname) |
| `transform on` / `off` | Toggle OpenRouter middle-out transform |
| `send` | Snapshot current state and start a chat API call |
| `cancel` | Abort an in-flight call |
| `trim N` / `trim keep K` | Drop oldest messages |
| `reset` | Clear messages, system, tools, tool_choice; state -> Idle |

### Options

```
llmfs [-D] [-m mntpt] [-k apikey] [-M model]

-k apikey   OpenRouter API key (or set OPENROUTER_API_KEY env var)
-m mntpt    Mount point (default: /n/llm)
-M model    Default model (default: openai/gpt-4.1-nano)
-D          Enable Styx protocol tracing
```

## Files

| File | Description |
|------|-------------|
| `llmfs.b` | Styx file server implementation |
| `openrouter.b` | Minimal OpenRouter API test program |
| `tlstest.b` | TLS connectivity test |

## Design

The server uses the `styxservers.m` framework with a custom navigator (following the `keyfs.b` pattern from Inferno). API calls run in spawned goroutines with results delivered via channels, so the Styx serve loop never blocks. Reads on `data` or on a not-yet-created assistant turn while a request is in-flight are queued and satisfied when the API responds.

`ctl send` builds a *snapshot* of `system`, `tools`, `tool_choice`, and `messages` before spawning the API goroutine. This lets the caller continue reading or writing those files during a generation without affecting the in-flight call — the next `send` picks up the changes.
