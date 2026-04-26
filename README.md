# Discourse Quarterly Topic Rotation

A Discourse plugin that adds a custom automation script to rotate topics on a quarterly basis. On first setup, it seeds the first managed topic for the category. After that, it rotates on the first day of each quarter in Discourse's configured `Time.zone`, and can finish incomplete cleanup from a prior run if needed:

1. **Creates** a new topic in a configured category with the new quarter's label (e.g., "New Member Intros Q3 2026")
2. **Posts a closing message** (optional) in the old topic linking to the new one
3. **Closes and/or archives** the old topic

The plugin uses Discourse's built-in Automation system — no external cron jobs or API scripts required.

For safety, each rotation stream should use its own dedicated category.

On first run, the plugin creates or adopts the current quarter's topic immediately if the category has not been initialized yet, even if the current date is past the quarter boundary.

## Requirements

- Discourse 2.7.0 or later (Discourse Automation is bundled with core)
- Discourse Automation must be enabled in site settings
- Self-hosted Discourse, or a managed hosting plan that permits custom plugins

## Installation

Add the plugin's repository URL to your `app.yml` in the `hooks` section:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/commoncog/discourse-quarterly-topic-rotation.git
```

Then rebuild:

```bash
cd /var/discourse
./launcher rebuild app
```

## Configuration

### Step 1: Enable the plugin

Go to **Admin → Site Settings**, search for `quarterly_topic_rotation_enabled`, and toggle it **on**.

### Step 2: Enable Discourse Automation

If not already active, search for `discourse_automation_enabled` in Site Settings and toggle it **on**.

### Step 3: Create the automation

Navigate to **Admin → Plugins → Automations** (or go to `/admin/plugins/discourse-automation`), then click **New**.

| Setting | Value |
|---|---|
| **Name** | e.g., "Quarterly Member Intro Rotation" |
| **Script** | Quarterly Topic Rotation |
| **Trigger** | Recurring |

### Step 4: Configure the trigger

Set the **Recurring** trigger to fire **monthly on the 1st day of the month**. The script includes a built-in guard that creates new quarter topics only on the first day of January, April, July, and October in Discourse's `Time.zone`, while still allowing an initial first-run seed and later cleanup recovery if needed.

If you prefer, you can use four separate **Point in time** triggers instead, one for each quarter boundary date.

### Step 5: Configure the script fields

Use a dedicated category for this automation. The plugin now tracks its managed topics explicitly and heals incomplete prior runs, but it is still intended for one quarterly rotation stream per category.

| Field | Example | Notes |
|---|---|---|
| **Category** | Introductions | The category where your quarterly topics live |
| **Topic title template** | `New Member Intros {{quarter_label}}` | Produces titles like "New Member Intros Q3 2026"; include a quarter placeholder so each run renders a unique title |
| **Opening post body** | `Welcome! This is the {{quarter_label}} introduction thread. Please say hello and tell us a bit about yourself.` | The first post of each new topic |
| **Closing message** | `This thread is now closed. Please continue introductions in the new topic: {{new_topic_url}}` | Optional — posted as a final reply before closing |
| **Archive old topic** | ✅ | Check if you want to archive (not just close) |
| **Skip quarter-boundary check** | ☐ | Leave unchecked for production; check for testing |

### Step 6: Save and enable

Toggle the automation to **Enabled** and save. Done.

## First-Run Behavior

When you enable the automation for a category that does not yet have a managed quarterly topic, the plugin bootstraps the category immediately:

1. It computes the current quarter from Discourse's `Time.zone`.
2. It creates the current quarter's topic, or adopts an existing system-created topic with the expected title.
3. It marks that topic as managed and stores the category's rotation state.
4. It does not attempt to close or archive anything on that bootstrap run unless it finds incomplete cleanup from an earlier managed run.

This means you do not need to wait until the next quarter boundary to start using the plugin.

## Placeholders

These placeholders work in the title template, post body, and closing message:

| Placeholder | Example output | Description |
|---|---|---|
| `{{quarter_label}}` | Q3 2026 | Current quarter and year |
| `{{quarter}}` | Q3 | Current quarter only |
| `{{year}}` | 2026 | Current year |
| `{{prev_quarter_label}}` | Q2 2026 | Previous quarter and year |
| `{{new_topic_url}}` | /t/new-member-intros-q3-2026/456 | Only available in closing message |

## How it works internally

1. **Quarter-boundary guard with bootstrap** — Unless "Skip quarter-boundary check" is enabled, new quarter topics are created only on the first day of January, April, July, or October in Discourse's `Time.zone`. The exception is the first managed topic for a category: if no managed topic exists yet, the plugin seeds one immediately so management can start without waiting for the next boundary.

2. **Re-entrant reconciliation** — Each run computes a quarter key such as `2026-Q3`. If the managed topic for that quarter already exists, the script reuses it instead of creating a duplicate, then continues any remaining close/archive work for the previous quarter. This allows later runs to heal incomplete earlier runs, even if they happen after the exact boundary date.

3. **Managed topic tracking** — The plugin stores the current rotation state in `PluginStore` and marks managed topics with a quarter key custom field. On later runs it uses that explicit tracking to find the current and previous topics instead of guessing from category recency.

4. **Close → Archive** — The previous managed topic is closed first, then optionally archived. If a prior run created the new topic but did not finish the old-topic cleanup, a later run will resume and finish the missing steps.

5. **Per-category locking** — Rotation work runs under a per-category lock so overlapping automation executions do not create duplicate topics or race while closing the previous one.

## Testing

1. Create the automation as described above.
2. Check **"Skip quarter-boundary check"** so the script runs regardless of the current month.
3. Set the Recurring trigger to a short interval (e.g., every hour) or use a Point in time trigger set a few minutes in the future.
4. Watch the Discourse logs (`/admin/logs`) for entries prefixed with `[quarterly-topic-rotation]`.
5. Once confirmed working, uncheck the skip flag and set the trigger back to monthly.

### RSpec tests
**Note that RSpec tests are AI generated and have not yet been run in a Discourse install.**

Automated RSpec coverage lives in `spec/integration/quarterly_topic_rotation_spec.rb`. Run it from the root of a Discourse checkout with the plugin installed:

```sh
LOAD_PLUGINS=1 bundle exec rspec plugins/discourse-quarterly-topic-rotation/spec/integration/quarterly_topic_rotation_spec.rb
```

Or run the whole plugin spec suite via Discourse's plugin task:

```sh
bundle exec rake "plugin:spec[discourse-quarterly-topic-rotation]"
```

## Troubleshooting

- **"Not the first day of a quarter in Time.zone, and no bootstrap or recovery work is needed. Skipping."** — Expected behavior when the automation fires off-cycle after the category is already initialized and there is no incomplete cleanup to finish. Enable "Skip quarter-boundary check" if testing.
- **"Reusing managed topic"** or **"Adopted existing topic"** — Expected when the current quarter topic already exists and the plugin is reconciling the remaining work instead of creating a duplicate.
- **"Created initial managed topic"** — Expected on first setup when the chosen category has no managed topic yet.
- **Installed after the quarter boundary passed** — Expected to work. The first run bootstraps the current quarter's topic immediately if the category has no managed topic yet.
- **"Missing required fields"** — Check that category, title template, and post body are all configured in the automation settings.
- **"Category not found"** — The configured category may have been deleted or its ID changed.

## License

MIT
