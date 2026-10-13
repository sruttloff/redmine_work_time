# WorkTime for Redmine 6.1

WorkTime adds daily time entry and monthly reports to Redmine. Users can record time against issues, review their working month, keep daily notes, and export reports. Project reports summarize time by member, issue, project, and activity.

This fork is maintained for Redmine 6.1 by **[SaaS-Secure.com, S. Ruttloff](https://www.saas-secure.com/)**. It is based on [WorkTime by Tomohisa Kusukawa and contributors](https://github.com/redmine-work-time/redmine_work_time).

**Version: 0.4.5.** Validation environment: Redmine **6.1.2-stable**, Rails **7.2.3**, Ruby **3.3.7**, and MySQL **8.4.11**. The scope and limitations of the release checks are documented in the [validation report](doc/REDMINE_6_1_VALIDATION.md). Other Redmine versions and database adapters have not been validated for this fork. See [NEWS.md](NEWS.md) for release notes.

## Features

- Daily time entry forms and a monthly overview for each user.
- Project and member filters, with separate permissions for viewing and editing other members' time.
- Monthly reports by member, issue, and project, including breakdowns by activity.
- Ticket relays: aggregate reported effort under another issue without moving the original Redmine time entries.
- CSV downloads of individual monthly data, month tables, and project reports.
- Daily notes using Redmine's text formatting.
- Administrator-managed holidays and configurable project accounting periods.
- Translations including English and German; some inherited labels are still English.

## Requirements

- Redmine 6.1 and the Ruby/Rails versions supported by that Redmine release.
- A configured Redmine database and standard time tracking activities.
- A backup of the database and plugin directory before installation or upgrade.

WorkTime has no additional plugin-specific gem dependencies. Its migrations create tables for notes, holidays, ticket relays, and display order; recorded hours remain standard Redmine `TimeEntry` records.

## Installation

Check out the desired published revision in Redmine's plugin directory. The directory must be named exactly `redmine_work_time`:

```sh
cd /path/to/redmine/plugins
git clone --branch v0.4.5 https://github.com/sruttloff/redmine_work_time.git redmine_work_time
cd /path/to/redmine
bundle install
bundle exec rake redmine:plugins:migrate NAME=redmine_work_time RAILS_ENV=production
```

If your installation uses precompiled assets, rebuild them next:

```sh
bundle exec rake assets:precompile RAILS_ENV=production
```

Then restart the Redmine application server using the command appropriate for your deployment, such as Puma under systemd, Passenger, or Docker.

For an upgrade, back up the database and plugin directory, fetch and check out the desired release tag, and repeat the steps for gems, migrations, assets, and restarting the application. Version 0.4.5 introduces no new database migrations.

## Setup

1. Enable **Time tracking** and **WorkTime** under **Project → Settings → Modules**. The WorkTime module may appear as **Zeiterfassung** in German.
2. Under **Administration → Roles and permissions**, grant the required WorkTime permissions:

   | Permission | Purpose |
   | --- | --- |
   | View Work time tab (`view_work_time_tab`) | Access the project's WorkTime view |
   | View other members' work time (`view_work_time_other_member`) | Select project members and access project reports |
   | Edit work time totals (`edit_work_time_total`) | Manage report member order, ticket relays, and the project accounting start day |
   | Edit other members' work time (`edit_work_time_other_member`) | Edit another member's time through WorkTime |

3. Grant standard Redmine permissions such as **View issues**, **View spent time**, **Log spent time**, and the appropriate time entry editing permissions for each role. WorkTime permissions complement the standard Redmine permissions. Editing another member requires both WorkTime's `edit_work_time_other_member` and Redmine's `edit_time_entries`; creating a booking for another member also requires Redmine's `log_time_for_other_users`. Redmine's own-only time visibility remains effective in reports and exports.
4. Under **Administration → Plugins → WorkTime → Configure**, choose whether the personal WorkTime link appears in the account menu.
5. Users with `edit_work_time_total` and a standard permission that gives access to project settings (such as **Edit project**) can set the **Company start day** under **Project → Settings → WorkTime**. The default is `1`; values from `1` to `31` are supported. In shorter months, the start is clamped to the last day of that month. For example, a start day of `31` produces a period from February 28 (29 in a leap year) through March 30.

## Usage

1. Open **WorkTime** in the project menu, or use the personal account menu link for an overview across projects.
2. Select a month and day. Add an issue to the daily table, enter hours, choose an activity, and save with **Update**.
3. Use the project filter to narrow the overview. Users with the relevant permissions can select another member.
4. Add a daily note below the time entry table and navigate between previous and next notes.
5. Open the monthly project report to review member totals. The ticket relay editor can map issues to reporting targets; relayed reports aggregate hours along these mappings.
6. Use the data download links for CSV reports, including individual records, a monthly matrix, and activity breakdowns where available.

Administrators can mark a selected date as a holiday or remove that marker. Holiday markers are plugin-wide rather than personal leave records.

## Changes for Redmine 6.1

- Replace the dynamic controller-action route with explicit routes while preserving existing action URLs.
- Apply the project settings helper patch during Redmine plugin initialization, including development reloads.
- Avoid recursive helper calls when another plugin, such as `redmine_contacts_helpdesk`, wraps project settings tabs.
- Convert rational hour values to decimals for report aggregation and CSV/API output.
- Stop processing after a missing project has returned a 404 response.
- Handle missing issues and missing ticket relay records without nil errors.
- Use Rails' plain-text rendering for the missing-issue error response and remove an unused memo action without a template.

## Validation and development

Version **0.4.5** resolves the authorization, escaping, CSV/API, date, and missing-record defects identified in the [0.4.4 review](doc/FUNCTIONAL_REVIEW_2026_10_13.md). See the [0.4.5 review and release validation](doc/REVIEW_0_4_5.md) for the corrections, tests, and upgrade implications. Explicit changes now require POST with CSRF protection; custom integrations that previously changed data via GET must be updated. The bundled interface handles this automatically.

From a migrated development or test installation with at least one tracker, issue status, and time tracking activity:

```sh
bundle exec rake zeitwerk:check
bundle exec rails runner plugins/redmine_work_time/test/compatibility_smoke.rb
bundle exec rails runner plugins/redmine_work_time/test/workflow_audit.rb
bundle exec rails runner plugins/redmine_work_time/test/reload_smoke.rb
node --check plugins/redmine_work_time/assets/javascripts/work_time.js
```

The compatibility runner covers 42 integration checks. The expanded workflow runner covers 54 authorization, mutation, CSRF, CSV/API, date, cycle, and custom-field checks. Both create temporary records inside rolled-back transactions and disable mail delivery in their process. They refuse to run in production. The reload runner checks three isolated WorkTime initialization cycles without changing the running application. See the [validation report](doc/REDMINE_6_1_VALIDATION.md) for the environment and limits of these checks.

The inherited unit and controller tests can be run in a separate, prepared test database:

```sh
RAILS_ENV=test bundle exec rake redmine:plugins:test NAME=redmine_work_time
```

These inherited tests mostly contain placeholder assertions and are not comprehensive workflow coverage.

## More plugins from SaaS-Secure.com

- **[Redmine UX Toolkit](https://www.saas-secure.com/online-services/redmine-ux-toolkit.html)** – Modern interface, dashboards, checklists, templates, reminders, and administration tools.
- **[SCM Creator for Redmine](https://www.saas-secure.com/online-services/redmine-scm.html)** – Repository management for Git, Subversion, Mercurial, Bazaar, and GitHub.

These plugins are optional additions. For hosting and other services, visit **[www.saas-secure.com](https://www.saas-secure.com/)**.

## Support and credits

For support with this fork, use the contact options at **[SaaS-Secure.com](https://www.saas-secure.com/)**. GitHub Issues are currently disabled in this fork. Include your Redmine, Ruby, Rails, database, and plugin versions, installed plugins, and steps to reproduce the problem.

- Original plugin and upstream maintenance: [Tomohisa Kusukawa and contributors](https://github.com/redmine-work-time/redmine_work_time).
- Redmine 6.1 adaptations and maintenance of this fork: [SaaS-Secure.com, S. Ruttloff](https://www.saas-secure.com/).
- Original plugin listing: [Redmine.org](https://www.redmine.org/plugins/redmine_work_time).

## License

WorkTime includes the **GNU General Public License, version 2**. See [GPL.txt](GPL.txt) for the license text. Original authorship is preserved in the plugin metadata and Git history.
