# Discourse Plugin Testing Guide

This file summarizes what I learned while adding
`spec/integration/quarterly_topic_rotation_spec.rb` to this plugin.

## The Short Version

This plugin's spec is not a standalone Ruby test. It is a Discourse plugin
spec, which means it is meant to run inside a full Discourse checkout with the
plugin installed under `plugins/discourse-quarterly-topic-rotation`.

The key command is:

```sh
LOAD_PLUGINS=1 bundle exec rspec \
  plugins/discourse-quarterly-topic-rotation/spec/integration/quarterly_topic_rotation_spec.rb
```

Or, to run the whole plugin spec suite:

```sh
bundle exec rake "plugin:spec[discourse-quarterly-topic-rotation]"
```

## Why The Spec Runs That Way

The spec starts with:

```ruby
require "rails_helper"
```

That is Discourse's `spec/rails_helper.rb`, not something local to this plugin.
So the test assumes all of the following already exist:

- a full Rails app
- Discourse models such as `Topic`, `Post`, `Category`, and `PluginStore`
- Discourse test helpers such as `freeze_time`
- Fabrication and core fabricators
- the `discourse-automation` plugin and its test fabricators

If this repository is sitting by itself on disk, the spec can be syntax-checked,
but it cannot be executed end-to-end because none of that test infrastructure is
available.

## What `LOAD_PLUGINS=1` Does

Discourse does not load plugins in the test environment unless you explicitly
ask it to. `LOAD_PLUGINS=1` turns plugin loading on for specs.

That matters here for two reasons:

1. This plugin's `plugin.rb` must be loaded so the
   `quarterly_topic_rotation` automation scriptable is registered.
2. The `discourse-automation` plugin must also be loaded, because this spec uses
   its automation model and test fabricators.

Without `LOAD_PLUGINS=1`, the plugin routes, plugin code, plugin fabricators,
and automation script registration may not exist in the test process.

## How This Spec Works

The spec in
`spec/integration/quarterly_topic_rotation_spec.rb` is best thought of as an
integration spec around the automation entry point defined in `plugin.rb`.

It does not call helper methods directly as its primary testing strategy.
Instead, it exercises the plugin the way Discourse actually uses it.

The rough flow is:

1. Fabricate a category and a `DiscourseAutomation::Automation` record.
2. Enable the relevant site settings.
3. Configure the automation's script fields with `automation.upsert_field!`.
4. Freeze time to a specific date.
5. Call `automation.trigger!`.
6. Assert against real Discourse state:
   - created topics
   - created posts
   - topic custom fields
   - topic closed/archived status
   - `PluginStore` state

That is a good fit for this plugin because nearly all of its behavior lives in a
single automation `script` block inside `plugin.rb`.

## Why I Chose Integration Specs

This plugin is a single-file plugin and the most important behavior is not the
individual helper methods. The important behavior is:

- when the automation runs
- whether it creates or reuses the right topic
- whether it closes and archives the previous topic
- whether it writes the expected state to `PluginStore`
- whether re-running the automation is safe

Those are integration-level concerns, so testing through `automation.trigger!`
is more valuable than unit-testing every helper in isolation.

## What The Current Spec Covers

The spec currently covers three high-value scenarios:

1. Bootstrap
   - If the category has no managed topic yet, an off-boundary run creates the
     initial quarter topic.

2. Quarter boundary rotation
   - On the first day of a new quarter, the automation creates the new topic,
     posts the closing message, closes the previous topic, and archives it when
     configured.

3. Healing and idempotency
   - If a later run finds that the current quarter topic already exists but the
     previous topic cleanup was not finished, it completes the cleanup without
     duplicating the closing message.

This gives coverage for the plugin's most important user-facing guarantees while
keeping the test suite compact.

## Why `freeze_time` Is Important

This plugin is date-driven. Quarter boundaries are the feature.

Without time control, the tests would be flaky or impossible to reason about.
The spec uses `freeze_time(...) do ... end` so that:

- quarter calculations are deterministic
- timestamps written to `PluginStore` are assertable
- the block form automatically restores time after each example

In Discourse specs, using the block form is the safest option because it avoids
time leaking into other examples.

## The Role Of Fabricators And Real Models

Typical Discourse plugin specs rely heavily on:

- `fab!` / `Fabricate(...)`
- real ActiveRecord models
- site setting overrides in the example itself

That is what this spec does too.

Examples from this spec:

- `fab!(:category) { Fabricate(:category, user: admin) }`
- `Fabricate(:automation, script: "quarterly_topic_rotation", trigger: "recurring")`
- `PostCreator.new(...)` to build managed topics for setup

This is the normal Discourse style: use the real stack unless mocking would make
the test much clearer.

## The Typical Discourse Plugin Testing Story

For backend plugin code, the common path is:

1. Put Ruby specs under the plugin's `spec/` directory.
2. Run them from the root of a full Discourse checkout.
3. Set `LOAD_PLUGINS=1` so the plugin is actually loaded in test.
4. Use `bundle exec rspec ...` for targeted runs or
   `bundle exec rake "plugin:spec[plugin-name]"` for the whole plugin.

In practice, the testing toolbox usually looks like this:

- Backend behavior: RSpec in `spec/`
- Frontend Ember behavior: plugin QUnit tests under `test/javascripts/...`
- Full browser flows: system specs when the plugin has meaningful UI

For a plugin like this one, which is mostly server-side automation logic,
backend RSpec integration tests are the most natural first layer.

## What Discourse Loads For Plugin Specs

When plugins are loaded in test mode, Discourse's test boot process also knows
how to load plugin-specific test helpers and fabricators.

That typically means these plugin-local files are available if present:

- `spec/plugin_helper.rb`
- `spec/fabricators/**/*.rb`
- `spec/system/page_objects/**/*.rb`

This plugin does not currently need a `spec/plugin_helper.rb`, but that is a
normal place to put shared setup if the test suite grows.

## Useful Commands

Run this plugin's spec file only:

```sh
LOAD_PLUGINS=1 bundle exec rspec \
  plugins/discourse-quarterly-topic-rotation/spec/integration/quarterly_topic_rotation_spec.rb
```

Run the entire plugin spec suite:

```sh
bundle exec rake "plugin:spec[discourse-quarterly-topic-rotation]"
```

Use autospec during development from the Discourse root:

```sh
bin/rake autospec
```

## Common Gotchas

- Running from the plugin directory instead of the Discourse root.
- Forgetting `LOAD_PLUGINS=1`.
- Expecting a standalone plugin repo to have a working `rails_helper`.
- Forgetting that `discourse-automation` must also be available for this plugin.
- Writing time-sensitive tests without `freeze_time`.
- Testing helper methods only and missing the actual automation integration path.

## What I Learned About This Plugin Specifically

- The real public API of this plugin is the automation scriptable registered in
  `plugin.rb`, not just the helper methods in the module.
- `PluginStore` plus a topic custom field gives enough observable state to write
  useful assertions without reaching into internals too much.
- The safest high-value coverage is around bootstrap, quarter rotation, and
  healing/idempotency.
- For this plugin, one well-targeted integration spec file is more useful than a
  large number of tiny helper specs.

## If The Test Suite Grows Later

Good future additions would be:

- a scheduler-path spec that goes through `Jobs::DiscourseAutomation::Tracker`
- failure-path specs for topic creation or status updates
- optional specs for adoptable-topic behavior
- UI tests only if the plugin gains custom frontend behavior
