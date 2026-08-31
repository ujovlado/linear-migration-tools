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
    echo "[DRY RUN] Adding parent labels to child issues of all Epics in project: $PROJECT_KEY"
else
    echo "Adding parent labels to child issues of all Epics in project: $PROJECT_KEY"
fi

check_acli_installed() {
    if ! command -v acli &> /dev/null; then
        echo "Error: acli is not installed or not in PATH"
        echo "Please install acli: https://developer.atlassian.com/cloud/acli/installation/"
        exit 1
    fi
}

is_epic() {
    local issue_key="$1"
    local issue_type=$(acli jira workitem view "$issue_key" --json | jq -r '.fields.issuetype.name')

    if [ "$issue_type" = "Epic" ]; then
        return 0
    else
        return 1
    fi
}

get_epics_in_project() {
    local project_key="$1"
    local epics=$(acli jira workitem search --jql "project = $project_key AND issuetype = Epic AND statusCategory NOT IN (Done)" --paginate --json | jq -r '.[].key')
    echo "$epics"
}

get_child_issues() {
    local epic_key="$1"
    local child_issues=$(acli jira workitem search --jql "\"Epic Link\" = $epic_key OR parent = $epic_key" --json | jq -r '.[].key')
    echo "$child_issues"
}

add_parent_label() {
    local child_key="$1"
    local parent_key="$2"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] Would add 'parentIs$parent_key' label to $child_key"
    else
        echo "  Adding 'parentIs$parent_key' label to $child_key..."
        acli jira workitem edit --key "$child_key" --labels "parentIs$parent_key" --yes
        echo "  ✓ Added label to $child_key"
    fi
}

process_epic() {
    local epic_key="$1"

    if ! is_epic "$epic_key"; then
        echo "Warning: Issue $epic_key is not an Epic, skipping..."
        return
    fi

    echo "Processing Epic: $epic_key"

    local child_issues=$(get_child_issues "$epic_key")

    if [ -z "$child_issues" ]; then
        echo "  No child issues found"
    else
        local count=$(echo "$child_issues" | wc -l | tr -d ' ')
        echo "  Found $count child issue(s)"

        while IFS= read -r child_key; do
            if [ -n "$child_key" ]; then
                add_parent_label "$child_key" "$epic_key"
            fi
        done <<< "$child_issues"
    fi
}

main() {
    check_acli_installed

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

    echo "Parent labels processing completed!"
}

main
