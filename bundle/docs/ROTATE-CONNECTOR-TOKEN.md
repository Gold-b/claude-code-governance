# Replace the connector token with a fine-grained, single-repo PAT

Why: the connector currently carries the gh CLI's own OAuth token, which can reach every repo the
account can. A fine-grained token can be limited to one repository and the four permissions this
flow actually uses. Browser only — GitHub has no API for creating personal access tokens.

Time: about 3 minutes. Nothing breaks while you do it; the old token keeps working until you
replace the header.

## 1. Create the token

1. Open https://github.com/settings/personal-access-tokens/new
2. **Token name:** `claude-pr-follow-through`
3. **Expiration:** 90 days (put a calendar reminder for day 85)
4. **Resource owner:** pick the ORGANISATION that owns the repo, not your personal account.
   - If the organisation is missing from the list, it has not enabled fine-grained tokens.
     Stop here and use a classic token instead: https://github.com/settings/tokens/new with the
     single scope `repo`. Everything else below is the same.
5. **Repository access:** *Only select repositories* → choose the one repo.
6. **Permissions → Repository permissions**, set exactly these four and leave everything else "No access":

   | Permission | Level | Why |
   |---|---|---|
   | Pull requests | Read and write | read PRs, post the reminder comment, update the hidden state block |
   | Issues | Read and write | a PR comment is an issue comment in the API |
   | Contents | Read-only | read the branch and CI state |
   | Metadata | Read-only | mandatory, GitHub selects it for you |

7. **Generate token** → copy it now. GitHub shows it exactly once.
8. If the organisation requires approval, the token appears as "pending" until an org owner
   approves it. It will return 403 until then.

## 2. Put it in the connector

1. https://claude.ai/customize/connectors → the GitHub custom connector → Edit
2. Under **Additional request headers**, replace the `Authorization` header value with:
   `Bearer <the new token>`
   (one space after `Bearer`; the old value is write-only, so just overwrite it)
3. Save.

## 3. Verify before you throw the old token away

Ask Claude in a session: *"run PR follow-through routine A once and show me the run log"*.
The log must show a successful `list_pull_requests` on the tracked repo. If it shows 401 or 403,
the token is wrong, not approved yet, or missing a permission — fix that before step 4.

## 4. Clean up

1. Update this machine's copy: in `~/.claude/.governance-local.env`, replace the value of
   `GITHUB_MCP_CONNECTOR_TOKEN` with the new token (the file is local-only and never synced).
2. Revoke nothing else: the gh CLI token stays as it is, because `gh` on this machine and the
   `pr-watch.sh` watcher use it. You are only removing it from the cloud connector.

## If you ever need to undo

Put the old value back in the connector header. It is still in
`~/.claude/.governance-local.env` until you overwrite it in step 4.1 — so do step 4.1 last, and
only after the verification in step 3 passed.
