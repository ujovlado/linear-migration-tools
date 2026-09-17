#!/bin/bash

set -e

CLIENT_ID="${1:-$LINEAR_CLIENT_ID}"
CLIENT_SECRET="${2:-$LINEAR_CLIENT_SECRET}"

REDIRECT_URI="http://localhost:8080/callback"

if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
    echo "Usage: $0 <client-id> <client-secret>"
    echo "   or: LINEAR_CLIENT_ID=... LINEAR_CLIENT_SECRET=... $0"
    echo ""
    echo "Create an OAuth application first at:"
    echo "  https://linear.app/settings/api/applications/new"
    echo "  Redirect callback URL: $REDIRECT_URI"
    exit 1
fi

# The actor=app parameter is what unlocks createAsUser/displayIconUrl, which the
# import uses to attribute issues and comments to their original ClickUp authors.
build_authorize_url() {
    echo "https://linear.app/oauth/authorize?client_id=${CLIENT_ID}&redirect_uri=${REDIRECT_URI}&response_type=code&scope=read,write&actor=app&prompt=consent"
}

exchange_code_for_token() {
    local code="$1"

    local response=$(curl -s -X POST \
        -d "code=${code}" \
        -d "redirect_uri=${REDIRECT_URI}" \
        -d "client_id=${CLIENT_ID}" \
        -d "client_secret=${CLIENT_SECRET}" \
        -d "grant_type=authorization_code" \
        https://api.linear.app/oauth/token)

    if echo "$response" | jq -e '.access_token' > /dev/null 2>&1; then
        echo "$response" | jq -r '.access_token'
    else
        echo "Error exchanging code for token:" >&2
        echo "$response" | jq -r '.error_description // .error // .' >&2
        return 1
    fi
}

main() {
    for cmd in curl jq; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            echo "Error: $cmd is not installed"
            exit 1
        fi
    done

    echo "1. Open this URL in your browser and authorize the application:"
    echo ""
    echo "   $(build_authorize_url)"
    echo ""
    echo "2. The browser will fail to load $REDIRECT_URI - that is expected."
    echo "   Copy the 'code' parameter out of the address bar."
    echo ""
    printf "Paste the code here: "
    read -r code

    if [ -z "$code" ]; then
        echo "Error: no code provided"
        exit 1
    fi

    local token=$(exchange_code_for_token "$code")

    echo ""
    echo "✓ Got a token. It is valid for 24 hours - run this script again when it expires."
    echo ""
    echo "export LINEAR_OAUTH_TOKEN=$token"
}

main
