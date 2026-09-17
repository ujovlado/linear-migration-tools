# Linear Migration Tools

Shell scripts for migrating issues into Linear. Each migration is self-contained — see its README for prerequisites and the step-by-step workflow.

| | |
|---|---|
| [`jira/`](jira/README.md) | Jira → Linear, with the Epic hierarchy preserved through labels and restored on both sides afterwards |
| [`clickup/`](clickup/README.md) | ClickUp → Linear, with comments, attachments, original authors and timestamps |

All scripts need `curl` and `jq`; the Jira ones also need the [Atlassian CLI](https://developer.atlassian.com/cloud/acli/installation/).

## License

MIT — see [LICENSE](LICENSE).
