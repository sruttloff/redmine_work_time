# WorkTime

## 0.4.5 - 2026-10-13

### Authorization, security, and correctness review

* Enforce login, WorkTime module permissions, member scope, and Redmine time-entry visibility across pages, AJAX, CSV, and the reporting API.
* Validate time-entry ownership, date, visibility, and standard edit permissions before writes; ignore forged ownership, project, issue, and date fields.
* Require management permissions for accounting settings and relay editing, and administrator rights for global holidays.
* Restrict daily note changes to the selected authorized user; preserve successful manager edits in audit notes without exposing hidden memo fields.
* Require POST and valid CSRF tokens for explicit changes; update AJAX, ordering, deletion, and holiday controls accordingly.
* Escape ticket labels and validation errors; anonymize hidden relay targets in reports and the API.
* Generate all CSV exports with proper quoting and protect formula-like text cells.
* Clamp accounting start days to each month's last day, including leap years; reject invalid dates, progress values, and malformed form fields cleanly.
* Reject relay loops and tolerate pre-existing cycles without recursive aggregation failures.
* Add an expanded transactional regression suite, browser revalidation, and review documentation. Target CI at Redmine 6.1 with Ruby 3.3/3.4.

No new database migrations. Existing roles need the explicit WorkTime management permissions for management actions. Logging time for another member additionally requires Redmine's standard `log_time_for_other_users` permission.

## 0.4.4 - 2026-10-13

### Redmine 6.1 maintenance release by SaaS-Secure.com

* Publish the local Redmine 6.1 adaptations in the sruttloff fork.
* Replace dynamic action routing with explicit routes and remove an unused memo action.
* Apply the project settings helper patch during plugin initialization and prevent recursive calls with alias-wrapping plugins.
* Export decimal hour totals instead of rational fractions on Redmine 6.1.
* Return cleanly after missing-project errors; tolerate missing issues and ticket relay records.
* Use Rails-compatible plain-text error rendering.
* Expand installation, permissions, usage, support, and validation documentation.
* Retain upstream's updated Catalan translations, test helpers, fixtures, and GitHub workflows.
* Add a transactional compatibility runner for the released adaptations.
* Make automatic GitHub release creation independent of a Discussions category.

## 0.4.3

* Inherited upstream baseline (commit `defaa518d19736a44972368dca4ed91078663879`).
* Includes upstream CI and test fixture updates. See Git history for details.

## 0.4.2 - 2025-11-17

### Improvements

  * Add support for Redmine 6.0.

  * Add support for Redmine 6.1.

### Fixes

  * Fixed CKEditor plugin integration.
