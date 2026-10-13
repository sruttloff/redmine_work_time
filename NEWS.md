# WorkTime

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
