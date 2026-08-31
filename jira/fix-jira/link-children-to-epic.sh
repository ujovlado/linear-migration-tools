#!/bin/bash

set -e

PROJECT_KEY="$1"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            PROJECT_KEY="$1"
            shift
            ;;
    esac
done

if [ -z "$PROJECT_KEY" ]; then
    echo "Usage: $0 <project-key> [--dry-run]"
    echo "Example: $0 PAT"
    echo "Example: $0 PAT --dry-run"
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Linking child issues to Epics in project: $PROJECT_KEY"
else
    echo "Linking child issues to Epics in project: $PROJECT_KEY"
fi

check_acli_installed() {
    if ! command -v acli &> /dev/null; then
        echo "Error: acli is not installed or not in PATH"
        echo "Please install acli: https://developer.atlassian.com/cloud/acli/installation/"
        exit 1
    fi
}

check_jira_config() {
    if [ -z "$JIRA_HOST" ]; then
        echo "Error: JIRA_HOST environment variable is not set"
        echo "Set it with: export JIRA_HOST=your-domain.atlassian.net"
        exit 1
    fi

    if [ -z "$JIRA_USER_EMAIL" ]; then
        echo "Error: JIRA_USER_EMAIL environment variable is not set"
        echo "Set it with: export JIRA_USER_EMAIL=your-email@example.com"
        exit 1
    fi

    if [ -z "$JIRA_API_TOKEN" ]; then
        echo "Error: JIRA_API_TOKEN environment variable is not set"
        echo "Get your API token from: https://id.atlassian.com/manage-profile/security/api-tokens"
        exit 1
    fi
}

get_epics_in_project() {
    local project_key="$1"
    local epics=$(acli jira workitem search --jql "project = $project_key AND issuetype = Epic and labels IN (IssueTypeEpic)" --paginate --json | jq -r '.[].key')
    echo "$epics"
}

get_child_issues_by_label() {
    local project_key="$1"
    local epic_key="$2"
    local child_issues=$(acli jira workitem search --jql "project = $project_key AND labels = parentIs$epic_key" --paginate --json | jq -r '.[].key')
    echo "$child_issues"
}

set_epic_link() {
    local child_key="$1"
    local epic_key="$2"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] Would link $child_key to $epic_key"
    else
        # Use Jira REST API to set parent field
        local auth=$(echo -n "${JIRA_USER_EMAIL}:${JIRA_API_TOKEN}" | base64)
        local url="https://${JIRA_HOST}/rest/api/3/issue/${child_key}"
        local json_payload="{\"fields\":{\"parent\":{\"key\":\"${epic_key}\"}}}"

        local http_code=$(curl -s -w "%{http_code}" -o /tmp/jira_response_$$.json -X PUT \
            -H "Authorization: Basic $auth" \
            -H "Content-Type: application/json" \
            "$url" \
            -d "$json_payload")

        local response=$(cat /tmp/jira_response_$$.json)
        rm -f /tmp/jira_response_$$.json

        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
            echo "  ✓ Linked $child_key to $epic_key"
        else
            echo "  ✗ Error linking $child_key to $epic_key (HTTP $http_code)"
            if [ -n "$response" ]; then
                echo "$response" | jq -r '.errorMessages // .errors // .' 2>/dev/null || echo "$response"
            fi
        fi
    fi
}

process_epic() {
    local epic_key="$1"

    echo "Processing Epic: $epic_key"

    # Find child issues with parentIs label
    local child_issues=$(get_child_issues_by_label "$PROJECT_KEY" "$epic_key")

    if [ -z "$child_issues" ]; then
        echo "  No child issues found"
    else
        local count=$(echo "$child_issues" | wc -l | tr -d ' ')
        echo "  Found $count child issue(s)"

        while IFS= read -r child_key; do
            if [ -n "$child_key" ]; then
                set_epic_link "$child_key" "$epic_key"
            fi
        done <<< "$child_issues"
    fi
}

main() {
    check_acli_installed
    check_jira_config

    epics=$(get_epics_in_project "$PROJECT_KEY")

    if [ -z "$epics" ]; then
        echo "No Epics found in project $PROJECT_KEY"
    else
        local epic_count=$(echo "$epics" | wc -l | tr -d ' ')
        echo "Found $epic_count Epic(s) in project $PROJECT_KEY"
        echo ""

        while IFS= read -r epic_key; do
            if [ -n "$epic_key" ]; then
                process_epic "$epic_key"
                echo ""
            fi
        done <<< "$epics"
    fi

    echo "Epic linking completed!"
}

main
