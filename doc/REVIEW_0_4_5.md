# Code review and release validation: WorkTime 0.4.5

Reviewed on 2026-10-13 against release 0.4.4 (`11b57f8`). Target: Redmine 6.1. The review covers controller actions and callbacks, permissions, model assignment boundaries, report queries, CSV/API serialization, view escaping, JavaScript mutations, project-helper initialization, and the regression tests.

## Findings resolved

All ten findings in the [0.4.4 functional review](FUNCTIONAL_REVIEW_2026_10_13.md) were reproduced and corrected:

| Finding | Correction |
| --- | --- |
| F1: foreign time entries could be edited/deleted | Validate selected user, date, standard `editable_by?`, project visibility, filters, and WorkTime permission before processing any existing entry. Allow only hours, activity, comments, and editable custom values; ignore forged user/project/issue/date fields. |
| F2: another user's note could be overwritten | Resolve the user from the authorized member selection. Direct note editing is limited to the current user. Do not render a hidden editable note field for another member. Append successful manager changes separately after note processing. |
| F3: non-admin global holiday changes | Enforce administrator rights in the server, attribute changes to the authenticated actor, and require POST with CSRF protection. |
| F4: readers could change accounting settings | Assign settings and relay management to `edit_work_time_total` and enforce that permission before saving. |
| F5: hidden relay titles exposed | Check source visibility and hide inaccessible targets. Apply Redmine's time-entry visibility and WorkTime member permissions before report aggregation. |
| F6: stored HTML injection | Render issue labels through escaped helpers; remove raw `html_safe` treatment of issue names in relay and ticket-insertion fragments. Escape validation messages inside their HTML containers. |
| F7: malformed CSV | Use Ruby CSV for all six export variants, including quotes, commas, and text values that could otherwise be interpreted as spreadsheet formulas. |
| F8: API crash on private aggregate | Serialize inaccessible/missing relay targets as `PRIVATE` rather than dereferencing a missing issue. |
| F9: invalid month boundaries | Clamp each accounting boundary independently to its month's last day, including leap years. Validate explicit report dates and accounting settings. |
| F10: stale/missing IDs crashed actions | Validate records before rendering/changes and return controlled 404/400 responses. |

Additional review corrections:

- Require login for AJAX as well as full-page requests. Validate selected members and filters against accessible WorkTime projects.
- Require POST for explicit mutations, including time entries, notes, holidays, ordering, relays, progress, ticket insertion, and settings. Update bundled AJAX/form controls to send CSRF tokens.
- Require `view_work_time_other_member` for project-wide reports and preserve Redmine's own-only time-entry visibility.
- Require both standard and WorkTime permissions for edits to another member; creating another member's entry additionally requires `log_time_for_other_users`.
- Keep issue-field assignment separate from time-entry assignment and validate malformed nested form input.
- Prevent new relay cycles and traverse legacy cycles iteratively instead of recursing indefinitely.
- Correct multi-digit issue IDs in the bulk relay JavaScript and exclude remaining-hours fields from the unsaved time total.
- Keep audit notes only for successful manager writes and retain them when the main form is submitted.

## Validation

Local environment: Redmine 6.1.2-stable, Rails 7.2.3, Ruby 3.3.7, MySQL 8.4.11, Linux Docker, development mode, with the other installed plugins present.

- **42 compatibility checks:** daily/monthly pages, decimal totals, CSV variants, missing projects, project settings, and explicit routes.
- **54 workflow/authorization checks:** expected successful and denied requests, CSRF, forged ownership fields, standard edit permissions, private data, notes, holidays, settings, progress, relays, cycles, CSV/API, month boundaries, malformed forms, and custom fields.
- **Three isolated reloads:** one project-helper patch, correct registered version, and private internal relay helper.
- Zeitwerk loading, JavaScript syntax, and staged whitespace checks.

Both integration runners disable mail delivery, enable CSRF protection, use their own temporary records, and roll back their changes. The CSRF regression deliberately receives HTTP 422 and signs the temporary user in again because Rails resets the session on an invalid token.

Integrated-browser revalidation used separate disposable private projects and employee/manager accounts. Confirmed `2:30` → `2.50` hours, `90m` → `1.50` hours, POST-based ticket insertion, notes with umlauts, a persisted 50% progress update, a relay from a 2.50-hour issue to a reporting target with the overall 4.00-hour total preserved, and a saved accounting start day of 31. No console script errors were observed. The initial 0.4.4 browser review also covered own-entry deletion and invalid negative hours. Browser test data was removed after validation.

## Upgrade notes

- No new database migrations. Rebuild precompiled assets and restart Redmine as described in the README so browser JavaScript and server mutation rules are upgraded together.
- Recheck role assignments: management actions now require explicit management rights, and project-wide reports require the other-member viewing permission.
- Update custom callers that previously changed data with GET to use POST with a valid session CSRF token. The reporting API remains read-only and uses normal Redmine API-key authentication.
- CSV quoting and row ordering can differ from 0.4.4; parse exports as CSV rather than splitting text by commas. Locale-based export encoding is retained.
- Accounting days 29–31 are now supported in short months through clamping rather than causing errors.

No unresolved findings remain in the reviewed changes after the checks above. Other Redmine versions, database adapters, every possible permission/deployment combination, and concurrent administrative workloads are outside the locally validated scope. CI is configured for Redmine 6.1 with Ruby 3.3/3.4 and runs the regression scripts when Actions are enabled for this fork; this report does not claim an unobserved GitHub CI result.
