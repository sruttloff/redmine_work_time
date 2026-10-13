# WorkTime 0.4.5 validation for Redmine 6.1

Release date: 2026-10-13. Version: `0.4.5`, tag: `v0.4.5`.
Baseline: upstream commit `defaa518d19736a44972368dca4ed91078663879`.

The [0.4.5 code review and release validation](REVIEW_0_4_5.md) documents the corrections to all ten findings from the [historical 0.4.4 review](FUNCTIONAL_REVIEW_2026_10_13.md), additional hardening, and the current browser checks.

## Environment

- Redmine 6.1.2-stable, Rails 7.2.3, Ruby 3.3.7.
- MySQL 8.4.11; Linux Docker container, `RAILS_ENV=development`.
- Other locally installed plugins are present, including `redmine_contacts_helpdesk`, which also wraps project settings helpers.
- The existing database already contains all nine WorkTime migrations. This release changes no migrations.

## Verification

Run from the Redmine root in a migrated development or test installation:

```sh
bundle exec rake zeitwerk:check
bundle exec rails runner plugins/redmine_work_time/test/compatibility_smoke.rb
bundle exec rails runner plugins/redmine_work_time/test/workflow_audit.rb
bundle exec rails runner plugins/redmine_work_time/test/reload_smoke.rb
node --check plugins/redmine_work_time/assets/javascripts/work_time.js
```

The Zeitwerk check passes. The compatibility runner passes **42 checks** using actual Rails requests with a temporary non-admin user, role, private project, issue, and a 4.75-hour time entry. It checks:

- Login and rendering of daily/monthly views and project reports.
- An issue without a saved ticket relay and a missing issue in the ticket-add action.
- Plain-text output when the relay action receives no issue ID.
- Decimal hours in individual, matrix, project, relayed, and activity CSV reports.
- Missing-project responses across eleven actions, without double rendering.
- A single WorkTime project settings tab, its default accounting start day, and persistence of a changed start day.
- Explicit routes excluding internal helpers and the removed memo action.

The runner disables mail delivery in its process, rolls back temporary database records, and refuses to run in production. The project settings test grants the standard `edit_project` permission in addition to WorkTime permissions because Redmine authorizes the settings page separately.

The expanded workflow runner passes **54 checks**, including real CSRF protection, forged ownership fields, standard edit permissions, private projects/issues, read-only roles, custom fields, hidden relay targets, all six CSV variants, formula-like text, leap years, and legacy relay cycles. The reload runner verifies one helper patch and the registered version after **three reloads**, isolating this plugin's initialization in its process. JavaScript syntax checks pass.

## Scope and limitations

- Integration checks are complemented by actual integrated-browser checks of booking edits, minute input, ticket insertion, notes, progress updates, relay changes, project settings, and downloads. The browser console was checked for script errors. Every permission combination and deployment has not been exhaustively validated.
- The inherited unit/controller suite mostly contains placeholder assertions. It is retained with upstream's corrected helper and fixture files; it is not a substitute for the compatibility runner.
- Other Redmine versions, databases, and deployments have not been validated locally for this fork.
- Accounting days 1–31 are accepted and clamped to the actual month end. Invalid dates and settings return HTTP 400.
- CSV uses Ruby's serializer and neutralizes formula-like text; encoding continues to follow Redmine's configured locale CSV encoding.
- The review covers the plugin's controller, view/helper output, browser mutations, and regression suite. It is not a guarantee covering every external plugin, concurrent workload, or future Redmine release.

## Repository and release

The local plugin directory is an independent Git repository tracking `origin/main` at `sruttloff/redmine_work_time`. Existing upstream history is preserved. The current upstream's GitHub workflows, Catalan translation, test helpers, and fixtures are retained rather than replaced by older local copies.

The release workflow reads the newest section of `NEWS.md`. Its dependency on an `Announcements` Discussions category was removed because Discussions are disabled in this fork. Automatic release creation requires GitHub Actions to be enabled for the fork; the published Git tag is independent of that setting.
