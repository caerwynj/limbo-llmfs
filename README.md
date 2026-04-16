# llmfs

A Styx file server for Inferno OS that provides an LLM interface over the filesystem. It connects to the [OpenRouter](https://openrouter.ai) API for inference, exposing chat completions through the standard read/write file paradigm.

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
/n/llm/N/data                   raw prompt interface
/n/llm/N/status                 connection state: Idle, Prompting, Generating, Done
/n/llm/N/chat/system            system prompt
/n/llm/N/chat/user              user message (close triggers generation)
/n/llm/N/chat/assistant         generated response (read-only)
```

### Chat interface

```sh
id=`{cat /n/llm/clone}
echo -n 'You are a helpful assistant.' > /n/llm/$id/chat/system
echo -n 'What is the capital of France?' > /n/llm/$id/chat/user
cat /n/llm/$id/chat/assistant
```

Closing the `user` file triggers the API call. Reading `assistant` blocks until the response is ready.

### Raw data interface

```sh
id=`{cat /n/llm/clone}
echo -n 'What is 2+2? Reply with just the number.' > /n/llm/$id/data
cat /n/llm/$id/data
```

### Ctl commands

Write to `/n/llm/N/ctl`:

| Command | Description |
|---------|-------------|
| `temp 0.7` | Set temperature (0.0-2.0) |
| `top 0.9` | Set top_p (0.0-1.0) |
| `max_tokens 100` | Limit output tokens |
| `seed 42` | Set sampling seed |
| `model openai/gpt-4.1-nano` | Set model for this connection |
| `reset` | Clear state for reuse |

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

The server uses the `styxservers.m` framework with a custom navigator (following the `keyfs.b` pattern from Inferno). API calls run in spawned goroutines with results delivered via channels, so the Styx serve loop never blocks. Reads on `assistant` or `data` while a request is in-flight are queued and satisfied when the API responds.
