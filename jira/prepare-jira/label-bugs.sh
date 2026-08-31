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
    echo "[DRY RUN] Adding 'Bug' label to all Bug issues in project: $PROJECT_KEY"
else
    echo "Adding 'Bug' label to all Bug issues in project: $PROJECT_KEY"
fi

check_acli_installed() {
    if ! command -v acli &> /dev/null; then
        echo "Error: acli is not installed or not in PATH"
        echo "Please install acli: https://developer.atlassian.com/cloud/acli/installation/"
        exit 1
    fi
}

get_bug_issues() {
    local project_key="$1"
    local bug_issues=$(acli jira workitem search --jql "project = $project_key AND issuetype = Bug and (labels is EMPTY OR labels NOT IN (Bug)) and statusCategory NOT IN (Done)" --paginate --json | jq -r '.[].key')
    echo "$bug_issues"
}

add_bug_label() {
    local issue_key="$1"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] Would add 'Bug' label to $issue_key"
    else
        echo "  Adding 'Bug' label to $issue_key..."
        acli jira workitem edit --key "$issue_key" --labels "Bug" --yes
        echo "  ✓ Added 'Bug' label to $issue_key"
    fi
}

main() {
    check_acli_installed

    bug_issues=$(get_bug_issues "$PROJECT_KEY")

    if [ -z "$bug_issues" ]; then
        echo "No Bug issues found in project $PROJECT_KEY"
    else
        local count=$(echo "$bug_issues" | wc -l | tr -d ' ')
        echo "Found $count Bug issue(s) in project $PROJECT_KEY"
        echo ""

        while IFS= read -r issue_key; do
            if [ -n "$issue_key" ]; then
                add_bug_label "$issue_key"
            fi
        done <<< "$bug_issues"
    fi

    echo ""
    echo "Bug labeling completed!"
}

main
