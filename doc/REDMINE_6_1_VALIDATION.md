# WorkTime 0.4.4 validation for Redmine 6.1

Release date: 2026-10-13. Version: `0.4.4`, tag: `v0.4.4`.
Baseline: upstream commit `defaa518d19736a44972368dca4ed91078663879`.

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

## Scope and limitations

- These are Rails integration checks, not browser interaction tests. JavaScript editing, drag and drop, daily notes, holiday administration, and every permission combination have not been exhaustively validated in this release.
- The inherited unit/controller suite mostly contains placeholder assertions. It is retained with upstream's corrected helper and fixture files; it is not a substitute for the compatibility runner.
- Other Redmine versions, databases, and deployments have not been validated locally for this fork.
- Accounting start days 29 through 31 can fail in shorter months because the inherited date calculation does not clamp them. Use days 1 through 28 when the period must work throughout the year.
- CSV serialization is inherited. This release verifies decimal hour values; it does not redesign quoting, spreadsheet formula handling, or export encoding.
- This release publishes the existing local compatibility fixes. It is not a comprehensive security or authorization audit of the inherited plugin.

## Repository and release

The local plugin directory is an independent Git repository tracking `origin/main` at `sruttloff/redmine_work_time`. Existing upstream history is preserved. The current upstream's GitHub workflows, Catalan translation, test helpers, and fixtures are retained rather than replaced by older local copies.

The release workflow reads the newest section of `NEWS.md`. Its dependency on an `Announcements` Discussions category was removed because Discussions are disabled in this fork. Automatic release creation requires GitHub Actions to be enabled for the fork; the published Git tag is independent of that setting.
