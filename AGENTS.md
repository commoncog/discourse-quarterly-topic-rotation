# AGENTS.md — discourse-quarterly-topic-rotation

## Overview
Discourse plugin that adds a `quarterly_topic_rotation` automation script (via Discourse Automation). It bootstraps the first managed topic for a dedicated category immediately, then rotates that category on the first day of each quarter in Discourse's `Time.zone`: creates a new topic, posts a closing message, and closes/archives the old one. It also heals incomplete prior runs. Single-file plugin — all logic lives in `plugin.rb`.

## Structure
- `plugin.rb` — Plugin metadata, `QuarterlyTopicRotation` module (helpers/state tracking), topic custom field registration, and the automation scriptable definition inside `after_initialize`.
- `config/settings.yml` — Site setting `quarterly_topic_rotation_enabled`.
- `config/locales/` — i18n strings (server.en.yml, client.en.yml) for the site setting and automation UI.

## Build / Test
This plugin runs inside a Discourse Rails app. There is no standalone build or test suite. To test, install into a Discourse dev environment and run Discourse's test suite with the plugin loaded:
```sh
LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-quarterly-topic-rotation
```

## State Management
- **PluginStore** holds per-category rotation state as a JSON hash keyed by category ID, containing: `current_topic_id`, `current_quarter_key` (e.g. `2026-Q3`), and `last_success_at` (ISO 8601 timestamp).
- **Topic custom field** `quarterly_topic_rotation_quarter_key` (constant: `QuarterlyTopicRotation::QUARTER_KEY_FIELD`) marks managed topics. Never identify managed topics by heuristics like "most recent topic in category."
- The reconciliation flow follows a "resolve or create" pattern: look for an existing managed topic for the current quarter before creating a new one, and heal incomplete prior runs (e.g. close/archive an old topic that was left open).

## Concurrency & Safety
- Wrap all mutating actions in `DistributedMutex.synchronize` with key `discourse-quarterly-topic-rotation:rotate:<category_id>`.
- Do **not** pass `skip_validations: true` to `PostCreator`; let topics/posts go through normal site validation.
- Before posting a closing message, check whether the system user has already posted that exact content to the topic to avoid duplicate posts during recovery runs.

## Code Style
- Ruby, `# frozen_string_literal: true` at top of every `.rb` file.
- Follow Discourse plugin conventions: metadata comments at top of `plugin.rb`, `enabled_site_setting`, `after_initialize` / `reloadable_patch` blocks.
- Use `Time.zone.now` for all time checks to respect the Discourse site's configured time zone.
- New quarter topic creation should stay tied to the first day of January, April, July, and October in `Time.zone`, except for first-run bootstrap and recovery of incomplete cleanup.
- **Bootstrap rule**: if a category has no managed topics yet, create the initial topic immediately regardless of calendar date.
- **Healing runs**: off-cycle runs are allowed when the plugin detects a previous rotation was incomplete (new topic exists but old one is still open).
- Assume one dedicated rotation stream per category.
- Keep the reconciliation flow re-entrant so later runs can safely finish missed close/archive work without creating duplicate quarter topics.
- Use `DistributedMutex` for per-category rotation locking and `PostCreator` for creating posts/topics.
- Log with `Rails.logger` using `[quarterly-topic-rotation]` prefix.
- Template placeholders: `{{quarter_label}}`, `{{quarter}}`, `{{year}}`, `{{prev_quarter_label}}`, `{{new_topic_url}}`.
