export interface Env {
    OAuthCallback: KVNamespace;
    Auth: KVNamespace;
}

const TOKEN_PATTERN = /^[a-zA-Z0-9_-]{8,128}$/;
const KV_TTL_SECONDS = 60;
const LONG_POLL_MAX_MS = 30_000;
const LONG_POLL_INTERVAL_MS = 1_000;

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        if (request.method !== 'GET') return text('method not allowed', 405);

        const url = new URL(request.url);
        const parts = url.pathname.split('/').filter(p => p.length > 0);

        // Route map:
        //   GET /<uuid>/<string>          → OAuth provider redirects here
        //   GET /<uuid>/<string>/wait     → long-poll for the stored callback
        if (parts.length < 2 || parts.length > 3) return text('not found', 404);

        const [uuid, secret, tail] = parts;

        // Cheap shape check before touching KV — keeps scanners from running up reads.
        if (!TOKEN_PATTERN.test(uuid) || !TOKEN_PATTERN.test(secret)) {
            return text('forbidden', 403);
        }

        // Auth: <secret> must equal Auth.get(<uuid>)
        const expected = await env.Auth.get(uuid);
        if (expected === null || expected !== secret) {
            return text('forbidden', 403);
        }

        if (parts.length === 2) {
            return handleCallback(uuid, url, env);
        }
        if (parts.length === 3 && tail === 'wait') {
            return handleWait(uuid, env);
        }
        return text('not found', 404);
    },
};

async function handleCallback(uuid: string, url: URL, env: Env): Promise<Response> {
    // Store the entire querystring verbatim, keyed by uuid.
    const qs = url.search.startsWith('?') ? url.search.slice(1) : url.search;
    if (!qs) {
        return html(`<h1>Bad callback</h1><p>No querystring received.</p>`, 400);
    }

    await env.OAuthCallback.put(`oauth:${uuid}`, qs, {
        expirationTtl: KV_TTL_SECONDS,
    });

    return html(
        `<h1>Callback received</h1>` +
        `<p>The CLI has captured the response. You can return to your terminal.</p>` +
        `<script>setTimeout(()=>window.close(),1500);</script>`
    );
}

async function handleWait(uuid: string, env: Env): Promise<Response> {
    const deadline = Date.now() + LONG_POLL_MAX_MS;
    while (Date.now() < deadline) {
        const qs = await env.OAuthCallback.get(`oauth:${uuid}`);
        if (qs !== null) {
            await env.OAuthCallback.delete(`oauth:${uuid}`);
            return text(qs);
        }
        await sleep(LONG_POLL_INTERVAL_MS);
    }
    return text('timeout', 408);
}

function sleep(ms: number): Promise<void> {
    return new Promise(r => setTimeout(r, ms));
}

function html(body: string, status = 200): Response {
    return new Response(
        `<!doctype html><html><head><meta charset="utf-8"><title>OAuth relay</title>` +
        `<style>body{font-family:-apple-system,system-ui,sans-serif;max-width:520px;margin:80px auto;padding:0 24px;color:#222}` +
        `h1{color:#0a7;margin:0 0 12px}p{color:#555;line-height:1.55}` +
        `code{background:#f4f4f4;padding:2px 6px;border-radius:3px;font-size:0.95em}</style>` +
        `</head><body>${body}</body></html>`,
        {
            status,
            headers: {
                'content-type': 'text/html; charset=utf-8',
                'cache-control': 'no-store',
            },
        }
    );
}

function text(body: string, status = 200): Response {
    return new Response(body, {
        status,
        headers: {
            'content-type': 'text/plain; charset=utf-8',
            'cache-control': 'no-store',
        },
    });
}
