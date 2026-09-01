#!/bin/bash

# Shared helpers for the ClickUp -> Linear import scripts.
# Sourced by get-clickup-lists.sh and import-to-linear.sh.

CLICKUP_API="https://api.clickup.com/api/v2"
LINEAR_API="https://api.linear.app/graphql"

# Check for required tooling
check_deps() {
    for cmd in curl jq; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            echo "Error: $cmd is not installed"
            exit 1
        fi
    done
}

# Check for required environment variables
check_clickup_config() {
    if [ -z "$CLICKUP_API_KEY" ]; then
        echo "Error: CLICKUP_API_KEY environment variable is not set"
        echo "Get your API key from: https://app.clickup.com/settings/apps"
        exit 1
    fi
}

check_linear_config() {
    if [ -z "$LINEAR_OAUTH_TOKEN" ]; then
        echo "Error: LINEAR_OAUTH_TOKEN environment variable is not set"
        echo "Get a token by running: ./get-linear-token.sh"
        exit 1
    fi
}

# Make a ClickUp REST API request. Retries on rate limit (~100 requests/minute).
clickup_api_call() {
    local path="$1"

    local body=$(mktemp)
    local attempt=1
    local code=""

    while [ $attempt -le 5 ]; do
        code=$(curl -s -w '%{http_code}' -o "$body" \
            -H "Authorization: $CLICKUP_API_KEY" \
            "${CLICKUP_API}${path}")

        if [ "$code" = "429" ]; then
            echo "  Rate limited by ClickUp, waiting 60s..." >&2
            sleep 60
            attempt=$((attempt + 1))
            continue
        fi
        break
    done

    case "$code" in
        2*)
            cat "$body"
            rm -f "$body"
            ;;
        *)
            echo "Error: ClickUp API returned HTTP $code for $path" >&2
            jq -r '.err // .' < "$body" >&2 || cat "$body" >&2
            rm -f "$body"
            return 1
            ;;
    esac
}

# Make a Linear GraphQL API request. Takes a query and a JSON object of variables.
linear_api_call() {
    local query="$1"
    local variables="$2"

    if [ -z "$variables" ]; then
        variables='{}'
    fi

    local payload=$(jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')
    local body=$(mktemp)
    local attempt=1
    local code=""

    while [ $attempt -le 5 ]; do
        code=$(curl -s -w '%{http_code}' -o "$body" -X POST \
            -H "Authorization: Bearer $LINEAR_OAUTH_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$LINEAR_API")

        if [ "$code" = "429" ]; then
            echo "  Rate limited by Linear, waiting 60s..." >&2
            sleep 60
            attempt=$((attempt + 1))
            continue
        fi
        break
    done

    if [ "$code" = "401" ]; then
        echo "Error: Linear rejected the token (HTTP 401)" >&2
        echo "OAuth tokens expire after 24 hours - re-run ./get-linear-token.sh" >&2
        rm -f "$body"
        return 1
    fi

    # GraphQL reports errors in the body, not only in the status code
    if jq -e '.errors' < "$body" > /dev/null 2>&1; then
        echo "Error: Linear API request failed:" >&2
        jq -r '.errors[] | "    \(.message)"' < "$body" >&2
        rm -f "$body"
        return 1
    fi

    case "$code" in
        2*)
            cat "$body"
            rm -f "$body"
            ;;
        *)
            echo "Error: Linear API returned HTTP $code" >&2
            cat "$body" >&2
            rm -f "$body"
            return 1
            ;;
    esac
}

FILE_UPLOAD_MUTATION='
mutation($size: Int!, $contentType: String!, $filename: String!) {
  fileUpload(size: $size, contentType: $contentType, filename: $filename) {
    success
    uploadFile {
      uploadUrl
      assetUrl
      headers { key value }
    }
  }
}'

# Download a ClickUp attachment. The URLs are normally pre-signed, so try
# unauthenticated first and only fall back to the API token.
download_attachment() {
    local url="$1"
    local dest="$2"

    local code=$(curl -sL -w '%{http_code}' -o "$dest" "$url")

    case "$code" in
        2*) ;;
        *) code=$(curl -sL -w '%{http_code}' -o "$dest" -H "Authorization: $CLICKUP_API_KEY" "$url") ;;
    esac

    case "$code" in
        2*) [ -s "$dest" ] ;;
        *)  return 1 ;;
    esac
}

# Upload a local file to Linear and echo the asset URL it can be referenced by.
# Linear hands out a pre-signed URL, the bytes go straight to storage.
linear_upload_file() {
    local path="$1"
    local filename="$2"
    local content_type="$3"

    local size=$(wc -c < "$path" | tr -d ' ')

    local response
    response=$(linear_api_call "$FILE_UPLOAD_MUTATION" \
        "$(jq -n --argjson size "$size" --arg ct "$content_type" --arg fn "$filename" \
            '{size: $size, contentType: $ct, filename: $fn}')") || return 1

    local upload_url=$(echo "$response" | jq -r '.data.fileUpload.uploadFile.uploadUrl // empty')
    local asset_url=$(echo "$response" | jq -r '.data.fileUpload.uploadFile.assetUrl // empty')

    if [ -z "$upload_url" ] || [ -z "$asset_url" ]; then
        return 1
    fi

    # The pre-signed PUT only accepts the headers Linear signed it with
    local headers
    headers=()
    while IFS=$'\t' read -r key value; do
        if [ -n "$key" ]; then
            headers[${#headers[@]}]="-H"
            headers[${#headers[@]}]="$key: $value"
        fi
    done <<< "$(echo "$response" | jq -r '.data.fileUpload.uploadFile.headers[]? | [.key, .value] | @tsv')"

    local code=$(curl -s -w '%{http_code}' -o /dev/null -X PUT \
        -H "Content-Type: $content_type" \
        -H "Cache-Control: public, max-age=31536000" \
        "${headers[@]}" \
        --data-binary "@$path" \
        "$upload_url")

    case "$code" in
        2*) echo "$asset_url" ;;
        *)  return 1 ;;
    esac
}

# ClickUp timestamps are unix milliseconds, Linear wants ISO 8601.
# BSD date (macOS) uses -r, GNU date uses -d @.
to_iso() {
    local ms="$1"

    case "$ms" in
        ''|*[!0-9]*) return 0 ;;
    esac

    local secs=$((ms / 1000))
    date -u -r "$secs" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "@$secs" +%Y-%m-%dT%H:%M:%SZ
}

# Linear's dueDate is a TimelessDate (YYYY-MM-DD), not a datetime. Converted in
# UTC, matching ClickUp's convention of storing time-less due dates at 04:00 UTC.
to_date() {
    local ms="$1"

    case "$ms" in
        ''|*[!0-9]*) return 0 ;;
    esac

    local secs=$((ms / 1000))
    date -u -r "$secs" +%Y-%m-%d 2>/dev/null \
        || date -u -d "@$secs" +%Y-%m-%d
}

# A key -> value store backed by a temp file. macOS ships bash 3.2, which has no
# associative arrays.
map_create() {
    mktemp
}

map_put() {
    printf '%s\t%s\n' "$2" "$3" >> "$1"
}

map_get() {
    awk -F'\t' -v key="$2" '$1 == key { print $2; exit }' "$1"
}
