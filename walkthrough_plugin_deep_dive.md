# Deep Dive: discourse-quarterly-topic-rotation

*2026-04-08T13:57:10Z by Showboat 0.6.1*
<!-- showboat-id: 6680d186-cc87-4d3f-a0ef-15ee3f5a3828 -->

This walkthrough dissects `plugin.rb` line by line, following the code in the order it executes. The plugin is a Discourse Automation script that manages one "rolling" topic per category — creating a new topic each quarter, closing and optionally archiving the old one, and recovering from interrupted runs.

There are only four files that matter:

- `plugin.rb` — all logic lives here
- `config/settings.yml` — a single on/off site setting
- `config/locales/server.en.yml` — server-side label for the setting
- `config/locales/client.en.yml` — admin UI labels and field descriptions for the automation

## Part 1: Plugin Metadata and the Kill Switch

When Discourse loads a plugin, it reads magic comments at the top of `plugin.rb` for the plugin name, version, and minimum Discourse version. Right after that, `enabled_site_setting` ties the entire plugin to a single boolean — if an admin disables it, none of the code below will run.

```bash
sed -n '1,10p' plugin.rb
```

```output
# frozen_string_literal: true

# name: discourse-quarterly-topic-rotation
# about: Automatically rotates topics on a quarterly basis — archives the current topic and creates a new one with the next quarter's label.
# version: 0.1.0
# authors: Your Name
# url: https://github.com/your-org/discourse-quarterly-topic-rotation
# required_version: 2.7.0

enabled_site_setting :quarterly_topic_rotation_enabled
```

The setting itself is declared in `config/settings.yml`, defaulting to `false` so the plugin ships inert:

```bash
cat config/settings.yml
```

```output
plugins:
  quarterly_topic_rotation_enabled:
    default: false
    client: true
```

## Part 2: The QuarterlyTopicRotation Module — Constants and Date Math

The module is declared at the top level (`::QuarterlyTopicRotation`) so it is globally reachable. It defines two constants and then a set of pure helper methods. Everything below is stateless — these methods just compute things from their arguments.

```bash
sed -n '12,14p' plugin.rb
```

```output
module ::QuarterlyTopicRotation
  PLUGIN_NAME = "discourse-quarterly-topic-rotation"
  QUARTER_KEY_FIELD = "quarterly_topic_rotation_quarter_key"
```

`PLUGIN_NAME` is used as the namespace for `PluginStore` reads/writes (Discourse's key-value store for plugins). `QUARTER_KEY_FIELD` is the name of a topic custom field that tags each managed topic with its quarter — e.g. `"2026-Q2"`. This custom field is how the plugin recognises its own topics even if the PluginStore state is lost.

Now the date helpers. `quarter_for` does the core math: integer-divide `(month - 1)` by 3 to get the quarter number (1–4):

```bash
sed -n '16,31p' plugin.rb
```

```output
  # Returns [quarter_number, year] for a given date
  def self.quarter_for(date)
    q = ((date.month - 1) / 3) + 1
    [q, date.year]
  end

  # Returns the label like "Q2 2026"
  def self.quarter_label(date)
    q, y = quarter_for(date)
    "Q#{q} #{y}"
  end

  def self.quarter_key(date)
    q, y = quarter_for(date)
    "#{y}-Q#{q}"
  end
```

Notice the two different formats: `quarter_label` produces a human-readable string like `"Q2 2026"` for use in topic titles and posts, while `quarter_key` produces a sortable storage key like `"2026-Q2"` for use in PluginStore and custom fields.

Next, `quarter_boundary?` is the gate that decides whether today is a "real" rotation day. It only returns true on January 1, April 1, July 1, and October 1:

```bash
sed -n '33,36p' plugin.rb
```

```output
  # Returns true if the given date is the first day of a quarter in Time.zone
  def self.quarter_boundary?(date)
    date.day == 1 && [1, 4, 7, 10].include?(date.month)
  end
```

## Part 3: Template Rendering with `apply_placeholders`

This is the plugin's mini template engine. It takes a template string and a date, then does simple `gsub` substitution for four placeholders. The `{{prev_quarter_label}}` placeholder is notable — it subtracts 3 months to compute the previous quarter, which is how the closing message can say things like "Continue from Q1 2026" when we're rotating into Q2.

```bash
sed -n '38,55p' plugin.rb
```

```output
  # Applies placeholder substitution to a template string.
  #
  #   {{quarter_label}} => "Q3 2026"
  #   {{quarter}}        => "Q3"
  #   {{year}}           => "2026"
  #   {{prev_quarter_label}} => "Q2 2026"
  #
  def self.apply_placeholders(template, date)
    q, y = quarter_for(date)
    prev_date = date - 3.months
    prev_q, prev_y = quarter_for(prev_date)

    template
      .gsub("{{quarter_label}}", "Q#{q} #{y}")
      .gsub("{{quarter}}", "Q#{q}")
      .gsub("{{year}}", y.to_s)
      .gsub("{{prev_quarter_label}}", "Q#{prev_q} #{prev_y}")
  end
```

Note: `{{new_topic_url}}` is NOT handled here. It is substituted separately in the script block (line 310) because the URL isn't known until the new topic has been created or found.

## Part 4: State Persistence — PluginStore Read/Write

The plugin stores per-category rotation state in Discourse's `PluginStore`, a simple key-value store backed by the database. Each category gets its own key (`rotation_state_{category_id}`).

`rotation_state` reads and normalises the stored value. The `when Integer` branch handles an older storage format where only the topic ID was saved — a migration-free backwards-compatibility trick:

```bash
sed -n '57,80p' plugin.rb
```

```output
  def self.rotation_state(category_id)
    state = PluginStore.get(PLUGIN_NAME, store_key(category_id))

    case state
    when Integer
      { "current_topic_id" => state }
    when Hash
      state.transform_keys(&:to_s)
    else
      {}
    end
  end

  def self.save_rotation_state(category_id, topic_id:, quarter_key:, at:)
    PluginStore.set(
      PLUGIN_NAME,
      store_key(category_id),
      {
        "current_topic_id" => topic_id,
        "current_quarter_key" => quarter_key,
        "last_success_at" => at.iso8601,
      }
    )
  end
```

`save_rotation_state` writes three things: the current topic ID, the current quarter key, and the timestamp of the last successful run. This state is only written at the *very end* of a successful run (line 373), which is what makes the whole flow resumable — if a run crashes partway through, the state still points at the old topic, and the next run can pick up where it left off.

## Part 5: Topic Lookup Helpers

These methods are the plugin's "eyes" for finding managed topics. Each one serves a different fallback scenario in the reconciliation logic.

```bash
sed -n '82,97p' plugin.rb
```

```output
  def self.topic_from_state(state, category_id)
    topic_id = state["current_topic_id"]
    return if topic_id.blank?

    topic = Topic.find_by(id: topic_id)
    topic if topic&.category_id == category_id
  end

  def self.find_topic_by_quarter(category_id, quarter_key)
    TopicCustomField
      .joins(:topic)
      .where(name: QUARTER_KEY_FIELD, value: quarter_key, topics: { category_id: category_id })
      .order("topics.created_at DESC")
      .first
      &.topic
  end
```

`topic_from_state` is the fast path: grab the topic ID from PluginStore and verify it still belongs to the right category (guards against an admin moving or deleting the topic).

`find_topic_by_quarter` is the first fallback: scan `TopicCustomField` for any topic in this category tagged with the current quarter key. This catches cases where the state was lost but the topic itself still exists with its custom field intact.

Next, `find_previous_managed_topic` finds the most recent managed topic that is *not* the current quarter's topic — this is what the cleanup phase will close/archive:

```bash
sed -n '99,108p' plugin.rb
```

```output
  def self.find_previous_managed_topic(category_id, current_topic_id:, current_quarter_key:)
    TopicCustomField
      .joins(:topic)
      .where(name: QUARTER_KEY_FIELD, topics: { category_id: category_id })
      .where.not(topic_id: current_topic_id)
      .where.not(value: current_quarter_key)
      .order("topics.created_at DESC")
      .first
      &.topic
  end
```

The `where.not` clauses are critical: they exclude both the current topic and any topic with the current quarter key, so this method always returns a topic from a *previous* quarter. The `ORDER BY created_at DESC` ensures the most recent one wins if multiple old managed topics exist.

Now the "adoption" helper — the second fallback for finding the current quarter's topic:

```bash
sed -n '110,118p' plugin.rb
```

```output
  def self.find_adoptable_topic(category_id, title, quarter_key)
    Topic
      .where(category_id: category_id, title: title, user_id: Discourse.system_user.id)
      .order(created_at: :desc)
      .find do |topic|
        stored_quarter_key = topic.custom_fields[QUARTER_KEY_FIELD]
        stored_quarter_key.blank? || stored_quarter_key == quarter_key
      end
  end
```

This handles a specific scenario: someone (or an earlier version of the plugin) already created a system-user-authored topic with the exact expected title, but it wasn't tagged with the quarter custom field. Rather than creating a duplicate, the plugin "adopts" it by tagging it. The `find` block ensures it only adopts topics that are either untagged or already tagged with the correct quarter.

The remaining helpers are simpler utilities:

```bash
sed -n '120,145p' plugin.rb
```

```output
  def self.managed_topic_exists?(category_id)
    TopicCustomField.joins(:topic).where(name: QUARTER_KEY_FIELD, topics: { category_id: category_id }).exists?
  end

  def self.managed_topic_in_category?(topic, category_id)
    topic.present? && topic.category_id == category_id && topic.custom_fields[QUARTER_KEY_FIELD].present?
  end

  def self.mark_topic!(topic, quarter_key)
    return if topic.custom_fields[QUARTER_KEY_FIELD] == quarter_key

    topic.custom_fields[QUARTER_KEY_FIELD] = quarter_key
    topic.save_custom_fields
  end

  def self.store_key(category_id)
    "rotation_state_#{category_id}"
  end

  def self.lock_key(category_id)
    "#{PLUGIN_NAME}:rotate:#{category_id}"
  end

  def self.log(level, message)
    Rails.logger.public_send(level, "[quarterly-topic-rotation] #{message}")
  end
```

- `managed_topic_exists?` — a fast existence check ("has this category ever had a managed topic?"). This is how bootstrap runs are detected.
- `managed_topic_in_category?` — validates that a topic object is non-nil, in the right category, and tagged with the quarter custom field.
- `mark_topic!` — idempotently tags a topic with a quarter key custom field. The early return avoids a needless DB write.
- `store_key` / `lock_key` — generate per-category keys for PluginStore and DistributedMutex respectively.
- `log` — all logging goes through `Rails.logger` with a `[quarterly-topic-rotation]` prefix for easy grepping.

## Part 6: Registering the Custom Field and Entering `after_initialize`

After the module closes, two lines wire the plugin into Discourse's infrastructure:

```bash
sed -n '148,153p' plugin.rb
```

```output
register_topic_custom_field_type QuarterlyTopicRotation::QUARTER_KEY_FIELD, :string

after_initialize do
  reloadable_patch do
    if defined?(DiscourseAutomation)
      DiscourseAutomation::Scriptable.add(:quarterly_topic_rotation) do
```

`register_topic_custom_field_type` tells Discourse that this custom field is a string, so it gets properly typed when loaded rather than being treated as raw JSON.

`after_initialize` is Discourse's standard plugin hook — code here runs after the application is fully booted. `reloadable_patch` makes the block safe to re-execute during development reloads. The `if defined?(DiscourseAutomation)` guard protects against installations that don't have the Automation plugin loaded.

`DiscourseAutomation::Scriptable.add(:quarterly_topic_rotation)` registers this as a named automation script that admins can select from the Automation UI.

## Part 7: The Admin-Configurable Fields

Inside the scriptable block, `field` declarations define what the admin sees in the Automation configuration UI. Each field has a name, a component type, and whether it's required:

```bash
sed -n '154,186p' plugin.rb
```

```output
        # ── Admin-configurable fields (auto-rendered in the UI) ──

        # The category where quarterly topics live
        field :target_category, component: :category, required: true

        # Title template for the new topic. Supports placeholders:
        #   {{quarter_label}}  =>  "Q3 2026"
        #   {{quarter}}        =>  "Q3"
        #   {{year}}           =>  "2026"
        field :title_template,
              component: :text,
              required: true

        # Body template for the opening post of the new topic.
        # Same placeholders as above.
        field :post_body_template, component: :message, required: true

        # Optional message posted as the final reply in the old topic
        # before it is closed. Supports {{new_topic_url}} in addition
        # to the standard date placeholders.
        field :closing_message, component: :message, required: false

        # Whether to archive the old topic (true) or just close it (false).
        field :archive_old_topic, component: :boolean

        # If false, the script will only act on the first day of
        # quarter-boundary months (Jan, Apr, Jul, Oct). If true, it runs
        # every time the trigger fires — useful for testing.
        field :skip_quarter_check, component: :boolean

        version 1
        triggerables %i[recurring point_in_time]

```

The field labels visible in the admin UI come from `config/locales/client.en.yml` — Discourse Automation maps the field name (e.g. `:target_category`) to the locale key path `discourse_automation.scriptables.quarterly_topic_rotation.fields.target_category`.

`version 1` is an internal version stamp. `triggerables %i[recurring point_in_time]` declares which Automation triggers this script supports: a recurring schedule or a one-time fire.

## Part 8: The Script Block — Setup and Validation

Now we enter the `script` block — this is what runs every time the automation fires. It receives three arguments: `_context` (trigger metadata, unused), `fields` (the admin-configured values), and `_automation` (the automation record, also unused).

```bash
sed -n '187,214p' plugin.rb
```

```output
        script do |_context, fields, _automation|
          now = Time.zone.now

          skip_check = fields.dig("skip_quarter_check", "value") || false

          # ── Read configuration ──
          category_id = fields.dig("target_category", "value")
          title_template = fields.dig("title_template", "value")
          post_body_template = fields.dig("post_body_template", "value")
          closing_message_template = fields.dig("closing_message", "value")
          should_archive = fields.dig("archive_old_topic", "value") || false

          unless category_id && title_template && post_body_template
            QuarterlyTopicRotation.log(
              :warn,
              "Missing required fields. " \
                "category_id=#{category_id} title_template=#{title_template.present?} " \
                "post_body_template=#{post_body_template.present?}"
            )
            next
          end

          category = Category.find_by(id: category_id)
          unless category
            QuarterlyTopicRotation.log(:warn, "Category #{category_id} not found.")
            next
          end

```

Key design detail: `now = Time.zone.now` is captured *once* at the top. Every quarter calculation and timestamp in the entire run derives from this single value. This prevents subtle bugs where the clock ticks from 23:59 to 00:00 mid-execution and changes the computed quarter.

The `next` statements are how you exit early inside a Discourse Automation script block — the block is a proc, not a method, so `return` would be wrong.

Two layers of validation: first, are all required admin fields present? Second, does the target category actually exist in the database? Both bail with a logged warning if they fail.

## Part 9: The Distributed Lock and State Gathering

Everything from here through the end of the run happens inside a `DistributedMutex` — Redis-backed per-category locking that ensures only one Sidekiq worker at a time can execute the rotation for a given category:

```bash
sed -n '215,238p' plugin.rb
```

```output
          DistributedMutex.synchronize(QuarterlyTopicRotation.lock_key(category.id)) do
            quarter_key = QuarterlyTopicRotation.quarter_key(now)
            new_title = QuarterlyTopicRotation.apply_placeholders(title_template, now)
            new_post_body = QuarterlyTopicRotation.apply_placeholders(post_body_template, now)
            state = QuarterlyTopicRotation.rotation_state(category.id)
            state_topic = QuarterlyTopicRotation.topic_from_state(state, category.id)
            managed_topic_exists = QuarterlyTopicRotation.managed_topic_exists?(category.id)
            boundary_run = skip_check || QuarterlyTopicRotation.quarter_boundary?(now)

            current_topic = nil

            if state["current_quarter_key"] == quarter_key &&
                 QuarterlyTopicRotation.managed_topic_in_category?(state_topic, category.id) &&
                 state_topic.custom_fields[QuarterlyTopicRotation::QUARTER_KEY_FIELD] == quarter_key
              current_topic = state_topic
            end

            current_topic ||= QuarterlyTopicRotation.find_topic_by_quarter(category.id, quarter_key)

            adopted_topic = nil
            if current_topic.nil?
              adopted_topic = QuarterlyTopicRotation.find_adoptable_topic(category.id, new_title, quarter_key)
              current_topic = adopted_topic if adopted_topic
            end
```

This is the "current topic resolution" cascade, and it runs in a deliberate fallback order:

1. **State check** (lines 226–230): Trust `PluginStore` if it says the current quarter key matches AND the referenced topic is a valid managed topic in the right category with the right custom field. This is the fast, happy path.
2. **Custom field scan** (line 232): If the state check fails (state lost, topic deleted, category changed), query `TopicCustomField` directly for any topic tagged with this quarter key in this category.
3. **Adoption** (lines 234–238): If nothing is found, look for a system-user-authored topic with the expected title that can be adopted. This prevents duplicate topics when someone manually created one.

The cascade is defensive: even if PluginStore is wiped, the plugin can recover from custom fields alone. Even if custom fields are missing, it can adopt a matching topic by title.

## Part 10: The Three Run-Type Booleans

```bash
sed -n '240,264p' plugin.rb
```

```output
            bootstrap_run = !managed_topic_exists

            previous_topic = nil
            if state_topic.present? && state_topic.id != current_topic&.id
              previous_topic = state_topic
            end

            previous_topic ||= QuarterlyTopicRotation.find_previous_managed_topic(
              category.id,
              current_topic_id: current_topic&.id,
              current_quarter_key: quarter_key,
            )

            healing_run =
              current_topic.present? &&
                previous_topic.present? &&
                (!previous_topic.closed? || (should_archive && !previous_topic.archived?))

            unless boundary_run || bootstrap_run || healing_run
              QuarterlyTopicRotation.log(
                :info,
                "Not the first day of a quarter in Time.zone (#{now.to_date}), and no bootstrap or recovery work is needed. Skipping."
              )
              next
            end
```

Three boolean flags control whether work proceeds:

- **`bootstrap_run`** — true when no managed topic has *ever* existed in this category. This lets the automation create the initial topic immediately, on any day, without waiting for a quarter boundary.
- **`boundary_run`** — true when today is a quarter boundary (Jan/Apr/Jul/Oct 1st) OR the admin has toggled `skip_quarter_check` for testing. This is the normal rotation trigger.
- **`healing_run`** — true when the current quarter's topic exists but a previous quarter's topic is still open (or not yet archived when archiving is configured). This is how the plugin finishes interrupted work — if a prior run crashed after creating the new topic but before closing the old one.

The `unless boundary_run || bootstrap_run || healing_run` guard is the safety valve. If none of these conditions is true, the run exits. This means you can safely schedule the automation to fire daily or even hourly — it will no-op on non-actionable days, but it will still catch and heal missed work.

Notice how `previous_topic` uses the same cascade pattern as `current_topic`: check state first, then fall back to a custom field query.

## Part 11: Creating, Adopting, or Reusing the Current Quarter's Topic

```bash
sed -n '266,304p' plugin.rb
```

```output
            if current_topic.nil?
              creator = PostCreator.new(
                Discourse.system_user,
                title: new_title,
                raw: new_post_body,
                category: category.id,
              )

              new_post = creator.create
              if new_post.blank?
                QuarterlyTopicRotation.log(
                  :error,
                  "Failed to create topic: #{creator.errors.full_messages.join(', ')}"
                )
                next
              end

              current_topic = new_post.topic
              log_message = if bootstrap_run && !boundary_run
                "Created initial managed topic: '#{current_topic.title}' (id=#{current_topic.id})"
              else
                "Created new topic: '#{current_topic.title}' (id=#{current_topic.id})"
              end
              QuarterlyTopicRotation.log(:info, log_message)
            elsif adopted_topic
              log_message = if bootstrap_run && !boundary_run
                "Adopted existing topic as the initial managed topic for #{quarter_key}: '#{current_topic.title}' (id=#{current_topic.id})"
              else
                "Adopted existing topic for #{quarter_key}: '#{current_topic.title}' (id=#{current_topic.id})"
              end
              QuarterlyTopicRotation.log(:info, log_message)
            else
              QuarterlyTopicRotation.log(
                :info,
                "Reusing managed topic for #{quarter_key}: '#{current_topic.title}' (id=#{current_topic.id})"
              )
            end

            QuarterlyTopicRotation.mark_topic!(current_topic, quarter_key)
```

Three branches, exactly one executes:

1. **Create** (`current_topic.nil?`): No topic was found by any method. `PostCreator` creates a new topic as `Discourse.system_user`. If creation fails (e.g. a title uniqueness constraint), the error is logged and the run aborts early — crucially, *before* any state is persisted.

2. **Adopt** (`adopted_topic` is set): A matching topic was found by `find_adoptable_topic` but not by state or custom field lookup. The plugin logs the adoption. No new topic is created.

3. **Reuse** (default): The topic was already found by state or custom field — this is a rerun within the same quarter. Just log it.

The log message distinguishes bootstrap runs from boundary runs with a conditional: `"Created initial managed topic"` vs `"Created new topic"`. This is purely for operational clarity in log output.

After the branch, `mark_topic!` ensures the winning topic has the quarter custom field set, regardless of which branch we took. This is idempotent — if the field is already correct, it no-ops.

## Part 12: Cleaning Up the Previous Topic

This is the most operationally complex part of the plugin. It runs only when `previous_topic` is present and handles three steps in a strict order: post closing message, close the topic, optionally archive it.

```bash
sed -n '306,338p' plugin.rb
```

```output
            if previous_topic.present?
              if closing_message_template.present? && !previous_topic.closed?
                closing_body = QuarterlyTopicRotation
                  .apply_placeholders(closing_message_template, now)
                  .gsub("{{new_topic_url}}", current_topic.url)

                unless Post.where(
                         topic_id: previous_topic.id,
                         user_id: Discourse.system_user.id,
                         raw: closing_body,
                       ).exists?
                  closing_creator = PostCreator.new(
                    Discourse.system_user,
                    topic_id: previous_topic.id,
                    raw: closing_body,
                  )

                  closing_post = closing_creator.create
                  if closing_post.blank?
                    QuarterlyTopicRotation.log(
                      :error,
                      "Failed to post closing message in topic '#{previous_topic.title}' " \
                        "(id=#{previous_topic.id}): #{closing_creator.errors.full_messages.join(', ')}"
                    )
                    next
                  end

                  QuarterlyTopicRotation.log(
                    :info,
                    "Posted closing message in old topic: '#{previous_topic.title}' (id=#{previous_topic.id})"
                  )
                end
              end
```

**Step 1: Closing message.** Only attempts this if:
- A closing message template was configured (optional field), AND
- The previous topic is not already closed (no point posting in a closed topic)

The `{{new_topic_url}}` substitution happens here — separate from `apply_placeholders` because the URL was not available during template rendering at the top of the lock block.

The idempotence guard is the `Post.where(...).exists?` check: it queries for an exact match on topic, user, and raw body. If a previous healing run already posted this message, the check returns true and the post is skipped. This prevents duplicate closing messages on repeated healing runs.

If the post creation fails, the run aborts (`next`). This is important: the plugin would rather leave the old topic open than persist state claiming cleanup succeeded.

**Step 2: Close the topic:**

```bash
sed -n '340,370p' plugin.rb
```

```output
              unless previous_topic.closed?
                begin
                  previous_topic.update_status("closed", true, Discourse.system_user)
                  QuarterlyTopicRotation.log(
                    :info,
                    "Closed old topic: '#{previous_topic.title}' (id=#{previous_topic.id})"
                  )
                rescue StandardError => e
                  QuarterlyTopicRotation.log(
                    :error,
                    "Failed to close old topic '#{previous_topic.title}' (id=#{previous_topic.id}): #{e.message}"
                  )
                  next
                end
              end

              if should_archive && !previous_topic.archived?
                begin
                  previous_topic.update_status("archived", true, Discourse.system_user)
                  QuarterlyTopicRotation.log(
                    :info,
                    "Archived old topic: '#{previous_topic.title}' (id=#{previous_topic.id})"
                  )
                rescue StandardError => e
                  QuarterlyTopicRotation.log(
                    :error,
                    "Failed to archive old topic '#{previous_topic.title}' (id=#{previous_topic.id}): #{e.message}"
                  )
                  next
                end
              end
```

**Step 2: Close.** Calls `topic.update_status("closed", true, system_user)`, which is Discourse's standard API for closing a topic. The `unless previous_topic.closed?` guard means healing runs skip this if a prior run already closed it. If closing fails, the run aborts.

**Step 3: Archive (optional).** Same pattern: only runs if `archive_old_topic` is enabled and the topic isn't already archived. Uses the same `update_status` API with `"archived"`. Again, failure aborts the run before state is persisted.

The ordering matters: closing message → close → archive. You can't post in a closed topic, so the message must go first. And archiving a topic that isn't closed first would be unusual. Each step has its own idempotence check (`closed?`, `archived?`), so a healing run can safely resume from any point in this sequence.

## Part 13: Persisting the Final State

```bash
sed -n '373,384p' plugin.rb
```

```output
            QuarterlyTopicRotation.save_rotation_state(
              category.id,
              topic_id: current_topic.id,
              quarter_key: quarter_key,
              at: now,
            )
          end
        end
      end
    end
  end
end
```

This is the *only* place state is written. It sits at the very bottom of the lock block, after every possible operation has succeeded. This is the cornerstone of the re-entrancy design:

- If a run crashes before this line, the state still points at the old topic. The next run will detect that work is unfinished (via `healing_run`) and resume.
- If a run reaches this line, it means the new topic is confirmed, marked, and the old topic (if any) is fully cleaned up. The state now points at the new topic, and future runs within this quarter will hit the "reuse" branch and no-op.

The `DistributedMutex`, the late state write, and the idempotent checks at each cleanup step together form a mini transaction-like pattern — not ACID, but good enough for an automation script that may fire repeatedly.

## Part 14: The Test Suite

The spec file covers the three main scenarios: bootstrap, normal rotation, and healing. It's worth reading to see how the plugin is exercised:

```bash
sed -n '1,45p' spec/integration/quarterly_topic_rotation_spec.rb
```

```output
# frozen_string_literal: true

require "rails_helper"

if defined?(DiscourseAutomation)
  RSpec.describe "Quarterly topic rotation automation" do
    fab!(:admin)
    fab!(:category) { Fabricate(:category, user: admin) }
    fab!(:automation) do
      Fabricate(:automation, script: "quarterly_topic_rotation", trigger: "recurring")
    end

    let(:title_template) { "New Member Intros {{quarter_label}}" }
    let(:post_body_template) { "Welcome to {{quarter_label}}" }
    let(:closing_message_template) do
      "This thread is now closed. Continue in {{new_topic_url}} from {{prev_quarter_label}}."
    end

    before do
      SiteSetting.quarterly_topic_rotation_enabled = true
      SiteSetting.discourse_automation_enabled = true
    end

    it "bootstraps the current quarter outside a boundary when the category is unmanaged" do
      configure_automation

      freeze_time(Time.zone.parse("2026-02-15 10:00:00")) do
        expect { automation.trigger! }.to change { Topic.where(category_id: category.id).count }.by(1)

        current_topic = Topic.where(category_id: category.id).order(:created_at).last
        state = QuarterlyTopicRotation.rotation_state(category.id)

        expect(current_topic.title).to eq("New Member Intros Q1 2026")
        expect(current_topic.first_post.raw).to eq("Welcome to Q1 2026")
        expect(current_topic.user_id).to eq(Discourse.system_user.id)
        expect(current_topic.closed?).to eq(false)
        expect(current_topic.archived?).to eq(false)
        expect(current_topic.custom_fields[QuarterlyTopicRotation::QUARTER_KEY_FIELD]).to eq("2026-Q1")
        expect(state).to include(
          "current_topic_id" => current_topic.id,
          "current_quarter_key" => "2026-Q1",
          "last_success_at" => Time.zone.now.iso8601,
        )
      end
    end
```

The **bootstrap test** freezes time to February 15 — *not* a quarter boundary. It verifies that when no managed topic exists for the category, the plugin creates one immediately. It then checks the topic title, body, author, open/archive status, custom field value, and PluginStore state. This test proves the `bootstrap_run` path works.

The **rotation test** is the most comprehensive:

```bash
sed -n '47,96p' spec/integration/quarterly_topic_rotation_spec.rb
```

```output
    it "creates the next quarter topic and closes plus archives the previous managed topic" do
      configure_automation(archive_old_topic: true, closing_message: closing_message_template)

      previous_topic = nil

      freeze_time(Time.zone.parse("2026-01-15 09:00:00")) do
        previous_topic = create_managed_topic(
          title: "New Member Intros Q1 2026",
          body: "Welcome to Q1 2026",
          quarter_key: "2026-Q1",
        )

        QuarterlyTopicRotation.save_rotation_state(
          category.id,
          topic_id: previous_topic.id,
          quarter_key: "2026-Q1",
          at: Time.zone.now,
        )
      end

      freeze_time(Time.zone.parse("2026-04-01 09:00:00")) do
        expect { automation.trigger! }.to change { Topic.where(category_id: category.id).count }.by(1)

        new_topic = Topic.where(category_id: category.id).where.not(id: previous_topic.id).order(:created_at).last
        expected_closing_body =
          "This thread is now closed. Continue in #{new_topic.url} from Q1 2026."
        state = QuarterlyTopicRotation.rotation_state(category.id)

        previous_topic.reload
        new_topic.reload

        expect(new_topic.title).to eq("New Member Intros Q2 2026")
        expect(new_topic.first_post.raw).to eq("Welcome to Q2 2026")
        expect(new_topic.custom_fields[QuarterlyTopicRotation::QUARTER_KEY_FIELD]).to eq("2026-Q2")
        expect(previous_topic).to be_closed
        expect(previous_topic).to be_archived
        expect(
          Post.where(
            topic_id: previous_topic.id,
            user_id: Discourse.system_user.id,
            raw: expected_closing_body,
          ).count,
        ).to eq(1)
        expect(state).to include(
          "current_topic_id" => new_topic.id,
          "current_quarter_key" => "2026-Q2",
          "last_success_at" => Time.zone.now.iso8601,
        )
      end
    end
```

This test sets up a Q1 topic in January, then fast-forwards to April 1 (a quarter boundary). It verifies the complete rotation lifecycle: new topic created with correct Q2 title/body, old topic closed AND archived, closing message posted exactly once in the old topic, and state updated to point at the new topic.

The **healing test** is the most interesting because it verifies the re-entrancy guarantee:

```bash
sed -n '98,155p' spec/integration/quarterly_topic_rotation_spec.rb
```

```output
    it "heals incomplete cleanup off-cycle without duplicating the closing message" do
      configure_automation(archive_old_topic: true, closing_message: closing_message_template)

      previous_topic = nil
      current_topic = nil

      freeze_time(Time.zone.parse("2026-01-15 09:00:00")) do
        previous_topic = create_managed_topic(
          title: "New Member Intros Q1 2026",
          body: "Welcome to Q1 2026",
          quarter_key: "2026-Q1",
        )
      end

      freeze_time(Time.zone.parse("2026-04-01 09:00:00")) do
        current_topic = create_managed_topic(
          title: "New Member Intros Q2 2026",
          body: "Welcome to Q2 2026",
          quarter_key: "2026-Q2",
        )

        QuarterlyTopicRotation.save_rotation_state(
          category.id,
          topic_id: current_topic.id,
          quarter_key: "2026-Q2",
          at: Time.zone.now,
        )
      end

      expected_closing_body =
        "This thread is now closed. Continue in #{current_topic.url} from Q1 2026."

      freeze_time(Time.zone.parse("2026-04-15 09:00:00")) do
        expect { automation.trigger! }.not_to change { Topic.where(category_id: category.id).count }

        previous_topic.reload

        expect(previous_topic).to be_closed
        expect(previous_topic).to be_archived
        expect(
          Post.where(
            topic_id: previous_topic.id,
            user_id: Discourse.system_user.id,
            raw: expected_closing_body,
          ).count,
        ).to eq(1)

        expect do
          automation.trigger!
        end.not_to change do
          Post.where(
            topic_id: previous_topic.id,
            user_id: Discourse.system_user.id,
            raw: expected_closing_body,
          ).count
        end
      end
    end
```

This test simulates a scenario where the Q2 topic was created and state was saved, but the Q1 topic was never closed or archived (as if the prior run crashed). It fires the automation on April 15 — *not* a quarter boundary — and verifies:

1. No new topic is created (topic count doesn't change)
2. The Q1 topic is now closed and archived
3. The closing message was posted exactly once
4. A *second* trigger on the same day does not duplicate the closing message (the `Post.where(...).exists?` guard works)

This is the test that proves the healing flow is both correct and idempotent.

## Part 15: Test Helpers

```bash
sed -n '157,201p' spec/integration/quarterly_topic_rotation_spec.rb
```

```output
    def configure_automation(archive_old_topic: false, closing_message: nil)
      automation.upsert_field!("target_category", "category", { value: category.id.to_s }, target: "script")
      automation.upsert_field!("title_template", "text", { value: title_template }, target: "script")
      automation.upsert_field!(
        "post_body_template",
        "message",
        { value: post_body_template },
        target: "script",
      )
      automation.upsert_field!(
        "archive_old_topic",
        "boolean",
        { value: archive_old_topic },
        target: "script",
      )
      automation.upsert_field!("skip_quarter_check", "boolean", { value: false }, target: "script")
      automation.upsert_field!(
        "recurrence",
        "period",
        { value: { interval: 1, frequency: "month" } },
        target: "trigger",
      )
      automation.upsert_field!("start_date", "date_time", { value: 1.minute.ago }, target: "trigger")

      return if closing_message.blank?

      automation.upsert_field!("closing_message", "message", { value: closing_message }, target: "script")
    end

    def create_managed_topic(title:, body:, quarter_key:)
      creator = PostCreator.new(
        Discourse.system_user,
        title: title,
        raw: body,
        category: category.id,
      )
      new_post = creator.create

      raise "Failed to create topic: #{creator.errors.full_messages.join(', ')}" if new_post.blank?

      topic = new_post.topic
      QuarterlyTopicRotation.mark_topic!(topic, quarter_key)
      topic.reload
    end
  end
```

`configure_automation` mirrors the admin UI setup: it uses `upsert_field!` to set each scriptable field and the trigger configuration (monthly recurrence, starting 1 minute ago). Note that `skip_quarter_check` is always set to `false` — the tests rely on real quarter boundary dates via `freeze_time`.

`create_managed_topic` is a helper that creates a topic and immediately marks it with the quarter custom field, simulating what the plugin itself does. The `topic.reload` at the end ensures the returned object has fresh custom fields.

## Summary: The Design in One Paragraph

The plugin is a single Discourse Automation script that manages one rolling quarterly topic per category. On each run, it computes the current quarter from `Time.zone.now`, resolves the current topic through a three-tier fallback cascade (PluginStore state → custom field scan → title-based adoption), determines the previous topic the same way, then gates execution on three conditions: is this a first-run bootstrap, a quarter boundary, or a healing run for unfinished cleanup? If any condition is true, it ensures the current topic exists and is tagged, then cleans up the previous topic in order (closing message → close → archive), with idempotent guards at every step. State is written only at the very end, making the entire flow resumable from any point of failure.
