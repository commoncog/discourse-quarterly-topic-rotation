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

## Code Style
- Ruby, `# frozen_string_literal: true` at top of every `.rb` file.
- Follow Discourse plugin conventions: metadata comments at top of `plugin.rb`, `enabled_site_setting`, `after_initialize` / `reloadable_patch` blocks.
- Use `PluginStore` for persisting per-category rotation state; use a topic custom field to mark managed topics by quarter key.
- New quarter topic creation should stay tied to the first day of January, April, July, and October in `Time.zone`, except for first-run bootstrap and recovery of incomplete cleanup.
- Assume one dedicated rotation stream per category; do not add logic that guesses the old topic from generic category recency.
- Keep the reconciliation flow re-entrant so later runs can safely finish missed close/archive work without creating duplicate quarter topics.
- Use `DistributedMutex` for per-category rotation locking and `PostCreator` for creating posts/topics.
- Log with `Rails.logger` using `[quarterly-topic-rotation]` prefix.
- Template placeholders: `{{quarter_label}}`, `{{quarter}}`, `{{year}}`, `{{prev_quarter_label}}`, `{{new_topic_url}}`.
