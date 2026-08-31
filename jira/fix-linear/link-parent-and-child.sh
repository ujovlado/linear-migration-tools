#!/bin/bash

set -e

TEAM_KEY="$1"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            TEAM_KEY="$1"
            shift
            ;;
    esac
done

if [ -z "$TEAM_KEY" ]; then
    echo "Usage: $0 <team-key> [--dry-run]"
    echo "Example: $0 ENG"
    echo "Example: $0 ENG --dry-run"
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Linking child issues to parent issues in team: $TEAM_KEY"
else
    echo "Linking child issues to parent issues in team: $TEAM_KEY"
fi

# Check for required environment variables
check_linear_config() {
    if [ -z "$LINEAR_API_KEY" ]; then
        echo "Error: LINEAR_API_KEY environment variable is not set"
        echo "Get your API key from: https://linear.app/settings/api"
        exit 1
    fi
}

# Make Linear GraphQL API request
linear_api_call() {
    local query="$1"

    local response=$(curl -s -X POST \
        -H "Authorization: $LINEAR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"query\":$(echo "$query" | jq -Rs .)}" \
        https://api.linear.app/graphql)

    echo "$response"
}

# Get all issues with IssueTypeEpic label in the team
get_parent_issues() {
    local team_key="$1"

    local query='
    query {
      issues(
        filter: {
          team: { key: { eq: "'$team_key'" } }
          labels: { name: { eq: "IssueTypeEpic" } }
        }
        first: 250
      ) {
        nodes {
          id
          identifier
          title
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }'

    local response=$(linear_api_call "$query")

    # Check for errors
    if echo "$response" | jq -e '.errors' > /dev/null 2>&1; then
        echo "Error fetching parent issues:" >&2
        echo "$response" | jq -r '.errors' >&2
        return 1
    fi

    echo "$response" | jq -r '.data.issues.nodes[] | "\(.identifier)|\(.id)"'
}

# Get child issues by label
get_child_issues_by_label() {
    local team_key="$1"
    local parent_identifier="$2"

    local query='
    query {
      issues(
        filter: {
          team: { key: { eq: "'$team_key'" } }
          labels: { name: { eq: "parentIs'$parent_identifier'" } }
        }
        first: 250
      ) {
        nodes {
          id
          identifier
          title
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }'

    local response=$(linear_api_call "$query")

    # Check for errors
    if echo "$response" | jq -e '.errors' > /dev/null 2>&1; then
        echo "Error fetching child issues:" >&2
        echo "$response" | jq -r '.errors' >&2
        return 1
    fi

    echo "$response" | jq -r '.data.issues.nodes[] | "\(.identifier)|\(.id)"'
}

# Set parent link on child issue
set_parent_link() {
    local child_identifier="$1"
    local child_id="$2"
    local parent_identifier="$3"
    local parent_id="$4"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] Would link $child_identifier to $parent_identifier"
    else
        local mutation='
        mutation {
          issueUpdate(
            id: "'$child_id'"
            input: {
              parentId: "'$parent_id'"
            }
          ) {
            success
            issue {
              id
              identifier
              title
              parent {
                id
                identifier
                title
              }
            }
          }
        }'

        local response=$(linear_api_call "$mutation")

        # Check for errors
        if echo "$response" | jq -e '.errors' > /dev/null 2>&1; then
            echo "  ✗ Error linking $child_identifier to $parent_identifier:"
            echo "$response" | jq -r '.errors[] | "    \(.message)"'
        else
            local success=$(echo "$response" | jq -r '.data.issueUpdate.success')
            if [ "$success" = "true" ]; then
                echo "  ✓ Linked $child_identifier to $parent_identifier"
            else
                echo "  ✗ Failed to link $child_identifier to $parent_identifier"
                echo "$response" | jq -r '.data.issueUpdate' 2>/dev/null
            fi
        fi
    fi
}

process_parent_issue() {
    local parent_data="$1"
    local parent_identifier=$(echo "$parent_data" | cut -d'|' -f1)
    local parent_id=$(echo "$parent_data" | cut -d'|' -f2)

    echo "Processing parent: $parent_identifier"

    # Find child issues with parentIs label
    local child_issues=$(get_child_issues_by_label "$TEAM_KEY" "$parent_identifier")

    if [ -z "$child_issues" ]; then
        echo "  No child issues found"
    else
        local count=$(echo "$child_issues" | wc -l | tr -d ' ')
        echo "  Found $count child issue(s)"

        while IFS= read -r child_data; do
            if [ -n "$child_data" ]; then
                local child_identifier=$(echo "$child_data" | cut -d'|' -f1)
                local child_id=$(echo "$child_data" | cut -d'|' -f2)
                set_parent_link "$child_identifier" "$child_id" "$parent_identifier" "$parent_id"
            fi
        done <<< "$child_issues"
    fi
}

main() {
    check_linear_config

    parent_issues=$(get_parent_issues "$TEAM_KEY")

    if [ -z "$parent_issues" ]; then
        echo "No parent issues found in team $TEAM_KEY"
    else
        local count=$(echo "$parent_issues" | wc -l | tr -d ' ')
        echo "Found $count parent issue(s) in team $TEAM_KEY"
        echo ""

        while IFS= read -r parent_data; do
            if [ -n "$parent_data" ]; then
                process_parent_issue "$parent_data"
                echo ""
            fi
        done <<< "$parent_issues"
    fi

    echo "Parent linking completed!"
}

main
