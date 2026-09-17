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
    echo "[DRY RUN] Converting issues labeled 'IssueTypeEpic' to Epic type in project: $PROJECT_KEY"
else
    echo "Converting issues labeled 'IssueTypeEpic' to Epic type in project: $PROJECT_KEY"
fi

check_acli_installed() {
    if ! command -v acli &> /dev/null; then
        echo "Error: acli is not installed or not in PATH"
        echo "Please install acli: https://developer.atlassian.com/cloud/acli/installation/"
        exit 1
    fi
}

get_epic_candidate_issues() {
    local project_key="$1"
    local issues=$(acli jira workitem search --jql "project = $project_key AND labels IN (IssueTypeEpic)" --paginate --json | jq -r '.[].key')
    echo "$issues"
}

convert_to_epic() {
    local issue_key="$1"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] Would convert $issue_key to Epic"
    else
        echo "  Converting $issue_key to Epic..."
        acli jira workitem edit --key "$issue_key" --type "Epic" --yes
        echo "  ✓ Converted $issue_key to Epic"
    fi
}

main() {
    check_acli_installed

    epic_candidates=$(get_epic_candidate_issues "$PROJECT_KEY")

    if [ -z "$epic_candidates" ]; then
        echo "No issues with label 'IssueTypeEpic' found in project $PROJECT_KEY"
    else
        local count=$(echo "$epic_candidates" | wc -l | tr -d ' ')
        echo "Found $count issue(s) with label 'IssueTypeEpic' in project $PROJECT_KEY"
        echo ""

        while IFS= read -r issue_key; do
            if [ -n "$issue_key" ]; then
                convert_to_epic "$issue_key"
            fi
        done <<< "$epic_candidates"
    fi

    echo ""
    echo "Epic conversion completed!"
}

main
