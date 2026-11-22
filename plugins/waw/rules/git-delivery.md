# Git, GitHub and GitLab

Repositories are reached with plain `git` (the developer's SSH key or credential helper) and
with the forge's CLI: `gh` for GitHub, `glab` for GitLab (self-hosted ones included). The
forge is the host of the `origin` remote. Both CLIs are logged in the way the developer set
them up: do not change remote URLs, do not switch between SSH and HTTPS, do not run
`gh auth login` or `glab auth login`, do not touch keys or credentials.

- Deliver with `deliver.sh`, which the developer allowed without a prompt: `deliver.sh push`
  pushes the current task branch, `deliver.sh mr --title ... --description-file <file>
  [--draft] [--label ...]` pushes it and opens its pull request (GitHub) or merge request
  (GitLab) into the default branch, or prints the open one. It refuses protected branches
  (main, master, develop, release/*, hotfix/*, the default branch, the forge's protected
  list) and never forces. Do not call `git push`, `gh pr create` or `glab mr create`
  directly for this: they prompt. A refusal from deliver.sh is final: tell the developer,
  never look for another way.
- `deliver.sh push`, `mr` and `commit` run git with hooks and fsmonitor disabled: they are
  code the project, or a worker that changed it, controls, and they would run on the host
  with the developer's rights.
- Never create a branch, a commit or a file on the forge another way (the API, an MCP
  connector): the result has other commit ids than the local branch and the two diverge.
- When a fetch, a push or a `gh`/`glab` call fails, stop and show the developer the error.
  Do not look for another way around it. `Permission denied (publickey)`: the SSH agent
  offers no key for the host (`ssh-add -l`). `401`: the CLI's token expired
  (`gh auth status`, `glab auth status`); the developer renews it.
- Never merge a pull or merge request (`gh pr merge`, `glab mr merge`). The developer merges.
  The push guard blocks both.
- The forge is the commander's: workers never push, open or comment on pull or merge
  requests (their guard blocks it).

The skills (ship, auto-pilot) name `gh`. In a GitLab repository use `glab`:

| The skill says | On GitLab |
|----------------|-----------|
| `gh issue view <ref> --comments` | `glab issue view <ref> --comments` |
| `gh pr create` (the body is the report) | write the body to `.ship/<slug>/mr.md`, then `deliver.sh mr --title "..." --description-file .ship/<slug>/mr.md` (it pushes first) |
| `gh pr create --draft` | the same with `--draft` |
| `git push` of the task branch | `deliver.sh push` |
| `gh pr checks --watch` | `glab ci status --live`, then `glab ci status` for the result of every job |
| the comments of the pull request | `glab mr view <iid> --comments` (`--unresolved` for the open threads); threads on code lines: `glab api "projects/:fullpath/merge_requests/<iid>/discussions"` |
| a failed job's log | `glab ci trace <job>` |
| `gh issue create` (a checklist) | `glab issue create --title ... --description ...` |

On GitHub, `gh pr create` in the skills also means `deliver.sh mr`, with the same arguments.

The default branch is not always `main` (some projects use `develop`): take it from
`gh repo view --json defaultBranchRef`, `glab repo view -F json` (`default_branch`) or
`git symbolic-ref refs/remotes/origin/HEAD`.

A project may have its own skill or instruction for delivering, written for another setup:
one that goes through an MCP connector, or that asks the developer to push by hand. Its way
of delivering does not apply: push with `git` and use `deliver.sh`, `gh` or `glab`, as above.
What it says about the content still applies: the template of the pull or merge request,
the form of the title and the description, labels, reviewers. This is settled here, so it is
not a decision to report.

When the task has a ticket key (Jira and the like), it is named in the branch
(`feat/PROJ-586_...` is PROJ-586).
