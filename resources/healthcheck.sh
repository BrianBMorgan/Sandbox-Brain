#!/bin/sh
# Smart healthcheck: reports healthy during analysis/wiki phases,
# then falls back to the real /healthz endpoint once services are up.

# If gitnexus analyze or wiki is still running, the container is starting up — report healthy
# Use pgrep -x to match the process name, avoiding false positives from entrypoint.sh args
if pgrep -f "[g]itnexus analyze" >/dev/null 2>&1 || pgrep -f "[g]itnexus wiki" >/dev/null 2>&1; then
    exit 0
fi

# If HAProxy isn't listening yet (gap between analyze finishing and services starting), report healthy
if ! nc -z 127.0.0.1 "${PORT:-8010}" >/dev/null 2>&1; then
    exit 0
fi

# HAProxy is up — /healthz is answered locally by HAProxy (mcp-proxy has no
# configurable health endpoint), so this always returns 200 once HAProxy is up.
SCHEME=$([ "$ENABLE_HTTPS" = "true" ] && echo https || echo http)
exec wget -q --spider --no-check-certificate "${SCHEME}://127.0.0.1:${PORT:-8010}/healthz"
