#!/bin/bash

set -e

source "$(dirname "$0")/lib.sh"

# Print every list in a folder
print_folder_lists() {
    local folder_id="$1"
    local prefix="$2"

    local response=$(clickup_api_call "/folder/${folder_id}/list?archived=false")

    echo "$response" | jq -r --arg prefix "$prefix" \
        '.lists[]? | [.id, "\($prefix) / \(.name) (\(.task_count // 0) tasks)"] | @tsv'
}

# Print every list in a space that is not inside a folder
print_folderless_lists() {
    local space_id="$1"
    local prefix="$2"

    local response=$(clickup_api_call "/space/${space_id}/list?archived=false")

    echo "$response" | jq -r --arg prefix "$prefix" \
        '.lists[]? | [.id, "\($prefix) / \(.name) (\(.task_count // 0) tasks)"] | @tsv'
}

process_space() {
    local space_id="$1"
    local prefix="$2"

    local folders=$(clickup_api_call "/space/${space_id}/folder?archived=false")

    while IFS=$'\t' read -r folder_id folder_name; do
        if [ -n "$folder_id" ]; then
            print_folder_lists "$folder_id" "$prefix / $folder_name"
        fi
    done <<< "$(echo "$folders" | jq -r '.folders[]? | [.id, .name] | @tsv')"

    print_folderless_lists "$space_id" "$prefix"
}

process_workspace() {
    local team_id="$1"
    local team_name="$2"

    echo "Reading workspace: $team_name" >&2

    local spaces=$(clickup_api_call "/team/${team_id}/space?archived=false")

    while IFS=$'\t' read -r space_id space_name; do
        if [ -n "$space_id" ]; then
            process_space "$space_id" "$team_name / $space_name"
        fi
    done <<< "$(echo "$spaces" | jq -r '.spaces[]? | [.id, .name] | @tsv')"
}

main() {
    check_deps
    check_clickup_config

    local teams=$(clickup_api_call "/team")

    local count=$(echo "$teams" | jq '.teams | length')
    if [ "$count" = "0" ]; then
        echo "No workspaces found for this token" >&2
        exit 1
    fi

    while IFS=$'\t' read -r team_id team_name; do
        if [ -n "$team_id" ]; then
            process_workspace "$team_id" "$team_name"
        fi
    done <<< "$(echo "$teams" | jq -r '.teams[] | [.id, .name] | @tsv')"

    echo "" >&2
    echo "Pass a list ID to ./import-to-linear.sh" >&2
}

main
