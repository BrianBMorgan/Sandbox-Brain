#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_PUID=1000
readonly DEFAULT_PGID=1000
readonly DEFAULT_PORT=8010
readonly DEFAULT_INTERNAL_PORT=38011
readonly DEFAULT_WEB_UI_PORT=4747
readonly WEB_UI_STATIC_PORT=39012
readonly WEB_UI_STATIC_DIR="/usr/local/share/gitnexus-web"
readonly DEFAULT_PROTOCOL="SHTTP"
readonly DEFAULT_TLS_MIN_VERSION="TLSv1.3"
readonly DEFAULT_HTTP_VERSION_MODE="auto"
readonly DEFAULT_DATA_DIR="/data"
readonly SAFE_API_KEY_REGEX='^[[:graph:]]+$'
readonly MIN_API_KEY_LEN=5
readonly MAX_API_KEY_LEN=256
readonly FIRST_RUN_FILE="/state/first_run_complete"
readonly HAPROXY_SERVER_NAME="gitnexus"
readonly HAPROXY_TEMPLATE="/etc/haproxy/haproxy.cfg.template"
readonly HAPROXY_CONFIG="/tmp/haproxy.cfg"
readonly STATE_DIR="/state"
readonly CLEAN_DONE_FILE="${STATE_DIR}/.clean_done"
readonly CLEAN_ALL_DONE_FILE="${STATE_DIR}/.clean_all_done"
readonly ANALYZE_FORCE_DONE_FILE="${STATE_DIR}/.analyze_force_done"
readonly WIKI_FORCE_DONE_FILE="${STATE_DIR}/.wiki_force_done"

trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

is_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

is_true() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

validate_port() {
    local name="$1"
    local value="$2"
    local fallback="$3"

    if ! is_positive_int "$value" || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        echo "Invalid ${name}='${value}', using default ${fallback}" >&2
        printf '%s' "$fallback"
        return
    fi

    printf '%s' "$value"
}

validate_tls_min_version() {
    local value="$1"
    local fallback="$2"

    case "$value" in
        TLSv1.2|TLSv1.3)
            printf '%s' "$value"
            ;;
        *)
            echo "Invalid TLS_MIN_VERSION='${value}', using default ${fallback}" >&2
            printf '%s' "$fallback"
            ;;
    esac
}

normalize_http_version_mode() {
    local raw="$1"
    local mode

    mode="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    mode="$(trim "$mode")"

    case "$mode" in
        auto|all|h1|h2|h3|h1+h2)
            printf '%s' "$mode"
            ;;
        http/1.1|http1|http1.1)
            printf 'h1'
            ;;
        http/2|http2)
            printf 'h2'
            ;;
        http/3|http3)
            printf 'h3'
            ;;
        *)
            echo "Invalid HTTP_VERSION_MODE='${raw}', using default ${DEFAULT_HTTP_VERSION_MODE}" >&2
            printf '%s' "$DEFAULT_HTTP_VERSION_MODE"
            ;;
    esac
}

validate_api_key() {
    API_KEY="${API_KEY:-}"
    API_KEY="$(trim "$API_KEY")"
    local api_key_len=0

    if [[ -z "$API_KEY" ]]; then
        export API_KEY=""
        return
    fi

    api_key_len="${#API_KEY}"
    if (( api_key_len < MIN_API_KEY_LEN || api_key_len > MAX_API_KEY_LEN )); then
        echo "Invalid API_KEY length (${api_key_len}). Expected ${MIN_API_KEY_LEN}-${MAX_API_KEY_LEN} characters." >&2
        exit 1
    fi

    if [[ ! "$API_KEY" =~ $SAFE_API_KEY_REGEX ]]; then
        echo "Invalid API_KEY format. Refusing to start with malformed API key (whitespace/control chars are not allowed)." >&2
        exit 1
    fi

    export API_KEY
}

validate_web_auth() {
    WEB_USERNAME="${WEB_USERNAME:-}"
    WEB_PASSWORD="${WEB_PASSWORD:-}"
    WEB_USERNAME="$(trim "$WEB_USERNAME")"
    WEB_PASSWORD="$(trim "$WEB_PASSWORD")"

    if [[ -z "$WEB_USERNAME" && -z "$WEB_PASSWORD" ]]; then
        if [[ -n "${API_KEY:-}" ]]; then
            echo "WARNING: API_KEY is set but WEB_USERNAME is not — Web UI and /api/* are unauthenticated." >&2
            echo "  Set WEB_USERNAME and WEB_PASSWORD to protect browser access." >&2
        fi
        export WEB_USERNAME="" WEB_PASSWORD=""
        return
    fi

    if [[ -z "$WEB_USERNAME" || -z "$WEB_PASSWORD" ]]; then
        echo "Both WEB_USERNAME and WEB_PASSWORD must be set (or both unset)." >&2
        exit 1
    fi

    if (( ${#WEB_PASSWORD} < 8 )); then
        echo "WEB_PASSWORD must be at least 8 characters." >&2
        exit 1
    fi

    export WEB_USERNAME WEB_PASSWORD
}

validate_rate_limit() {
    RATE_LIMIT="${RATE_LIMIT:-0}"
    RATE_LIMIT="$(trim "$RATE_LIMIT")"
    RATE_LIMIT_PERIOD="${RATE_LIMIT_PERIOD:-10s}"
    RATE_LIMIT_PERIOD="$(trim "$RATE_LIMIT_PERIOD")"
    MAX_CONNECTIONS_PER_IP="${MAX_CONNECTIONS_PER_IP:-0}"
    MAX_CONNECTIONS_PER_IP="$(trim "$MAX_CONNECTIONS_PER_IP")"

    if [[ "$RATE_LIMIT" != "0" ]]; then
        if ! [[ "$RATE_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
            echo "Invalid RATE_LIMIT='${RATE_LIMIT}'. Must be a positive integer or 0 to disable." >&2
            exit 1
        fi
        if ! [[ "$RATE_LIMIT_PERIOD" =~ ^[1-9][0-9]*(s|m|h|d)$ ]]; then
            echo "Invalid RATE_LIMIT_PERIOD='${RATE_LIMIT_PERIOD}'. Must be a duration like 10s, 1m, 1h." >&2
            exit 1
        fi
    fi

    if [[ "$MAX_CONNECTIONS_PER_IP" != "0" ]]; then
        if ! [[ "$MAX_CONNECTIONS_PER_IP" =~ ^[1-9][0-9]*$ ]]; then
            echo "Invalid MAX_CONNECTIONS_PER_IP='${MAX_CONNECTIONS_PER_IP}'. Must be a positive integer or 0 to disable." >&2
            exit 1
        fi
    fi

    export RATE_LIMIT RATE_LIMIT_PERIOD MAX_CONNECTIONS_PER_IP
}

validate_ip_access() {
    IP_ALLOWLIST="${IP_ALLOWLIST:-}"
    IP_BLOCKLIST="${IP_BLOCKLIST:-}"
    IP_ALLOWLIST="$(trim "$IP_ALLOWLIST")"
    IP_BLOCKLIST="$(trim "$IP_BLOCKLIST")"

    local ip_cidr_regex='^[0-9a-fA-F.:]+(/[0-9]+)?$'

    if [[ -n "$IP_BLOCKLIST" ]]; then
        : > /tmp/haproxy_blocklist.txt
        IFS=',' read -ra BLOCK_IPS <<< "$IP_BLOCKLIST"
        for ip in "${BLOCK_IPS[@]}"; do
            ip="$(trim "$ip")"
            [[ -z "$ip" ]] && continue
            if [[ "$ip" =~ $ip_cidr_regex ]]; then
                echo "$ip" >> /tmp/haproxy_blocklist.txt
            else
                echo "Warning: Invalid IP_BLOCKLIST entry '${ip}' — skipping" >&2
            fi
        done
        echo "IP blocklist loaded: $(wc -l < /tmp/haproxy_blocklist.txt) entries"
    fi

    if [[ -n "$IP_ALLOWLIST" ]]; then
        : > /tmp/haproxy_allowlist.txt
        IFS=',' read -ra ALLOW_IPS <<< "$IP_ALLOWLIST"
        for ip in "${ALLOW_IPS[@]}"; do
            ip="$(trim "$ip")"
            [[ -z "$ip" ]] && continue
            if [[ "$ip" =~ $ip_cidr_regex ]]; then
                echo "$ip" >> /tmp/haproxy_allowlist.txt
            else
                echo "Warning: Invalid IP_ALLOWLIST entry '${ip}' — skipping" >&2
            fi
        done
        echo "IP allowlist loaded: $(wc -l < /tmp/haproxy_allowlist.txt) entries"
    fi

    export IP_ALLOWLIST IP_BLOCKLIST
}

validate_cors() {
    ALLOW_ALL_CORS=false
    HAPROXY_CORS_ENABLED=false
    HAPROXY_CORS_ORIGINS=()

    local cors_value
    if [[ -z "${CORS:-}" ]]; then
        return
    fi

    HAPROXY_CORS_ENABLED=true
    IFS=',' read -ra CORS_VALUES <<< "$CORS"
    for cors_value in "${CORS_VALUES[@]}"; do
        cors_value="$(trim "$cors_value")"
        [[ -z "$cors_value" ]] && continue

        if [[ "$cors_value" =~ ^(all|\*)$ ]]; then
            ALLOW_ALL_CORS=true
            HAPROXY_CORS_ORIGINS=("*")
            break
        elif [[ "$cors_value" =~ ^https?:// ]]; then
            HAPROXY_CORS_ORIGINS+=("$cors_value")
        elif [[ "$cors_value" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(:[0-9]+)?$ ]]; then
            HAPROXY_CORS_ORIGINS+=("http://$cors_value" "https://$cors_value")
        elif [[ "$cors_value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]]; then
            HAPROXY_CORS_ORIGINS+=("http://$cors_value" "https://$cors_value")
        else
            echo "Warning: Invalid CORS pattern '$cors_value' - skipping"
        fi
    done
}

handle_first_run() {
    local uid_gid_changed=0

    if [[ -z "${PUID:-}" && -z "${PGID:-}" ]]; then
        PUID="$DEFAULT_PUID"
        PGID="$DEFAULT_PGID"
    elif [[ -n "${PUID:-}" && -z "${PGID:-}" ]]; then
        if is_positive_int "$PUID"; then
            PGID="$PUID"
        else
            PUID="$DEFAULT_PUID"
            PGID="$DEFAULT_PGID"
        fi
    elif [[ -z "${PUID:-}" && -n "${PGID:-}" ]]; then
        if is_positive_int "$PGID"; then
            PUID="$PGID"
        else
            PUID="$DEFAULT_PUID"
            PGID="$DEFAULT_PGID"
        fi
    else
        if ! is_positive_int "$PUID"; then
            PUID="$DEFAULT_PUID"
        fi
        if ! is_positive_int "$PGID"; then
            PGID="$DEFAULT_PGID"
        fi
    fi

    if [ "$(id -u node)" -ne "$PUID" ]; then
        if usermod -o -u "$PUID" node 2>/dev/null; then
            uid_gid_changed=1
        else
            PUID="$(id -u node)"
        fi
    fi

    if [ "$(id -g node)" -ne "$PGID" ]; then
        if groupmod -o -g "$PGID" node 2>/dev/null; then
            uid_gid_changed=1
        else
            PGID="$(id -g node)"
        fi
    fi

    if [ "$uid_gid_changed" -eq 1 ]; then
        echo "Updated UID/GID to PUID=${PUID}, PGID=${PGID}"
    fi

    touch "$FIRST_RUN_FILE"
}

haproxy_supports_quic() {
    # Build flag check (fast pre-filter)
    # Note: avoid pipe + grep -q with pipefail (SIGPIPE can cause false negatives)
    local vv_output
    vv_output="$(haproxy -vv 2>/dev/null)" || true
    if ! echo "$vv_output" | grep -Eiq 'USE_QUIC=1|[[:space:]]quic[[:space:]]: mode=HTTP'; then
        return 1
    fi

    # Runtime probe: verify QUIC bind actually works with the current SSL library
    local probe_dir probe_cfg probe_pem output
    probe_dir="$(mktemp -d)" || return 1
    probe_cfg="${probe_dir}/probe.cfg"
    probe_pem="${probe_dir}/probe.pem"

    if ! openssl req -x509 -newkey rsa:2048 -keyout "${probe_dir}/probe.key" -out "${probe_dir}/probe.crt" \
         -days 1 -nodes -subj "/CN=quic-probe" -batch 2>/dev/null; then
        rm -rf "$probe_dir"
        return 1
    fi
    cat "${probe_dir}/probe.crt" "${probe_dir}/probe.key" > "$probe_pem"

    printf 'global\n  log stderr format raw local0\ndefaults\n  mode http\n  timeout connect 5s\n  timeout client 5s\n  timeout server 5s\nfrontend quic_probe\n  bind quic4@*:65535 ssl crt %s alpn h3\n  default_backend quic_probe_be\nbackend quic_probe_be\n  server s1 127.0.0.1:1\n' \
        "$probe_pem" > "$probe_cfg"

    output="$(haproxy -c -f "$probe_cfg" 2>&1)" || true
    rm -rf "$probe_dir"

    if echo "$output" | grep -qi 'does not support the QUIC protocol'; then
        return 1
    fi
    return 0
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR"
}

ensure_parent_dir() {
    local target="$1"
    mkdir -p "$(dirname "$target")"
}

prepare_tls_pem() {
    local cert_path="$1"
    local key_path="$2"
    local pem_path="$3"

    if [[ -f "$pem_path" ]]; then
        return
    fi

    ensure_parent_dir "$pem_path"

    if [[ -f "$cert_path" && -f "$key_path" ]]; then
        cat "$cert_path" "$key_path" > "$pem_path"
        chmod 600 "$pem_path"
        return
    fi

    echo "ERROR: ENABLE_HTTPS=true but certificate files are missing." >&2
    echo "Please provide TLS_CERT_PATH and TLS_KEY_PATH, or a combined TLS_PEM_PATH." >&2
    echo "Auto certificate generation is not supported in this image." >&2
    echo "See CERTIFICATE_SETUP_GUIDE.md for instructions." >&2
    exit 1
}

resolve_listener_protocols() {
    local mode="$1"

    if ! is_true "$ENABLE_HTTPS"; then
        if [[ "$mode" != "h1" && "$mode" != "auto" ]]; then
            echo "HTTP_VERSION_MODE='${mode}' requested without TLS; falling back to HTTP/1.1" >&2
        fi

        BIND_PARAMS=""
        QUIC_BIND_LINE="# HTTP/3 disabled"
        EFFECTIVE_HTTP_VERSIONS="h1"
        return
    fi

    local alpn="http/1.1"
    local want_h3="false"

    case "$mode" in
        h1)
            alpn="http/1.1"
            ;;
        h2)
            alpn="h2"
            ;;
        h1+h2)
            alpn="h2,http/1.1"
            ;;
        h3)
            alpn="h2,http/1.1"
            want_h3="true"
            ;;
        auto|all)
            alpn="h2,http/1.1"
            want_h3="true"
            ;;
    esac

    BIND_PARAMS="ssl crt ${TLS_PEM_PATH} ssl-min-ver ${TLS_MIN_VERSION} alpn ${alpn}"
    EFFECTIVE_HTTP_VERSIONS="${alpn}"
    QUIC_BIND_LINE="# HTTP/3 disabled"

    if [[ "$want_h3" == "true" ]]; then
        if haproxy_supports_quic; then
            QUIC_BIND_LINE="bind quic4@*:${PORT} ssl crt ${TLS_PEM_PATH} ssl-min-ver ${TLS_MIN_VERSION} alpn h3"
            EFFECTIVE_HTTP_VERSIONS="${EFFECTIVE_HTTP_VERSIONS},h3"
        else
            echo "HTTP_VERSION_MODE='${mode}' requested h3, but QUIC is not available in this HAProxy build; continuing with ${alpn}" >&2
        fi
    fi
}

escape_sed_replacement() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
    value="${value//|/\\|}"
    printf '%s' "$value"
}

escape_haproxy_regex() {
    local value="$1"
    local escaped=""
    local i ch

    for ((i = 0; i < ${#value}; i++)); do
        ch="${value:i:1}"
        if [[ "$ch" =~ [\\.^$\|?*+(){}\[\]] ]]; then
            escaped+="\\$ch"
        else
            escaped+="$ch"
        fi
    done

    printf '%s' "$escaped"
}

generate_haproxy_config() {
    if [[ ! -f "$HAPROXY_TEMPLATE" ]]; then
        echo "Error: HAProxy template missing at ${HAPROXY_TEMPLATE}" >&2
        exit 1
    fi

    # Web UI Basic auth (username/password)
    local web_auth_userlist
    local web_auth_check
    if [[ -n "$WEB_USERNAME" && -n "$WEB_PASSWORD" ]]; then
        local hashed_password
        hashed_password="$(openssl passwd -5 "$WEB_PASSWORD")"
        web_auth_userlist="userlist web_users
    user ${WEB_USERNAME} password ${hashed_password}"
        web_auth_check="    # Web UI Basic auth - protect web UI, API, and all non-MCP routes
    # MCP clients use Bearer token (API_KEY) instead, so skip Basic auth for /mcp
    # Localhost health checks are always exempt
    acl is_basic_auth var(txn.auth_header) -m beg -i Basic
    http-request auth realm GitNexus if !is_mcp_path !is_health_check !is_basic_auth !{ http_auth(web_users) }
    http-request deny deny_status 401 content-type \"application/json\" string '{\"error\":\"Unauthorized\",\"message\":\"Invalid credentials\"}' if !is_mcp_path !is_health_check is_basic_auth !{ http_auth(web_users) }"
        echo "Web UI authentication enabled for user: ${WEB_USERNAME}"
    else
        web_auth_userlist="# Web UI authentication disabled"
        web_auth_check="    # Web UI authentication disabled - no login required"
    fi

    # Rate limiting and connection limiting
    local rate_limit_table
    local rate_limit_check
    if [[ "$RATE_LIMIT" != "0" || "$MAX_CONNECTIONS_PER_IP" != "0" ]]; then
        local store_counters=""
        [[ "$RATE_LIMIT" != "0" ]] && store_counters="http_req_rate(${RATE_LIMIT_PERIOD})"
        [[ "$MAX_CONNECTIONS_PER_IP" != "0" ]] && {
            [[ -n "$store_counters" ]] && store_counters+=","
            store_counters+="conn_cur"
        }

        rate_limit_table="backend rate_limit_table
    stick-table type ipv6 size 100k expire 30s store ${store_counters}"

        rate_limit_check="    # Track client IP for rate/connection limiting
    http-request track-sc0 src table rate_limit_table"

        if [[ "$RATE_LIMIT" != "0" ]]; then
            rate_limit_check+="
    http-request return status 429 content-type \"application/json\" string '{\"error\":\"Too Many Requests\",\"message\":\"Rate limit exceeded\"}' hdr \"Retry-After\" \"${RATE_LIMIT_PERIOD%%[smhd]*}\" if !is_health_check { sc_http_req_rate(0,rate_limit_table) gt ${RATE_LIMIT} }"
            echo "Rate limiting enabled: ${RATE_LIMIT} requests per ${RATE_LIMIT_PERIOD}"
        fi

        if [[ "$MAX_CONNECTIONS_PER_IP" != "0" ]]; then
            rate_limit_check+="
    http-request deny deny_status 429 content-type \"application/json\" string '{\"error\":\"Too Many Connections\",\"message\":\"Connection limit exceeded\"}' if !is_health_check { sc_conn_cur(0,rate_limit_table) gt ${MAX_CONNECTIONS_PER_IP} }"
            echo "Connection limiting enabled: ${MAX_CONNECTIONS_PER_IP} concurrent connections per IP"
        fi
    else
        rate_limit_table="# Rate limiting disabled"
        rate_limit_check="    # Rate limiting disabled"
    fi

    # IP access control
    local ip_access_check
    if [[ -n "$IP_BLOCKLIST" && -s /tmp/haproxy_blocklist.txt ]]; then
        ip_access_check="    # IP blocklist
    acl is_blocked_ip src -f /tmp/haproxy_blocklist.txt
    http-request deny deny_status 403 content-type \"application/json\" string '{\"error\":\"Forbidden\",\"message\":\"IP address blocked\"}' if is_blocked_ip !is_health_check"
    else
        ip_access_check=""
    fi

    if [[ -n "$IP_ALLOWLIST" && -s /tmp/haproxy_allowlist.txt ]]; then
        [[ -n "$ip_access_check" ]] && ip_access_check+="
"
        ip_access_check+="    # IP allowlist (only listed IPs may connect)
    acl is_allowed_ip src -f /tmp/haproxy_allowlist.txt
    acl is_allowed_ip src 127.0.0.1 ::1
    http-request deny deny_status 403 content-type \"application/json\" string '{\"error\":\"Forbidden\",\"message\":\"IP address not allowed\"}' if !is_allowed_ip"
    fi

    if [[ -z "$ip_access_check" ]]; then
        ip_access_check="    # IP access control disabled"
    fi

    local api_key_check
    if [[ -n "$API_KEY" ]]; then
        local escaped_key_sed
        escaped_key_sed="$(escape_sed_replacement "$API_KEY")"
        api_key_check="    # API Key authentication enabled (localhost /healthz and web UI excluded)
    acl auth_header_present var(txn.auth_header) -m found

    # Extract token: strip 'Bearer ' prefix (case-insensitive) into txn.api_token
    http-request set-var(txn.api_token) var(txn.auth_header),regsub(^[Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+,)

    # Validate extracted token via exact string match (no regex escaping issues)
    acl auth_valid var(txn.api_token) -m str ${escaped_key_sed}

    # Deny requests without valid authentication
    # Bypass: localhost health checks, web UI static assets, Web UI API (/api/*)
    # /api/* is the Web UI backend — exempt from API_KEY (protected by WEB_USERNAME if set)
    # MCP (/mcp) always requires API_KEY auth
    http-request deny deny_status 401 content-type \"application/json\" string '{\"error\":\"Unauthorized\",\"message\":\"Valid API key required\"}' if !is_health_check !is_web_ui !is_api_path !auth_header_present
    http-request deny deny_status 401 content-type \"application/json\" string '{\"error\":\"Unauthorized\",\"message\":\"Valid API key required\"}' if is_health_check !is_localhost !auth_header_present
    http-request deny deny_status 403 content-type \"application/json\" string '{\"error\":\"Forbidden\",\"message\":\"Invalid API key\"}' if !is_health_check !is_web_ui !is_api_path auth_header_present !auth_valid
    http-request deny deny_status 403 content-type \"application/json\" string '{\"error\":\"Forbidden\",\"message\":\"Invalid API key\"}' if is_health_check !is_localhost auth_header_present !auth_valid"
    else
        api_key_check="    # API Key authentication disabled - all requests allowed"
    fi

    local cors_check
    local cors_preflight_condition
    local cors_response_condition

    if [[ "$HAPROXY_CORS_ENABLED" == "true" ]]; then
        if [[ "$ALLOW_ALL_CORS" == "true" ]]; then
            cors_check="    # CORS enabled - allowing ALL origins"
            cors_preflight_condition="{ var(txn.origin) -m found }"
            cors_response_condition="{ var(txn.origin) -m found }"
        else
            cors_check="    # CORS enabled - allowing specific origins
    acl cors_origin_allowed var(txn.origin) -m str -i"

            local origin
            for origin in "${HAPROXY_CORS_ORIGINS[@]}"; do
                cors_check+=" ${origin}"
            done

            cors_check+="

    # Deny requests from non-allowed origins
    http-request deny deny_status 403 content-type \"application/json\" string '{\"error\":\"Forbidden\",\"message\":\"Origin not allowed\"}' if { var(txn.origin) -m found } !cors_origin_allowed"
            cors_preflight_condition="cors_origin_allowed"
            cors_response_condition="cors_origin_allowed"
        fi
    else
        cors_check="    # CORS disabled"
        cors_preflight_condition="{ always_false }"
        cors_response_condition="{ always_false }"
    fi

    local escaped_bind_params
    local escaped_quic_bind_line
    escaped_bind_params="$(escape_sed_replacement "$BIND_PARAMS")"
    escaped_quic_bind_line="$(escape_sed_replacement "$QUIC_BIND_LINE")"

    # Concurrency caps. Bound HAProxy-level acceptance so a burst cannot
    # trigger unbounded upstream mcp-proxy child reuse / spawn. Empty = no cap.
    local frontend_maxconn_clause=""
    local server_maxconn_clause=""
    if [[ "${HAPROXY_FRONTEND_MAXCONN:-0}" =~ ^[1-9][0-9]*$ ]]; then
        frontend_maxconn_clause="maxconn ${HAPROXY_FRONTEND_MAXCONN}"
    fi
    if [[ "${HAPROXY_SERVER_MAXCONN:-0}" =~ ^[1-9][0-9]*$ ]]; then
        server_maxconn_clause="maxconn ${HAPROXY_SERVER_MAXCONN}"
    fi
    local escaped_frontend_maxconn
    local escaped_server_maxconn
    escaped_frontend_maxconn="$(escape_sed_replacement "$frontend_maxconn_clause")"
    escaped_server_maxconn="$(escape_sed_replacement "$server_maxconn_clause")"

    sed -e "s|__SERVER_PORT__|${PORT}|g" \
        -e "s|__BIND_PARAMS__|${escaped_bind_params}|g" \
        -e "s|__QUIC_BIND_LINE__|${escaped_quic_bind_line}|g" \
        -e "s|__INTERNAL_PORT__|${INTERNAL_PORT}|g" \
        -e "s|__WEB_UI_PORT__|${WEB_UI_PORT}|g" \
        -e "s|__WEB_UI_STATIC_PORT__|${WEB_UI_STATIC_PORT}|g" \
        -e "s|__SERVER_NAME__|${HAPROXY_SERVER_NAME}|g" \
        -e "s|__CORS_PREFLIGHT_CONDITION__|${cors_preflight_condition}|g" \
        -e "s|__CORS_RESPONSE_CONDITION__|${cors_response_condition}|g" \
        -e "s|__FRONTEND_MAXCONN__|${escaped_frontend_maxconn}|g" \
        -e "s|__SERVER_MAXCONN__|${escaped_server_maxconn}|g" \
        "$HAPROXY_TEMPLATE" > "${HAPROXY_CONFIG}.tmp"

    awk -v replacement="$api_key_check" -v replacement_cors="$cors_check" \
        -v replacement_web_auth="$web_auth_check" -v replacement_web_userlist="$web_auth_userlist" \
        -v replacement_rate_table="$rate_limit_table" -v replacement_rate_check="$rate_limit_check" \
        -v replacement_ip_access="$ip_access_check" '
        /__API_KEY_CHECK__/ { print replacement; next }
        /__CORS_CHECK__/ { print replacement_cors; next }
        /__WEB_AUTH_CHECK__/ { print replacement_web_auth; next }
        /__WEB_AUTH_USERLIST__/ { print replacement_web_userlist; next }
        /__RATE_LIMIT_TABLE__/ { print replacement_rate_table; next }
        /__RATE_LIMIT_CHECK__/ { print replacement_rate_check; next }
        /__IP_ACCESS_CHECK__/ { print replacement_ip_access; next }
        { print }
    ' "${HAPROXY_CONFIG}.tmp" > "$HAPROXY_CONFIG"

    rm -f "${HAPROXY_CONFIG}.tmp"

    haproxy -c -f "$HAPROXY_CONFIG" >/dev/null
}

start_haproxy() {
    echo "Starting HAProxy on port ${PORT}"
    haproxy -db -f "$HAPROXY_CONFIG" &
    HAPROXY_PID=$!
}

run_gitnexus_clean() {
    # Run as node user so registry path matches serve/mcp processes
    local run_cmd=()
    if [ "$(id -u)" -eq 0 ]; then
        run_cmd=(gosu node)
    fi

    if is_true "${CLEAN_ALL_FORCE:-false}"; then
        if [[ -f "$CLEAN_ALL_DONE_FILE" ]]; then
            echo "Clean --all --force already completed this container lifecycle, skipping"
            return
        fi
        echo "Running gitnexus clean --all --force..."
        if "${run_cmd[@]}" gitnexus clean --all --force; then
            touch "$CLEAN_ALL_DONE_FILE"
        else
            echo "Warning: gitnexus clean --all --force returned non-zero (will retry on next restart)"
        fi
        return
    fi

    if is_true "${CLEAN_ON_START:-false}"; then
        if [[ -f "$CLEAN_DONE_FILE" ]]; then
            echo "Clean already completed this container lifecycle, skipping"
            return
        fi
        echo "Running gitnexus clean..."
        if "${run_cmd[@]}" gitnexus clean; then
            touch "$CLEAN_DONE_FILE"
        else
            echo "Warning: gitnexus clean returned non-zero (will retry on next restart)"
        fi
    fi
}

run_gitnexus_analyze() {
    local data_dir="$1"

    if [[ ! -d "$data_dir" ]]; then
        echo "Warning: DATA_DIR='${data_dir}' does not exist. Skipping analysis."
        return
    fi

    # Cache supported flags (once per entrypoint run)
    local help_text
    help_text="$(gitnexus analyze --help 2>&1 || true)"

    # Determine which phases to run (decided first so base_args can react)
    local do_force=false
    if is_true "${ANALYZE_FORCE:-false}"; then
        if [[ -f "$ANALYZE_FORCE_DONE_FILE" ]]; then
            echo "Force analysis already completed this container lifecycle, skipping --force"
        else
            do_force=true
        fi
    fi
    local do_embeddings=false
    if is_true "${ANALYZE_EMBEDDINGS:-false}" && echo "$help_text" | grep -q -- '--embeddings'; then
        do_embeddings=true
    fi
    local do_skills=false
    if is_true "${ANALYZE_SKILLS:-false}" && echo "$help_text" | grep -q -- '--skills'; then
        do_skills=true
    fi

    # Build base args (shared across all phases)
    local base_args=()
    if is_true "${ANALYZE_SKIP_GIT:-false}" && echo "$help_text" | grep -q -- '--skip-git'; then
        base_args+=("--skip-git")
    fi
    if is_true "${ANALYZE_VERBOSE:-false}" && echo "$help_text" | grep -q -- '--verbose'; then
        # Upstream --verbose renders progress bars via ANSI cursor control
        # that trigger non-zero exit (and truncate skill generation) when
        # combined with --embeddings or --skills. Drop it in that case.
        if [[ "$do_embeddings" == "true" || "$do_skills" == "true" ]]; then
            echo "Note: ANALYZE_VERBOSE ignored because ANALYZE_EMBEDDINGS/ANALYZE_SKILLS is set (upstream incompatibility)"
        else
            base_args+=("--verbose")
        fi
    fi

    # Suppress MaxListenersExceededWarning — gitnexus analyze adds many drain
    # listeners on stdout during concurrent file processing (not a leak).
    # The preload approach (--require) doesn't survive the upstream execFileSync
    # re-exec for heap management, so --no-warnings is the only reliable option.
    export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--no-warnings"
    local run_cmd=()
    if [ "$(id -u)" -eq 0 ]; then
        run_cmd=(gosu node)
    fi

    local found_repos=0
    for repo_dir in "$data_dir"/*/; do
        if [[ -d "$repo_dir" ]]; then
            found_repos=1
            echo "Analyzing repository: ${repo_dir}"
            # Pre-flight: verify the effective user can read the repo contents.
            local test_cmd=("${run_cmd[@]}")
            local can_read=false
            if [[ ${#test_cmd[@]} -gt 0 ]]; then
                if "${test_cmd[@]}" test -r "${repo_dir}.git/HEAD" 2>/dev/null || \
                   "${test_cmd[@]}" test -r "${repo_dir}.gitignore" 2>/dev/null; then
                    can_read=true
                fi
            else
                if [[ -r "${repo_dir}.git/HEAD" ]] || [[ -r "${repo_dir}.gitignore" ]]; then
                    can_read=true
                fi
            fi
            if [[ "$can_read" == "false" ]]; then
                echo "Warning: node user (PUID=${PUID}) cannot read files in ${repo_dir}"
                echo "  Hint: set PUID/PGID to match the file owner, or fix volume permissions"
                echo "  Skipping analysis for this repository"
                continue
            fi

            # Phase 1: Code graph (heaviest — parses files, builds graph)
            local analyze_args=("${base_args[@]}")
            [[ "$do_force" == "true" ]] && analyze_args+=("--force")
            [[ "$do_embeddings" == "true" ]] && analyze_args+=("--embeddings")
            [[ "$do_skills" == "true" ]] && analyze_args+=("--skills")

            # Single combined call. Splitting phases causes upstream to report
            # "Already up to date" on the second invocation (commit hash match),
            # silently skipping --embeddings/--skills work. Verified v1.6.1:
            # combined --embeddings --skills produces both without crashing.
            local phase_desc="code graph"
            [[ "$do_embeddings" == "true" ]] && phase_desc="${phase_desc} + embeddings"
            [[ "$do_skills" == "true" ]] && phase_desc="${phase_desc} + skills"
            echo "  Analyzing (${phase_desc})..."
            local meta_file="${repo_dir}.gitnexus/meta.json"
            local before_ts=0
            [[ -f "$meta_file" ]] && before_ts=$(stat -c %Y "$meta_file" 2>/dev/null || echo 0)
            # Upstream gitnexus analyze truncates skill generation (~7/20) and
            # exits rc=1 when stdout is non-TTY (the default under `docker run -d`).
            # Wrap in script(1) to allocate a pseudo-TTY so full output is produced.
            # Temporarily clear EXIT/INT/TERM traps — script(1) propagates signal
            # state to its child, and the outer shutdown trap causes upstream to
            # exit rc=1 after ~7 skills.
            set +e
            trap - EXIT INT TERM
            (cd "$repo_dir" && script --flush -q -e -c "$(printf '%q ' "${run_cmd[@]}" gitnexus analyze "${analyze_args[@]}")" /dev/null 2>&1)
            local analyze_rc=$?
            trap shutdown EXIT INT TERM
            set -e
            # Upstream sometimes exits non-zero in --verbose mode despite completing
            # successfully. Trust meta.json freshness as the real success signal.
            if [[ -f "$meta_file" ]]; then
                local after_ts
                after_ts=$(stat -c %Y "$meta_file" 2>/dev/null || echo 0)
                if [[ "$after_ts" -gt "$before_ts" ]]; then
                    [[ "$analyze_rc" -ne 0 ]] && \
                        echo "  (gitnexus exited rc=${analyze_rc} but meta.json updated — treating as success)"
                else
                    echo "Warning: gitnexus analyze did not refresh meta.json for ${repo_dir} (rc=${analyze_rc})"
                    continue
                fi
            else
                echo "Warning: gitnexus analyze failed for ${repo_dir} (rc=${analyze_rc}, no meta.json)"
                continue
            fi
        fi
    done

    if [[ "$found_repos" -eq 0 ]]; then
        echo "No subdirectories found in ${data_dir}. Analyzing root data directory..."
        local analyze_args=("${base_args[@]}")
        [[ "$do_force" == "true" ]] && analyze_args+=("--force")
        [[ "$do_embeddings" == "true" ]] && analyze_args+=("--embeddings")
        [[ "$do_skills" == "true" ]] && analyze_args+=("--skills")
        local meta_file="${data_dir}/.gitnexus/meta.json"
        local before_ts=0
        [[ -f "$meta_file" ]] && before_ts=$(stat -c %Y "$meta_file" 2>/dev/null || echo 0)
        set +e
        trap - EXIT INT TERM
        (cd "$data_dir" && script --flush -q -e -c "$(printf '%q ' "${run_cmd[@]}" gitnexus analyze "${analyze_args[@]}")" /dev/null 2>&1)
        local analyze_rc=$?
        trap shutdown EXIT INT TERM
        set -e
        if [[ -f "$meta_file" ]]; then
            local after_ts
            after_ts=$(stat -c %Y "$meta_file" 2>/dev/null || echo 0)
            if [[ "$after_ts" -gt "$before_ts" ]]; then
                [[ "$analyze_rc" -ne 0 ]] && \
                    echo "  (gitnexus exited rc=${analyze_rc} but meta.json updated — treating as success)"
            else
                echo "Warning: gitnexus analyze did not refresh meta.json for ${data_dir} (rc=${analyze_rc})"
            fi
        else
            echo "Warning: gitnexus analyze failed for ${data_dir} (rc=${analyze_rc}, no meta.json)"
        fi
    fi

    if [[ "$do_force" == "true" ]] && [[ ! -f "$ANALYZE_FORCE_DONE_FILE" ]]; then
        touch "$ANALYZE_FORCE_DONE_FILE"
    fi
}

run_gitnexus_wiki() {
    if ! is_true "${WIKI_ENABLED:-false}"; then
        return
    fi

    local data_dir="$1"
    local wiki_args=()

    if [[ -n "${WIKI_MODEL:-}" ]]; then
        wiki_args+=("--model" "$WIKI_MODEL")
    fi

    if [[ -n "${WIKI_BASE_URL:-}" ]]; then
        wiki_args+=("--base-url" "$WIKI_BASE_URL")
    fi

    if is_true "${WIKI_FORCE:-false}"; then
        if [[ -f "$WIKI_FORCE_DONE_FILE" ]]; then
            echo "Force wiki generation already completed this container lifecycle, skipping --force"
        else
            wiki_args+=("--force")
        fi
    fi

    # Run as node user so registry path matches serve/mcp processes
    local run_cmd=()
    if [ "$(id -u)" -eq 0 ]; then
        run_cmd=(gosu node)
    fi

    for repo_dir in "$data_dir"/*/; do
        if [[ -d "$repo_dir" ]]; then
            echo "Generating wiki for: ${repo_dir}"
            (cd "$repo_dir" && "${run_cmd[@]}" gitnexus wiki "${wiki_args[@]}" 2>&1) || \
                echo "Warning: gitnexus wiki failed for ${repo_dir}"
        fi
    done

    if is_true "${WIKI_FORCE:-false}" && [[ ! -f "$WIKI_FORCE_DONE_FILE" ]]; then
        touch "$WIKI_FORCE_DONE_FILE"
    fi
}

start_mcp_server() {
    # mcp-proxy session model: stateful by default — one stdio child per
    # Mcp-Session-Id, reused across requests. Sessions persist until the client
    # explicitly closes them (no server-side TTL). Set MCP_PROXY_STATELESS=true
    # only when full per-request isolation is required (memory-hostile).
    MCP_PROXY_STATELESS="${MCP_PROXY_STATELESS:-false}"
    # Cap virtual memory of each gitnexus stdio child (MiB; 0 disables).
    GITNEXUS_MAX_MEM_MB="${GITNEXUS_MAX_MEM_MB:-0}"

    # mcp-proxy receives the stdio command as positional args after `--`,
    # so prlimit can prefix the argv list directly.
    local gitnexus_argv=(gitnexus mcp)
    if [[ "${GITNEXUS_MAX_MEM_MB}" =~ ^[1-9][0-9]*$ ]] && command -v prlimit >/dev/null 2>&1; then
        local mem_bytes=$((GITNEXUS_MAX_MEM_MB * 1024 * 1024))
        gitnexus_argv=(prlimit "--as=${mem_bytes}" -- "${gitnexus_argv[@]}")
        echo "GitNexus MCP child memory cap: ${GITNEXUS_MAX_MEM_MB} MiB (prlimit --as)"
    fi

    # Build mcp-proxy CORS args. CORS env may be comma-separated origins or "*".
    local cors_args=()
    if [[ -n "${CORS:-}" ]]; then
        local origin
        for origin in ${CORS//,/ }; do
            cors_args+=(--allow-origin "$origin")
        done
    fi
    cors_args+=(--expose-header Mcp-Session-Id)

    local stateless_args=()
    if [[ "${MCP_PROXY_STATELESS,,}" == "true" ]]; then
        stateless_args+=(--stateless)
    else
        stateless_args+=(--no-stateless)
    fi

    local mode_tag="stateful"
    [[ "${MCP_PROXY_STATELESS,,}" == "true" ]] && mode_tag="stateless"

    case "${PROTOCOL^^}" in
        SHTTP|STREAMABLEHTTP|SSE)
            # mcp-proxy exposes /mcp (StreamableHTTP) and /sse simultaneously.
            CMD_ARGS=(mcp-proxy
                --host 127.0.0.1
                --port "$INTERNAL_PORT"
                --pass-environment
                "${stateless_args[@]}"
                "${cors_args[@]}"
                --
                "${gitnexus_argv[@]}")
            PROTOCOL_DISPLAY="mcp-proxy: /mcp (StreamableHTTP) + /sse (${mode_tag})"
            ;;
        WS|WEBSOCKET)
            echo "ERROR: WebSocket transport is not supported by mcp-proxy." >&2
            echo "       Use PROTOCOL=SHTTP or PROTOCOL=SSE instead." >&2
            return 1
            ;;
        *)
            echo "Invalid PROTOCOL='${PROTOCOL}', defaulting to ${DEFAULT_PROTOCOL}"
            CMD_ARGS=(mcp-proxy
                --host 127.0.0.1
                --port "$INTERNAL_PORT"
                --pass-environment
                "${stateless_args[@]}"
                "${cors_args[@]}"
                --
                "${gitnexus_argv[@]}")
            PROTOCOL_DISPLAY="mcp-proxy: /mcp (StreamableHTTP) + /sse (${mode_tag})"
            ;;
    esac

    echo "Launching GitNexus MCP via ${PROTOCOL_DISPLAY}"

    if [ "$(id -u)" -eq 0 ]; then
        gosu node "${CMD_ARGS[@]}" &
    else
        "${CMD_ARGS[@]}" &
    fi

    MCP_PID=$!

    local i=0
    until nc -z 127.0.0.1 "$INTERNAL_PORT" >/dev/null 2>&1; do
        if ! kill -0 "$MCP_PID" >/dev/null 2>&1; then
            echo "MCP server exited before becoming ready" >&2
            return 1
        fi

        i=$((i + 1))
        if [ "$i" -ge 30 ]; then
            echo "MCP server did not become ready on ${INTERNAL_PORT}" >&2
            return 1
        fi

        sleep 1
    done
}

start_web_ui() {
    if ! is_true "${ENABLE_WEB_UI:-true}"; then
        echo "Web UI disabled (ENABLE_WEB_UI=false)"
        return
    fi

    echo "Starting GitNexus API server on port ${WEB_UI_PORT}"

    if [ "$(id -u)" -eq 0 ]; then
        gosu node gitnexus serve --port "$WEB_UI_PORT" &
    else
        gitnexus serve --port "$WEB_UI_PORT" &
    fi

    WEB_UI_PID=$!
}

start_web_static() {
    if ! is_true "${ENABLE_WEB_UI:-true}"; then
        return
    fi

    if [[ ! -d "$WEB_UI_STATIC_DIR" ]]; then
        echo "Web UI static files not found at ${WEB_UI_STATIC_DIR}, skipping static server"
        return
    fi

    # Rewrite hardcoded localhost:4747 URL in web UI JS to use browser origin via HAProxy
    local js_bundle
    js_bundle="$(find "$WEB_UI_STATIC_DIR/assets" -name 'index-*.js' -type f 2>/dev/null | head -n1)"
    if [[ -n "$js_bundle" ]] && grep -q 'http://localhost:4747' "$js_bundle" 2>/dev/null; then
        # Replace string literals (both quote styles) with window.location.origin expression
        # "http://localhost:4747" → "+window.location.origin+"  (evaluates to origin in JS)
        # 'http://localhost:4747' → '+window.location.origin+'  (same)
        sed -i \
            -e 's|"http://localhost:4747"|""+window.location.origin+""|g' \
            -e "s|'http://localhost:4747'|''+window.location.origin+''|g" \
            "$js_bundle"
        echo "Patched web UI to use browser origin via HAProxy"
    fi

    echo "Starting Web UI static server on port ${WEB_UI_STATIC_PORT}"

    if [ "$(id -u)" -eq 0 ]; then
        gosu node npx serve "$WEB_UI_STATIC_DIR" -l "$WEB_UI_STATIC_PORT" --no-clipboard --single &
    else
        npx serve "$WEB_UI_STATIC_DIR" -l "$WEB_UI_STATIC_PORT" --no-clipboard --single &
    fi

    WEB_UI_STATIC_PID=$!
}

shutdown() {
    set +e
    if [[ -n "${HAPROXY_PID:-}" ]]; then
        kill "$HAPROXY_PID" 2>/dev/null || true
    fi
    if [[ -n "${MCP_PID:-}" ]]; then
        kill "$MCP_PID" 2>/dev/null || true
    fi
    if [[ -n "${WEB_UI_PID:-}" ]]; then
        kill "$WEB_UI_PID" 2>/dev/null || true
    fi
    if [[ -n "${WEB_UI_STATIC_PID:-}" ]]; then
        kill "$WEB_UI_STATIC_PID" 2>/dev/null || true
    fi
    wait 2>/dev/null || true
}

main() {
    if [[ $# -gt 0 ]]; then
        exec "$@"
    fi

    PUID="${PUID:-$DEFAULT_PUID}"
    PGID="${PGID:-$DEFAULT_PGID}"
    PUID="$(trim "$PUID")"
    PGID="$(trim "$PGID")"

    PORT="${PORT:-$DEFAULT_PORT}"
    INTERNAL_PORT="${INTERNAL_PORT:-$DEFAULT_INTERNAL_PORT}"
    WEB_UI_PORT="${WEB_UI_PORT:-$DEFAULT_WEB_UI_PORT}"
    PROTOCOL="${PROTOCOL:-$DEFAULT_PROTOCOL}"
    ENABLE_HTTPS="${ENABLE_HTTPS:-false}"
    TLS_CERT_PATH="${TLS_CERT_PATH:-/etc/haproxy/certs/server.crt}"
    TLS_KEY_PATH="${TLS_KEY_PATH:-/etc/haproxy/certs/server.key}"
    TLS_PEM_PATH="${TLS_PEM_PATH:-/etc/haproxy/certs/server.pem}"
    TLS_MIN_VERSION="${TLS_MIN_VERSION:-$DEFAULT_TLS_MIN_VERSION}"
    HTTP_VERSION_MODE="${HTTP_VERSION_MODE:-$DEFAULT_HTTP_VERSION_MODE}"
    CORS="${CORS:-}"
    DATA_DIR="${DATA_DIR:-$DEFAULT_DATA_DIR}"

    PORT="$(validate_port "PORT" "$PORT" "$DEFAULT_PORT")"
    INTERNAL_PORT="$(validate_port "INTERNAL_PORT" "$INTERNAL_PORT" "$DEFAULT_INTERNAL_PORT")"
    WEB_UI_PORT="$(validate_port "WEB_UI_PORT" "$WEB_UI_PORT" "$DEFAULT_WEB_UI_PORT")"
    TLS_MIN_VERSION="$(validate_tls_min_version "$TLS_MIN_VERSION" "$DEFAULT_TLS_MIN_VERSION")"
    HTTP_VERSION_MODE="$(normalize_http_version_mode "$HTTP_VERSION_MODE")"

    validate_api_key
    validate_rate_limit
    validate_ip_access
    validate_web_auth
    validate_cors

    ensure_state_dir

    if [[ ! -f "$FIRST_RUN_FILE" ]]; then
        handle_first_run
    fi

    # Export variables for banner.sh (runs as child process)
    export PORT PUID PGID WEB_UI_PORT PROTOCOL DATA_DIR ENABLE_HTTPS NODE_ENV
    /usr/local/bin/banner.sh

    # Check for NVIDIA GPU availability and CUDA EP support
    local compute_mode="cpu"
    local cuda_so
    cuda_so="$(find /usr/local/lib/node_modules -name 'libonnxruntime_providers_cuda.so' -type f 2>/dev/null | head -n1)"

    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "NVIDIA GPU detected:"
        nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null || echo "  (nvidia-smi available but query failed)"
        # Register host-mounted CUDA libs with ldconfig so isCudaAvailable() finds them.
        # Common mount paths: /usr/local/cuda/lib64, /usr/local/cuda-12/targets/x86_64-linux/lib
        local cuda_conf="/etc/ld.so.conf.d/cuda-host.conf"
        > "$cuda_conf"
        for cuda_dir in \
            /usr/local/cuda/lib64 \
            /usr/local/cuda-12/targets/x86_64-linux/lib \
            /usr/local/cuda/targets/x86_64-linux/lib \
            /usr/lib/x86_64-linux-gnu; do
            if [[ -d "$cuda_dir" ]] && ls "$cuda_dir"/libcublas*.so* >/dev/null 2>&1; then
                echo "$cuda_dir" >> "$cuda_conf"
                echo "  Registered CUDA lib path: $cuda_dir"
            fi
        done
        ldconfig 2>/dev/null || true
        if [[ -n "$cuda_so" ]]; then
            compute_mode="cuda"
            echo "CUDA Execution Provider: enabled ($(du -sh "$cuda_so" | cut -f1))"
            if ldconfig -p 2>/dev/null | grep -q 'libcublasLt.so.12'; then
                echo "CUDA runtime libraries: found (libcublasLt.so.12)"
            else
                echo "WARNING: libcublasLt.so.12 not found in ldconfig — CUDA may fall back to CPU"
                echo "  Hint: mount host CUDA libs, e.g.: -v /usr/local/cuda/lib64:/usr/local/cuda/lib64:ro"
            fi
        else
            echo "CUDA Execution Provider: binaries not found — falling back to CPU"
        fi
    else
        echo "No NVIDIA GPU detected (running on CPU)"
    fi
    export GITNEXUS_COMPUTE_MODE="$compute_mode"

    # Ensure data directory exists and has correct ownership
    mkdir -p "$DATA_DIR"
    chown "${PUID}:${PGID}" "$DATA_DIR" 2>/dev/null || true
    # Only chown the top-level data dir, not recursively into mounted repos
    # This preserves original file ownership in mounted volumes
    for subdir in "$DATA_DIR"/*/; do
        if [[ -d "$subdir" ]]; then
            chown "${PUID}:${PGID}" "$subdir" 2>/dev/null || true
        fi
    done

    # Ensure GitNexus registry directory has correct ownership (may be a mounted volume)
    mkdir -p /home/node/.gitnexus
    chown -R "${PUID}:${PGID}" /home/node/.gitnexus 2>/dev/null || true

    # Ensure cache directories exist for the node user.
    # Without this, libraries try to write cache into /usr/local/lib/node_modules/
    # which is read-only for the node user, causing EACCES errors during analysis.
    mkdir -p /home/node/.cache
    chown "${PUID}:${PGID}" /home/node/.cache 2>/dev/null || true
    export XDG_CACHE_HOME="/home/node/.cache"

    # npm cache — `gitnexus` CLI + `npx serve` run as node, must not fall back
    # to /root/.npm (mcp-proxy itself is pure Python and doesn't use npm).
    mkdir -p /home/node/.npm
    chown -R "${PUID}:${PGID}" /home/node/.npm 2>/dev/null || true
    export npm_config_cache="/home/node/.npm"

    # HuggingFace transformers (Python env vars + JS library)
    export HF_HOME="/home/node/.cache/huggingface"
    export TRANSFORMERS_CACHE="/home/node/.cache/huggingface/transformers"
    mkdir -p "$HF_HOME" "$TRANSFORMERS_CACHE" 2>/dev/null || true
    chown -R "${PUID}:${PGID}" "$HF_HOME" 2>/dev/null || true

    # The @huggingface/transformers JS library writes its own .cache/ inside the
    # module directory, ignoring HF_HOME/TRANSFORMERS_CACHE env vars.
    # Redirect it via symlink to the writable cache path.
    local hf_module_cache
    hf_module_cache="$(find /usr/local/lib/node_modules -path '*/\@huggingface/transformers' -type d 2>/dev/null | head -n1)"
    if [[ -n "$hf_module_cache" ]]; then
        local target_cache="/home/node/.cache/huggingface/transformers-js"
        mkdir -p "$target_cache" 2>/dev/null || true
        chown "${PUID}:${PGID}" "$target_cache" 2>/dev/null || true
        if [[ -d "${hf_module_cache}/.cache" && ! -L "${hf_module_cache}/.cache" ]]; then
            rm -rf "${hf_module_cache}/.cache"
        fi
        if [[ ! -e "${hf_module_cache}/.cache" ]]; then
            ln -sf "$target_cache" "${hf_module_cache}/.cache"
        fi
    fi

    # ONNX Runtime cache — used during model inference
    export ONNX_HOME="/home/node/.cache/onnx"
    mkdir -p "$ONNX_HOME" 2>/dev/null || true
    chown -R "${PUID}:${PGID}" "$ONNX_HOME" 2>/dev/null || true

    if is_true "$ENABLE_HTTPS"; then
        prepare_tls_pem "$TLS_CERT_PATH" "$TLS_KEY_PATH" "$TLS_PEM_PATH"
    fi

    resolve_listener_protocols "$HTTP_VERSION_MODE"
    generate_haproxy_config

    trap shutdown INT TERM EXIT

    # Mark all mounted repos as safe for git (ownership may differ from container user)
    # Set for both root and the node user (analyze/serve/mcp run as node via gosu)
    git config --global --add safe.directory '*'
    if [ "$(id -u)" -eq 0 ]; then
        gosu node git config --global --add safe.directory '*'
    fi

    # GitNexus-specific: clean, analyze, wiki
    echo "=========================================="
    echo "GitNexus Repository Analysis Phase"
    echo "Data directory: ${DATA_DIR}"
    echo "=========================================="

    # Patch: fix MaxListenersExceededWarning on relationship CSV WriteStreams.
    # Without a waitingForDrain guard, each backpressure event on the same
    # WriteStream adds another once('drain') listener. The guard ensures only
    # one drain listener per stream at a time, eliminating the warning entirely.
    # Safe to re-run: node script only acts if the file hasn't been patched yet.
    # Remove this patch once upstream gitnexus ships the fix (PR #818).
    local _lbug_adapter
    _lbug_adapter="$(npm root -g)/gitnexus/dist/core/lbug/lbug-adapter.js"
    if [[ ! -f "$_lbug_adapter" ]]; then
        _lbug_adapter="/tmp/package/dist/core/lbug/lbug-adapter.js"
    fi
    if [[ -f "$_lbug_adapter" ]] && ! grep -q 'waitingForDrain' "$_lbug_adapter"; then
        node -e "
const fs = require('fs');
let c = fs.readFileSync('${_lbug_adapter}', 'utf-8');
// 1. Add waitingForDrain Set before the Promise block
c = c.replace(
  'await new Promise((resolve, reject) => {\\n        const rl = createInterface({',
  'const waitingForDrain = new Set();\\n    await new Promise((resolve, reject) => {\\n        const rl = createInterface({'
);
// 2. Remove setMaxListeners(50) if present
c = c.replace(/\\n\\s*ws\\.setMaxListeners\\(50\\);/, '');
// 3. Replace backpressure block with guarded version
c = c.replace(
  \`if (!ok) {\\n                rl.pause();\\n                ws.once('drain', () => rl.resume());\\n            }\`,
  \`if (!ok && !waitingForDrain.has(pairKey)) {\\n                waitingForDrain.add(pairKey);\\n                rl.pause();\\n                ws.once('drain', () => {\\n                    waitingForDrain.delete(pairKey);\\n                    rl.resume();\\n                });\\n            }\`
);
fs.writeFileSync('${_lbug_adapter}', c);
" && echo "Applied waitingForDrain patch to lbug-adapter.js" || \
            echo "Warning: waitingForDrain patch failed (non-fatal)"
    fi

    run_gitnexus_clean
    run_gitnexus_analyze "$DATA_DIR"
    run_gitnexus_wiki "$DATA_DIR"

    echo "=========================================="
    echo "Starting GitNexus Services"
    echo "=========================================="

    start_mcp_server
    start_web_ui
    start_web_static
    start_haproxy

    if [[ -n "$API_KEY" ]]; then
        echo "API key authentication enabled"
    else
        echo "API key authentication disabled"
    fi

    if is_true "$ENABLE_HTTPS"; then
        echo "HTTPS enabled on port ${PORT}"
        echo "HTTP versions enabled: ${EFFECTIVE_HTTP_VERSIONS}"
    else
        echo "HTTPS disabled; listening on HTTP port ${PORT}"
        echo "WARNING: Traffic is NOT encrypted when ENABLE_HTTPS=false." >&2
        echo "WARNING: Use ENABLE_HTTPS=true for internet-facing or untrusted networks." >&2
        if [[ "${NODE_ENV:-}" =~ ^([Pp][Rr][Oo][Dd][Uu][Cc][Tt][Ii][Oo][Nn])$ ]]; then
            echo "====================================================================" >&2
            echo "SECURITY WARNING: NODE_ENV=production with ENABLE_HTTPS=false" >&2
            echo "SECURITY WARNING: Requests and responses are plaintext over the network." >&2
            echo "SECURITY WARNING: Enable TLS now by setting ENABLE_HTTPS=true." >&2
            echo "====================================================================" >&2
        fi
        if [[ -n "$API_KEY" ]]; then
            echo "WARNING: API_KEY protects access but does not encrypt HTTP traffic." >&2
        fi
    fi

    echo "=========================================="
    echo "GitNexus MCP Server: port ${PORT} (${PROTOCOL_DISPLAY})"
    if is_true "${ENABLE_WEB_UI:-true}"; then
        echo "GitNexus Web UI:     http://0.0.0.0:${PORT}/"
    fi
    echo "=========================================="

    # Wait for any child process to exit
    local pids=("$MCP_PID" "$HAPROXY_PID")
    if [[ -n "${WEB_UI_PID:-}" ]]; then
        pids+=("$WEB_UI_PID")
    fi
    if [[ -n "${WEB_UI_STATIC_PID:-}" ]]; then
        pids+=("$WEB_UI_STATIC_PID")
    fi
    wait -n "${pids[@]}"
}

main "$@"
