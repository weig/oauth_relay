# oauth-relay

A tiny [Cloudflare Workers](https://developers.cloudflare.com/workers/) service
that relays OAuth 2.0 authorization-code callbacks from a browser to a
command-line tool on the user's machine. It has no vendor-specific logic —
any OAuth provider that lets you register a public HTTPS redirect URI will
work.

## Why this exists

Most OAuth providers require a pre-registered HTTPS redirect URI, and many
won't accept `http://localhost`. A CLI tool therefore has two options:

1. Ship its own HTTPS listener (certificates, ports, firewalls — painful).
2. Register a fixed public URL and have that URL hand the callback back to
   whichever CLI instance is currently waiting for it.

This project is option 2. The worker:

- Accepts the provider's redirect at `GET /<uuid>/<callback>?code=…`
- Stashes the querystring in KV for up to 60 seconds, keyed by `<uuid>`
- Serves a long-poll endpoint at `GET /<uuid>/<callback>/wait` that the CLI
  hits to pick the callback up (delete-on-read)

Both path segments are chosen by the operator when provisioning the redirect
URL. `<uuid>` identifies the callback slot; `<callback>` is the suffix the CLI
expects to see — the worker rejects any request where `<callback>` does not
match `Auth.get(<uuid>)`.

## Architecture

```
 ┌─────────────┐    ①   ┌─────────────┐    ②   ┌─────────────┐
 │  Your CLI   │───────▶│   Browser   │───────▶│   Provider  │
 └─────────────┘ opens  └─────────────┘ login, └─────────────┘
        │               consent                        │
        │  ④ long-poll             ③ redirect to          │
        │   /uuid/callback/wait     /uuid/callback?code=…  │
        ▼                                                  ▼
 ┌──────────────────────────────────────────────────────────────┐
 │                oauth-relay (Cloudflare Worker)               │
 │   KV: OAuthCallback (TTL 60s)   │   KV: Auth (uuid→callback) │
 └──────────────────────────────────────────────────────────────┘
```

Two KV namespaces are used:

| Binding         | Purpose                                                    |
|-----------------|------------------------------------------------------------|
| `OAuthCallback` | Short-lived (60s TTL) store for the captured querystring.  |
| `Auth`          | Long-lived `uuid → callback` mapping. Managed via `bin/auth.sh`.|

## Prerequisites

- [Node.js](https://nodejs.org/) 18 or newer
- A Cloudflare account (free tier is fine)
- `npm install` once, to pull in [wrangler](https://developers.cloudflare.com/workers/wrangler/)

## Install

```sh
git clone <your fork>
cd oauth_relay
npm install
```

## Deploy

```sh
bin/deploy.sh
```

On first run the script will:

1. Prompt you through `wrangler login` if you are not already authenticated.
2. Create two KV namespaces (`OAuthCallback`, `Auth`) in your account.
3. Write their IDs into a local `.env` file (gitignored, `chmod 600`).
4. Render `wrangler.toml` from `wrangler.toml.template`.
5. Run `wrangler deploy`.

On subsequent runs the script loads the IDs from `.env`, verifies the
namespaces still exist in your account, regenerates `wrangler.toml`, and
redeploys. If the IDs in `.env` are stale it will stop and ask you to fix or
delete the file.

### Configuration files

| File                     | Source of truth? | Committed? |
|--------------------------|------------------|------------|
| `.env`                   | yes — IDs        | no         |
| `.env.example`           | documentation    | yes        |
| `wrangler.toml.template` | yes — config     | yes        |
| `wrangler.toml`          | generated        | no         |

If you prefer to manage KV namespaces yourself, create them in the Cloudflare
dashboard, put the IDs into `.env` manually, and run `bin/deploy.sh`.

## Managing auth entries

Anyone who knows a `uuid` + `callback` pair can use the relay, so you need to
issue and revoke them yourself. Each pair is a row in the `Auth` KV namespace.

```sh
bin/auth.sh list                   # list all uuid → callback pairs
bin/auth.sh get    <uuid>          # look up the callback suffix for a uuid
bin/auth.sh set    <callback>      # create; a new uuid is generated for you
bin/auth.sh delete <uuid>          # revoke
```

`set` only takes the callback suffix — the uuid is generated via `uuidgen` and
printed on success, along with the full path to register as the provider's
redirect URI:

```
$ bin/auth.sh set my_callback

Created auth entry:
  uuid:     019db2ef-eacb-7d56-82b1-32dbcd438699
  callback: my_callback
  path:     /019db2ef-eacb-7d56-82b1-32dbcd438699/my_callback
```

Both `<uuid>` and `<callback>` must match `^[A-Za-z0-9_-]{8,128}$` — the same
pattern the worker validates against before touching KV.

## Integrating an OAuth client

Once an operator has run `bin/auth.sh set <callback>` and handed you a
`<uuid>` + `<callback>` pair, you have everything you need. The relay exposes
two GET endpoints:

| Endpoint                          | Who calls it       | Behavior                                                                 |
|-----------------------------------|--------------------|--------------------------------------------------------------------------|
| `/<uuid>/<callback>`              | the OAuth provider | Stores the raw querystring in KV under `<uuid>` (TTL 60s) and renders an HTML "you can close this tab" page. |
| `/<uuid>/<callback>/wait`         | your CLI           | Long-polls for up to 30s. Returns the stored querystring as `text/plain` (and deletes it), or `408 timeout` if none arrived. |

### Flow

1. Generate a random `state` value (for CSRF defense).
2. Open the provider's authorize URL in the user's browser, using
   `https://<your-worker>.workers.dev/<uuid>/<callback>` as `redirect_uri`.
3. In parallel, start polling `…/<uuid>/<callback>/wait`. Retry on `408`
   until the user completes consent (or your own overall deadline expires).
4. When `/wait` returns `200`, its body is the raw querystring the provider
   redirected with (`code=…&state=…` etc.). Parse it, check `state`, then
   exchange the `code` for a token against the provider's token endpoint as
   usual.

### Minimal Python example

```python
import secrets
import time
import urllib.parse
import urllib.request
import webbrowser
from urllib.error import HTTPError

RELAY     = "https://oauth-relay.example.workers.dev"
UUID      = "019db2ef-eacb-7d56-82b1-32dbcd438699"
CALLBACK  = "my_callback"
CLIENT_ID = "YOUR_CLIENT_ID"
AUTHORIZE = "https://provider.example.com/oauth/authorize"


def fetch_auth_code(scope: str, overall_timeout_s: float = 300.0) -> tuple[str, str]:
    state = secrets.token_urlsafe(16)
    redirect_uri = f"{RELAY}/{UUID}/{CALLBACK}"

    authorize_url = AUTHORIZE + "?" + urllib.parse.urlencode({
        "client_id":     CLIENT_ID,
        "response_type": "code",
        "redirect_uri":  redirect_uri,
        "scope":         scope,
        "state":         state,
    })
    webbrowser.open(authorize_url)

    wait_url = f"{RELAY}/{UUID}/{CALLBACK}/wait"
    deadline = time.monotonic() + overall_timeout_s

    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(wait_url, timeout=35) as resp:
                body = resp.read().decode("utf-8")
        except HTTPError as exc:
            if exc.code == 408:        # long-poll idle; try again
                continue
            raise

        params = urllib.parse.parse_qs(body, strict_parsing=True)
        if params.get("state", [""])[0] != state:
            raise RuntimeError("state mismatch — aborting")
        return params["code"][0], state

    raise TimeoutError("user did not complete consent in time")
```

### Shell sanity check

To verify end-to-end wiring without writing any code, run this in one
terminal:

```sh
curl -sS "https://<your-worker>.workers.dev/<uuid>/<callback>/wait"
```

Then, in your browser, hit
`https://<your-worker>.workers.dev/<uuid>/<callback>?code=test&state=abc`.
The `curl` call will return the body `code=test&state=abc`.

### Operational notes

- `/wait` is single-shot: the stored querystring is deleted the moment it's
  returned, so only the CLI that asked for it gets it.
- KV entries expire after 60 seconds. If the user is slow to consent, your
  CLI must still be polling when the redirect lands.
- One `<uuid>` slot serves one in-flight flow at a time — if two CLIs race
  against the same `<uuid>`, only the first `/wait` caller wins. Provision
  separate `<uuid>` + `<callback>` pairs per CLI / per user.

## Local development

```sh
bin/deploy.sh        # once, to ensure wrangler.toml exists
npm run dev       # wrangler dev, against the real (remote) KV
```

## Security notes

- `.env` is `chmod 600` on creation and listed in `.gitignore`.
- The worker performs a cheap regex check on both URL path segments before any
  KV read, so random scanners can't rack up KV operations.
- The `uuid` + `callback` pair is effectively a bearer credential in the URL:
  treat it like a shared secret even though the second segment is only a
  suffix. Rotate via `bin/auth.sh set` (overwrite) or `delete` + re-`set`.
- Captured OAuth callbacks live in KV for 60 seconds and are deleted the
  moment `/wait` returns them.

## License

MIT
