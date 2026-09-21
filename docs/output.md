# Execution output

The executor owns each selected item's start and final result. Modules describe
steps, provide failure reasons, and register follow-up instructions. All modules
use Install and Update, regardless of their implementation.

Each operation starts with `[position/total] Installing: label` or `Updating`.
Labels show only the item's own name, without its category path, throughout
progress messages, results, errors, and follow-up summaries.
Adjacent package-manager items still run in a batch, with a range such as
`[1-3/5]`. Each selected item receives its own result; counts refer to selected
items, not underlying packages. Shared packages are sent to the manager once.

| Result | Meaning |
| --- | --- |
| Installed / Updated | The requested operation finished successfully. |
| No changes | The operation checked the state and did not need to change it. |
| Skipped | The operation was not performed; a reason is required. |
| Failed | The operation did not finish; show the failing step or a specific reason. |
| Not run | Execution stopped before this item was attempted. |

Execution stops on failure and preserves the original exit status. A failed
package transaction is reported as failed for its unfinished items; its message
states that some packages may already have changed. Items previously classified
as skipped or unchanged keep those results.

The final summary counts every selected item exactly once and lists items not
run. Action-required messages are collected during execution and printed once
after the final summary, including when a later item fails. Repeated identical
instructions for the same item are deduplicated. They are follow-up instructions,
not a separate success/failure category.

Zero-count categories are omitted from the summary, except for failures: `0
failed` confirms a successful run. Long batch headings become item lists.

## Module interface

Use these helpers instead of printing status headings or embedding ANSI colors:

```bash
print_step 'Downloading the installer'    # Also sets the failure context.
print_info 'Configuration file preserved'
print_prompt 'New username:'             # No newline; read input separately.
print_action_required 'Sign out and sign in again'
fatal 2 'A required configuration file is missing'
```

`run_checked command args...` stops on a nonzero status and reports the current
step and command name. Its arguments are not added to the error message. Use
`fatal status 'specific reason'` when the cause is known. Native command output
and interactive input remain connected to the terminal.

Returning 0 from an install or update function defaults to Installed or Updated.
For exceptional non-error outcomes, set the result and return 0:

```bash
set_operation_result skipped 'canceled by user'
return 0

set_operation_result unchanged 'the selected account is already current'
return 0
```

The existing update convention is preserved: returning 1 means No changes.
An update failure must use `fatal`, `run_checked`, or return a status above 1;
do not allow a failed command's status 1 to mean No changes accidentally.
Installation checks still return 0 for installed, 1 for not installed, and
another status for errors. They must not print successful operation results.

Result overrides and action-required messages must be registered in the caller's
shell, so they survive until the executor records the result. Subshell workers
may print steps and diagnostics; the caller must collect their return status
and register follow-up instructions. See the Snell wrapper and the create-user
notice file for examples that preserve cleanup and rollback behavior.

## Formatting and streams

Operation headings, progress, prompts, results, and summaries start at the left
margin. Error reasons, follow-up instructions, and wrapped continuation lines
use two spaces. Blank lines separate operations and follow-up blocks. Progress
is cyan, success green, unchanged/skipped gray, failure red, and action-required
messages yellow. Text always identifies the status, even without color.

Status helpers write to stderr and omit color when stderr is not a terminal,
`NO_COLOR` is set, or `TERM=dumb`. Keep stdout for functions returning data and
for native program output. `printf` that generates configuration files, returns
paths, or renders the interactive interface is not a status message and should
retain its original purpose.

Prose wraps at the terminal's current width, preserving indentation on subsequent
lines. When stderr is redirected, `COLUMNS` controls the width (default 80).
Existing newlines are preserved. Put a command on its own line with two leading
spaces in an action-required message; such lines and unbroken paths are left
intact so copying them does not introduce extra newlines. Very long commands or
paths therefore rely on the terminal's own wrapping. Native command output is
also left intact.

Follow-up blocks use a heading such as `Action required: frpc-service`, with
instructions and commands indented by two spaces. Help text wraps into scrollable
rows. The selection tree stays one item per row and uses an
ellipsis for clipped labels while reserving space for group counts; the review
page shows the complete labels. Narrow headers prioritize the current mode.
