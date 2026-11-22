# Jira tickets: read everything, including the attachments

When the task is a Jira ticket (a key such as `PROJ-586`, or a Jira URL), the ticket is the
whole request. QA and the reporter put the decisive facts in screenshots and videos, not in the
text. Do not plan, write or declare anything done before you have read all of it.

Read, in this order, through the Atlassian connector:

1. The issue with its attachments: `getJiraIssue` returns a compact view that leaves
   attachments out, so ask for them: `fields: ["attachment", ...]` (or a view that includes
   them). Do not conclude "no attachments" from a response that did not ask for the field.
2. Every comment (`listJiraIssueComments`). QA often adds the screenshot in a later comment.
3. Linked issues and the parent (`issuelinks`, `parent`), when the ticket points at them.

Attachments:

- Download every image and every video/GIF with `downloadJiraIssueAttachment` (through
  `executeRead`), which returns a shell command: run it, saving into the run files
  (`.ship/<slug>/attachments/`, never committed), then open each image with the Read tool and
  look at it. A file name or a size is not looking.
- Images pasted inline in the description or a comment appear there as media UUIDs, not as
  numeric attachment ids. Match them to the attachment list; if one cannot be matched, say so.
- A video or a GIF: take frames (`ffmpeg`, install it when missing) and read them. If you
  cannot view one, say that; do not skip it silently.
- Other files (logs, HAR, crash reports, spreadsheets): read them too when they can bear on
  the cause.

Use them:

- In the plan, state what the screenshots show in one line each, and which of them an
  acceptance criterion comes from. A bug ticket's screenshot shows the failing state: the
  proof of the fix is the same screen showing the correct state.
- When the text and a screenshot disagree, the screenshot is the observed behaviour. Say so
  and follow it, or ask when it changes what the product does.
- If a download is blocked or an attachment cannot be opened, stop and tell the developer
  which one. Do not go on without it and do not guess what it shows.

Hand them to the workers: they have no connectors. Save the ticket's text, every comment and
the linked issues as `.ship/<slug>/context/<KEY>.md`, keep the attachments (and the frames of
videos) in `.ship/<slug>/attachments/`, and list both, with one line per screenshot of what it
shows, in the investigator's and the tester's briefs.

In the report, list what you read: "Attachments read: N of N (names)", plus the comments.
