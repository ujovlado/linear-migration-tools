#!/bin/bash

set -e

source "$(dirname "$0")/lib.sh"

LINEAR_TEAM=""
CLICKUP_LIST_IDS=""
OPEN_ONLY=false

MIGRATED_LABEL="Migrated"

# Attachments larger than this are reported instead of uploaded
MAX_ATTACHMENT_BYTES="${MAX_ATTACHMENT_BYTES:-104857600}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --open-only)
            OPEN_ONLY=true
            shift
            ;;
        *)
            if [ -z "$LINEAR_TEAM" ]; then
                LINEAR_TEAM="$1"
            elif [ -z "$CLICKUP_LIST_IDS" ]; then
                CLICKUP_LIST_IDS="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$LINEAR_TEAM" ] || [ -z "$CLICKUP_LIST_IDS" ]; then
    echo "Usage: $0 <linear-team-key-or-id> <clickup-list-ids> [--open-only]"
    echo "Example: $0 ENG 901234567890"
    echo "Example: $0 ENG 901234567890,901234567891"
    echo "Example: $0 ENG 901234567890 --open-only"
    echo ""
    echo "  --open-only  Skip tasks whose status is done or closed"
    echo ""
    echo "Run ./get-clickup-lists.sh to find list IDs."
    exit 1
fi

TEAM_ID=""
TEAM_NAME=""
STATES_JSON=""
MEMBERS_JSON=""
MIGRATED_LABEL_ID=""

ISSUES_CREATED=0
COMMENTS_CREATED=0
ATTACHMENTS_UPLOADED=0
FAILURES=0

# Temp state: label cache, ClickUp id -> Linear id, and the end-of-run report
LABEL_MAP=$(map_create)
ID_MAP=$(map_create)
UNMATCHED_ASSIGNEES=$(mktemp)
FALLBACK_STATUSES=$(mktemp)
SKIPPED_ATTACHMENTS=$(mktemp)
TASKS_FILE=$(mktemp)

trap 'rm -f "$LABEL_MAP" "$ID_MAP" "$UNMATCHED_ASSIGNEES" "$FALLBACK_STATUSES" "$SKIPPED_ATTACHMENTS" "$TASKS_FILE"' EXIT

TEAM_BY_KEY_QUERY='
query($key: String!) {
  teams(filter: { key: { eq: $key } }, first: 1) {
    nodes {
      id
      key
      name
      states(first: 100) { nodes { id name type position } }
      labels(first: 250) { nodes { id name } }
      members(first: 250) { nodes { id name email active } }
    }
  }
}'

TEAM_BY_ID_QUERY='
query($id: String!) {
  team(id: $id) {
    id
    key
    name
    states(first: 100) { nodes { id name type position } }
    labels(first: 250) { nodes { id name } }
    members(first: 250) { nodes { id name email active } }
  }
}'

LABEL_CREATE_MUTATION='
mutation($input: IssueLabelCreateInput!) {
  issueLabelCreate(input: $input) {
    success
    issueLabel { id name }
  }
}'

LABEL_LOOKUP_QUERY='
query($name: String!) {
  issueLabels(filter: { name: { eq: $name } }, first: 1) {
    nodes { id name }
  }
}'

ISSUE_CREATE_MUTATION='
mutation($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue { id identifier url }
  }
}'

COMMENT_CREATE_MUTATION='
mutation($input: CommentCreateInput!) {
  commentCreate(input: $input) {
    success
    comment { id }
  }
}'

ATTACHMENT_CREATE_MUTATION='
mutation($input: AttachmentCreateInput!) {
  attachmentCreate(input: $input) {
    success
    attachment { id }
  }
}'

# Fetch the team plus everything needed to map onto it in one request. The
# argument is accepted as either a team key (ENG) or a team UUID.
resolve_team() {
    local key="$1"

    local response
    local team=""

    response=$(linear_api_call "$TEAM_BY_KEY_QUERY" "$(jq -n --arg key "$key" '{key: $key}')")
    team=$(echo "$response" | jq -c '.data.teams.nodes[0] // empty')

    if [ -z "$team" ]; then
        response=$(linear_api_call "$TEAM_BY_ID_QUERY" "$(jq -n --arg id "$key" '{id: $id}')" 2>/dev/null) || response=""
        if [ -n "$response" ]; then
            team=$(echo "$response" | jq -c '.data.team // empty')
        fi
    fi

    if [ -z "$team" ]; then
        echo "Error: no Linear team found with key or id: $key"
        exit 1
    fi

    TEAM_ID=$(echo "$team" | jq -r '.id')
    TEAM_NAME=$(echo "$team" | jq -r '.name')
    STATES_JSON=$(echo "$team" | jq -c '.states.nodes')
    MEMBERS_JSON=$(echo "$team" | jq -c '.members.nodes')

    echo "$team" | jq -r '.labels.nodes[] | [(.name | ascii_downcase), .id] | @tsv' >> "$LABEL_MAP"
}

# Find a Linear label by name, creating it on the team when it does not exist
resolve_label() {
    local name="$1"
    local key=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')

    local id=$(map_get "$LABEL_MAP" "$key")
    if [ -n "$id" ]; then
        echo "$id"
        return 0
    fi

    local vars=$(jq -n --arg name "$name" --arg teamId "$TEAM_ID" '{input: {name: $name, teamId: $teamId}}')
    local response
    response=$(linear_api_call "$LABEL_CREATE_MUTATION" "$vars" 2>/dev/null) || response=""
    id=$(echo "$response" | jq -r '.data.issueLabelCreate.issueLabel.id // empty' 2>/dev/null)

    # Creation fails when a label of that name already exists at workspace scope
    if [ -z "$id" ]; then
        response=$(linear_api_call "$LABEL_LOOKUP_QUERY" "$(jq -n --arg name "$name" '{name: $name}')" 2>/dev/null) || response=""
        id=$(echo "$response" | jq -r '.data.issueLabels.nodes[0].id // empty' 2>/dev/null)
    fi

    if [ -n "$id" ]; then
        map_put "$LABEL_MAP" "$key" "$id"
    fi

    echo "$id"
}

# Map a ClickUp status onto a Linear workflow state: match the name first, then
# fall back to the ClickUp status type.
resolve_state() {
    local status_name="$1"
    local status_type="$2"

    local id=$(echo "$STATES_JSON" | jq -r --arg name "$status_name" \
        '[.[] | select((.name | ascii_downcase) == ($name | ascii_downcase)) | .id] | first // empty')

    if [ -n "$id" ]; then
        echo "$id"
        return 0
    fi

    local linear_type
    case "$status_type" in
        open)        linear_type="unstarted" ;;
        custom)      linear_type="started" ;;
        done|closed) linear_type="completed" ;;
        *)           linear_type="unstarted" ;;
    esac

    id=$(echo "$STATES_JSON" | jq -r --arg type "$linear_type" \
        '[.[] | select(.type == $type)] | sort_by(.position) | [.[].id] | first // empty')

    # Teams without a Todo state still have a backlog
    if [ -z "$id" ] && [ "$linear_type" = "unstarted" ]; then
        id=$(echo "$STATES_JSON" | jq -r \
            '[.[] | select(.type == "backlog")] | sort_by(.position) | [.[].id] | first // empty')
    fi

    local state_name=$(echo "$STATES_JSON" | jq -r --arg id "$id" '[.[] | select(.id == $id) | .name] | first // "team default"')
    printf '%s\t%s\n' "$status_name" "$state_name" >> "$FALLBACK_STATUSES"

    echo "$id"
}

# Match a ClickUp assignee onto an active Linear team member by email
resolve_assignee() {
    local email="$1"

    if [ -z "$email" ]; then
        return 0
    fi

    echo "$MEMBERS_JSON" | jq -r --arg email "$email" \
        '[.[] | select(.active == true and ((.email // "") | ascii_downcase) == ($email | ascii_downcase)) | .id] | first // empty'
}

# Collect every ClickUp tag as a Linear label id, always including Migrated
resolve_task_labels() {
    local task="$1"

    local ids="[\"$MIGRATED_LABEL_ID\"]"

    while IFS= read -r tag; do
        if [ -n "$tag" ]; then
            local label_id=$(resolve_label "$tag")
            if [ -n "$label_id" ]; then
                ids=$(jq -n --argjson ids "$ids" --arg id "$label_id" '$ids + [$id]')
            fi
        fi
    done <<< "$(echo "$task" | jq -r '.tags[]?.name')"

    echo "$ids" | jq -c 'unique'
}

# Page through a ClickUp list, appending one task per line to $TASKS_FILE
fetch_list_tasks() {
    local list_id="$1"
    local page=0
    local before=$(wc -l < "$TASKS_FILE" | tr -d ' ')

    while :; do
        local response
        # include_closed only covers ClickUp's Closed status, not done-type
        # statuses, so --open-only also filters on status type after fetching
        local include_closed="true"
        if [ "$OPEN_ONLY" = true ]; then
            include_closed="false"
        fi

        response=$(clickup_api_call "/list/${list_id}/task?page=${page}&include_closed=${include_closed}&subtasks=true&include_markdown_description=true")

        echo "$response" | jq -c '.tasks[]?' >> "$TASKS_FILE"

        # Not `.last_page // true` - jq's // treats false as empty
        local last_page=$(echo "$response" | jq -r 'if has("last_page") then .last_page else true end')
        if [ "$last_page" = "true" ]; then
            break
        fi
        page=$((page + 1))
    done

    local after=$(wc -l < "$TASKS_FILE" | tr -d ' ')
    echo "Found $((after - before)) task(s) in list $list_id"
}

# Pull every comment on a task, including threaded replies, oldest first
collect_comments() {
    local task_id="$1"

    local all='[]'
    local start=""
    local start_id=""

    while :; do
        local path="/task/${task_id}/comment"
        if [ -n "$start" ]; then
            path="${path}?start=${start}&start_id=${start_id}"
        fi

        local response
        response=$(clickup_api_call "$path") || return 1

        local batch=$(echo "$response" | jq -c '.comments // []')
        local count=$(echo "$batch" | jq 'length')

        if [ "$count" = "0" ]; then
            break
        fi

        all=$(jq -n --argjson all "$all" --argjson batch "$batch" '$all + $batch')

        # ClickUp returns 25 comments per page
        if [ "$count" -lt 25 ]; then
            break
        fi

        start=$(echo "$batch" | jq -r '.[-1].date')
        start_id=$(echo "$batch" | jq -r '.[-1].id')
    done

    local normalized=$(echo "$all" | jq -c '[.[] | {
        date: (.date | tonumber),
        body: ((.comment_text // "") | if test("\\S") then . else "_(no text content)_" end),
        user: (.user.username // ""),
        icon: (.user.profilePicture // "")
    }]')

    # Replies live behind their own endpoint
    while IFS= read -r comment_id; do
        if [ -n "$comment_id" ]; then
            local response
            response=$(clickup_api_call "/comment/${comment_id}/reply") || continue
            local replies=$(echo "$response" | jq -c '[(.comments // [])[] | {
                date: (.date | tonumber),
                body: ("↳ " + ((.comment_text // "") | if test("\\S") then . else "_(no text content)_" end)),
                user: (.user.username // ""),
                icon: (.user.profilePicture // "")
            }]')
            normalized=$(jq -n --argjson a "$normalized" --argjson b "$replies" '$a + $b')
        fi
    done <<< "$(echo "$all" | jq -r '.[] | select(((.reply_count // "0") | tonumber) > 0) | .id')"

    echo "$normalized" | jq -c 'sort_by(.date)'
}

# Recreate a task's comments on the imported issue, preserving author and date
import_comments() {
    local issue_id="$1"
    local task_id="$2"

    local comments
    comments=$(collect_comments "$task_id") || return 0

    local count=$(echo "$comments" | jq 'length')
    if [ "$count" = "0" ]; then
        return 0
    fi

    local created=0
    while IFS= read -r comment; do
        if [ -z "$comment" ]; then
            continue
        fi

        local created_at=$(to_iso "$(echo "$comment" | jq -r '.date')")
        local vars=$(jq -n --argjson c "$comment" --arg issueId "$issue_id" --arg createdAt "$created_at" \
            '{input: ({issueId: $issueId, body: $c.body}
                + (if $createdAt == "" then {} else {createdAt: $createdAt} end)
                + (if $c.user == "" then {} else {createAsUser: $c.user} end)
                + (if $c.icon == "" then {} else {displayIconUrl: $c.icon} end))}')

        if linear_api_call "$COMMENT_CREATE_MUTATION" "$vars" > /dev/null; then
            created=$((created + 1))
        fi
    done <<< "$(echo "$comments" | jq -c '.[]')"

    COMMENTS_CREATED=$((COMMENTS_CREATED + created))
    echo "    ✓ $created comment(s)"
}

# Put a link back to the ClickUp task in the issue's Links section. Linear treats
# the url as idempotent per issue, so re-running updates instead of duplicating.
link_clickup_task() {
    local issue_id="$1"
    local url="$2"
    local title="$3"

    if [ -z "$url" ]; then
        return 0
    fi

    local vars=$(jq -n --arg issueId "$issue_id" --arg url "$url" --arg title "$title" \
        '{input: {issueId: $issueId, title: "ClickUp", subtitle: $title, url: $url}}')

    linear_api_call "$ATTACHMENT_CREATE_MUTATION" "$vars" > /dev/null || true
}

# Copy one ClickUp attachment into Linear's own storage and link it on the issue
upload_attachment() {
    local issue_id="$1"
    local attachment="$2"

    local title=$(echo "$attachment" | jq -r '.title // "attachment"')
    local mimetype=$(echo "$attachment" | jq -r '.mimetype // "application/octet-stream"')
    local source_url=$(echo "$attachment" | jq -r '.url_w_query // .url // ""')
    local size=$(echo "$attachment" | jq -r '.size // 0')

    if [ -z "$source_url" ]; then
        return 1
    fi

    case "$size" in
        ''|*[!0-9]*) size=0 ;;
    esac

    if [ "$size" -gt "$MAX_ATTACHMENT_BYTES" ]; then
        printf '%s\t%s\n' "$title" "larger than $MAX_ATTACHMENT_BYTES bytes" >> "$SKIPPED_ATTACHMENTS"
        return 1
    fi

    local file=$(mktemp)

    if ! download_attachment "$source_url" "$file"; then
        printf '%s\t%s\n' "$title" "could not be downloaded from ClickUp" >> "$SKIPPED_ATTACHMENTS"
        rm -f "$file"
        return 1
    fi

    local asset_url
    asset_url=$(linear_upload_file "$file" "$title" "$mimetype") || {
        printf '%s\t%s\n' "$title" "upload to Linear failed" >> "$SKIPPED_ATTACHMENTS"
        rm -f "$file"
        return 1
    }
    rm -f "$file"

    local vars=$(jq -n --arg issueId "$issue_id" --arg title "$title" --arg url "$asset_url" \
        '{input: {issueId: $issueId, title: $title, url: $url}}')

    linear_api_call "$ATTACHMENT_CREATE_MUTATION" "$vars" > /dev/null || return 1
}

# Re-upload a task's attachments so they outlive the ClickUp workspace
import_attachments() {
    local issue_id="$1"
    local task="$2"
    local task_id="$3"

    local attachments=$(echo "$task" | jq -c '.attachments // empty')

    # The list endpoint does not always include attachments - ask for the task itself
    if [ -z "$attachments" ]; then
        local response
        response=$(clickup_api_call "/task/${task_id}") || return 0
        attachments=$(echo "$response" | jq -c '.attachments // []')
    fi

    local pending=$(echo "$attachments" | jq -c '[.[] | select((.deleted // false) == false and (.is_folder // false) == false)]')

    if [ "$(echo "$pending" | jq 'length')" = "0" ]; then
        return 0
    fi

    local uploaded=0
    while IFS= read -r attachment; do
        if [ -n "$attachment" ] && upload_attachment "$issue_id" "$attachment"; then
            uploaded=$((uploaded + 1))
        fi
    done <<< "$(echo "$pending" | jq -c '.[]')"

    ATTACHMENTS_UPLOADED=$((ATTACHMENTS_UPLOADED + uploaded))
    if [ "$uploaded" -gt 0 ]; then
        echo "    ✓ $uploaded attachment(s)"
    fi
}

# Create one Linear issue from one ClickUp task
import_task() {
    local task="$1"
    local parent_id="$2"

    local clickup_id=$(echo "$task" | jq -r '.id')
    local title=$(echo "$task" | jq -r '.name')
    local url=$(echo "$task" | jq -r '.url // ""')

    local created_at=$(to_iso "$(echo "$task" | jq -r '.date_created')")

    local due_date=""
    local due_ms=$(echo "$task" | jq -r '.due_date // empty')
    if [ -n "$due_ms" ]; then
        due_date=$(to_date "$due_ms")
    fi

    local state_id=$(resolve_state \
        "$(echo "$task" | jq -r '.status.status // ""')" \
        "$(echo "$task" | jq -r '.status.type // ""')")

    local assignee_email=$(echo "$task" | jq -r '.assignees[0].email // ""')
    local assignee_name=$(echo "$task" | jq -r '.assignees[0].username // ""')
    local assignee_id=$(resolve_assignee "$assignee_email")

    # The link back to ClickUp lives in the issue's Links section, not the body
    local footer=""

    if [ -n "$assignee_name" ] && [ -z "$assignee_id" ]; then
        footer="

---
*Original ClickUp assignee: $assignee_name*"
        printf '%s\t%s\n' "$assignee_name" "$assignee_email" >> "$UNMATCHED_ASSIGNEES"
    fi

    local description="$(echo "$task" | jq -r '.markdown_description // .description // ""')$footer"
    local label_ids=$(resolve_task_labels "$task")

    local input=$(jq -n \
        --argjson task "$task" \
        --arg teamId "$TEAM_ID" \
        --arg description "$description" \
        --arg createdAt "$created_at" \
        --arg dueDate "$due_date" \
        --arg stateId "$state_id" \
        --arg assigneeId "$assignee_id" \
        --arg parentId "$parent_id" \
        --argjson labelIds "$label_ids" \
        '{
            teamId: $teamId,
            title: $task.name,
            description: $description,
            labelIds: $labelIds,
            priority: (if ($task.priority | type) == "object" then ($task.priority.id | tonumber) else 0 end)
        }
        + (if $createdAt == ""  then {} else {createdAt: $createdAt} end)
        + (if $dueDate == ""    then {} else {dueDate: $dueDate} end)
        + (if $stateId == ""    then {} else {stateId: $stateId} end)
        + (if $assigneeId == "" then {} else {assigneeId: $assigneeId} end)
        + (if $parentId == ""   then {} else {parentId: $parentId} end)
        + (if ($task.creator.username // "") == ""       then {} else {createAsUser: $task.creator.username} end)
        + (if ($task.creator.profilePicture // "") == "" then {} else {displayIconUrl: $task.creator.profilePicture} end)')

    local response
    response=$(linear_api_call "$ISSUE_CREATE_MUTATION" "$(jq -n --argjson input "$input" '{input: $input}')") || {
        echo "  ✗ $title"
        FAILURES=$((FAILURES + 1))
        return 0
    }

    local success=$(echo "$response" | jq -r '.data.issueCreate.success')
    if [ "$success" != "true" ]; then
        echo "  ✗ $title"
        FAILURES=$((FAILURES + 1))
        return 0
    fi

    local issue_id=$(echo "$response" | jq -r '.data.issueCreate.issue.id')
    local identifier=$(echo "$response" | jq -r '.data.issueCreate.issue.identifier')

    map_put "$ID_MAP" "$clickup_id" "$issue_id"
    ISSUES_CREATED=$((ISSUES_CREATED + 1))
    echo "  ✓ $identifier $title"

    link_clickup_task "$issue_id" "$url" "$title"
    import_attachments "$issue_id" "$task" "$clickup_id"
    import_comments "$issue_id" "$clickup_id"
}

# Import in passes so that a subtask is always created after its parent and can
# be linked to it. Tasks whose parent is outside the imported lists end up flat.
import_tasks() {
    local pending="$1"

    while [ -s "$pending" ]; do
        local next=$(mktemp)
        local progress=0

        while IFS= read -r task; do
            if [ -z "$task" ]; then
                continue
            fi

            local clickup_parent=$(echo "$task" | jq -r '.parent // empty')
            local parent_id=""

            if [ -n "$clickup_parent" ]; then
                parent_id=$(map_get "$ID_MAP" "$clickup_parent")
                if [ -z "$parent_id" ]; then
                    echo "$task" >> "$next"
                    continue
                fi
            fi

            import_task "$task" "$parent_id"
            progress=$((progress + 1))
        done < "$pending"

        rm -f "$pending"
        pending="$next"

        if [ "$progress" -eq 0 ]; then
            while IFS= read -r task; do
                if [ -n "$task" ]; then
                    echo "  ! $(echo "$task" | jq -r '.name'): parent is not in the imported lists, creating without one"
                    import_task "$task" ""
                fi
            done < "$pending"
            rm -f "$pending"
            break
        fi
    done
}

print_summary() {
    echo ""
    echo "Created $ISSUES_CREATED issue(s), $COMMENTS_CREATED comment(s) and $ATTACHMENTS_UPLOADED attachment(s) in $TEAM_NAME"

    if [ "$FAILURES" -gt 0 ]; then
        echo "$FAILURES issue(s) failed to import"
    fi

    if [ -s "$SKIPPED_ATTACHMENTS" ]; then
        echo ""
        echo "Attachments that were not migrated (still available in ClickUp):"
        sort -u "$SKIPPED_ATTACHMENTS" | while IFS=$'\t' read -r name reason; do
            echo "  - $name: $reason"
        done
    fi

    if [ -s "$UNMATCHED_ASSIGNEES" ]; then
        echo ""
        echo "ClickUp assignees with no matching Linear user (left unassigned):"
        sort -u "$UNMATCHED_ASSIGNEES" | while IFS=$'\t' read -r name email; do
            echo "  - $name <$email>"
        done
    fi

    if [ -s "$FALLBACK_STATUSES" ]; then
        echo ""
        echo "ClickUp statuses with no matching Linear state (mapped by type):"
        sort -u "$FALLBACK_STATUSES" | while IFS=$'\t' read -r status state; do
            echo "  - $status -> $state"
        done
    fi

    echo ""
    echo "Import completed! Filter the team by the \"$MIGRATED_LABEL\" label to see everything imported."
}

main() {
    check_deps
    check_clickup_config
    check_linear_config

    resolve_team "$LINEAR_TEAM"
    echo "Importing into Linear team: $TEAM_NAME"

    MIGRATED_LABEL_ID=$(resolve_label "$MIGRATED_LABEL")
    if [ -z "$MIGRATED_LABEL_ID" ]; then
        echo "Error: could not find or create the \"$MIGRATED_LABEL\" label"
        exit 1
    fi

    for list_id in $(echo "$CLICKUP_LIST_IDS" | tr ',' ' '); do
        fetch_list_tasks "$list_id"
    done

    # subtasks=true can return a task that another page already listed
    local deduped=$(mktemp)
    jq -s -c --argjson openOnly "$OPEN_ONLY" '
        unique_by(.id)
        | (if $openOnly
           then map(select((.status.type // "") != "done" and (.status.type // "") != "closed"))
           else . end)
        | sort_by((.date_created // "0") | tonumber)
        | .[]' < "$TASKS_FILE" > "$deduped"

    local count=$(wc -l < "$deduped" | tr -d ' ')
    if [ "$count" = "0" ]; then
        echo "No tasks found"
        rm -f "$deduped"
        exit 0
    fi

    if [ "$OPEN_ONLY" = true ]; then
        local total=$(jq -s 'unique_by(.id) | length' < "$TASKS_FILE")
        echo "Importing $count task(s), skipping $((total - count)) done/closed"
    else
        echo "Importing $count task(s)"
    fi
    echo ""

    import_tasks "$deduped"
    print_summary
}

main
