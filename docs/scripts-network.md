# Scripts and the network

`run_script` can reach the network, but never through sockets. Both interpreters call the
host, the host calls `NetworkClient`, and `NetworkClient` is the same code `http_request`
uses. There is no second policy implementation to drift.

```
script:  http.get(url)  /  urlopen(url)
            ↓  host bridge (the same dispatcher that serves fs.read)
Swift:   ScriptNetworkBridge → NetworkClient → NetworkPolicy → URLSession
```

## Why not real sockets

Python's `socket`, `ssl`, `http` and `urllib.request` are not in the bundle, and that is
deliberate: `scripts/fetch-python.sh` removes them. A socket inside the app process would
be invisible to the trace, would bypass `NetworkPolicy`, and could not be rate-limited per
request. QuickJS has no `fetch` of its own either — any `fetch` is ours.

`urllib.parse` is kept. It is pure Python and never needed a socket.

## What a script can write

**Python**

```python
import json
from urllib.request import urlopen

with urlopen("https://api.example.com/data", timeout=10) as response:
    data = json.load(response)
```

`urlopen(url, data=None, timeout=…, headers={}, method=None)` accepts a string or a
`urllib.request.Request`, and returns an object with `read()`, `readline()`, `status`,
`code`, `headers` (case-insensitive), `geturl()`, `close()`, `raise_for_status()` and a
context manager.

Two deliberate differences from the stdlib:

- **`urlopen` does not raise for 4xx/5xx.** It returns the response so the caller can read
  the error body; `raise_for_status()` is the opt-in for urllib's behaviour.
- **`os.environ` is nearly empty** — `TMPDIR`, `HOME`, `LANG` and friends, nothing else. The
  app's own environment is not a script's to read, and a model told otherwise writes code
  that cannot work.

**JavaScript**

```javascript
const res = await fetch("https://api.example.com/data", { headers: { Accept: "application/json" } });
const data = await res.json();
```

`fetch` is a promise; `http.get` / `http.post` are the synchronous form. `Response` exposes
`status`, `ok`, `url`, `headers.get()`, `text()` and `json()` — the last two return values,
not promises, so `await res.json()` and `res.json()` both work.

Top-level `await` only parses as a module, so a source containing `await` is compiled as
one; anything else is compiled as a script. If that fails, the other shape is tried once.

## What is enforced

| | |
|---|---|
| Transport | HTTPS only — iOS ATS, not a rule of ours |
| Hosts | the optional allowlist applies; addresses themselves are not classified |
| Redirects | followed by the client, and every hop is re-validated |
| Body size | `maxRequestBodyBytes` for the request, `maxBodyBytes` for the response |
| Response headers | a fixed allowlist — no `Set-Cookie`, no auth echoes |
| Cookies | none; the session is ephemeral with no storage |
| Clock | the run's deadline; a hung request is abandoned with the run |

### Why addresses are not classified

The policy used to refuse private, loopback and benchmarking ranges, on the theory that a
model-generated request should never reach the user's own network. On a phone that theory
fails twice over: fake-IP proxies (Clash, Surge) resolve *every* domain into
198.18.0.0/15, and a developer's own services live on 127.0.0.1 or a LAN address. Blocking
either broke ordinary use, and the first version of this shipped with a test that asserted
the block — which is how a wrong assumption survives.

## What is not

- **No approval prompt.** A script's request does not ask, unlike `http_request`'s writes.
  This matches `bash` + `curl` in a terminal agent: the control is that you can read the
  script, not that each request interrupts you.
- **No request log.** The trace shows the script's stdout, not the URLs it touched. If that
  becomes a problem, the bridge is the place to add it — one call site, both runtimes.
- **No `requests`, no streaming, no `AbortController`, no cookie jar.** `requests` needs
  sockets and is out of reach by construction.
- **No environment variables to read secrets from.** A token has to be passed in the
  script, or fetched by the agent with `http_request` and written into a file.

## Where the seam is

`ScriptNetworkAccess` is optional on `ScriptRequest`. When it is nil — a test, or a build
without the runtime configured — the prelude is still installed, and calling `http.get` or
`urlopen` raises `network access is not available in this run` instead of failing obscurely.
