# Walkthrough: discourse-quarterly-topic-rotation

*2026-04-06T07:16:04Z by Showboat 0.6.1*
<!-- showboat-id: 961a7b31-6e33-4c0f-b604-e87f70b23aed -->

## Goal

This walkthrough explains the plugin in the same order Discourse encounters it at runtime.
Because the repository is intentionally small, the most useful path is a linear one: start with the repo surface and admin-facing configuration, then step through the helper module, then follow the automation `script` from input parsing to topic reconciliation and cleanup.

## Linear Plan

1. Confirm the repository shape and where the real logic lives.
2. Read the setting and locale files that expose the feature in the admin UI.
3. Walk through the pure helper methods that compute quarters and render placeholders.
4. Walk through the persistence helpers that store rotation state and tag managed topics.
5. Read the `after_initialize` registration that wires the plugin into Discourse Automation.
6. Follow the top of the `script` block where runtime inputs are read and validated.
7. Follow the state-reconciliation branch that decides whether this run is bootstrap, normal rotation, or healing.
8. Follow the create/adopt/reuse branch for the current quarter topic.
9. Follow the old-topic cleanup branch that posts the closing message, closes, archives, and persists the new state.

```bash
rg --files
```

```output
walkthrough_discourse-quarterly-topic-rotation.md
AGENTS.md
README.md
plugin.rb
config/settings.yml
config/locales/server.en.yml
config/locales/client.en.yml
```

## 1. Repository Shape

The repository is almost entirely centered on `plugin.rb`.
That matters because there is no hidden service layer or secondary job class to chase: once you understand the helper module and the automation script inside `plugin.rb`, you understand the implementation.

```bash
cat config/settings.yml
```

```output
plugins:
  quarterly_topic_rotation_enabled:
    default: false
    client: true
```

```bash
sed -n '1,80p' config/locales/server.en.yml
```

```output
en:
  site_settings:
    quarterly_topic_rotation_enabled: "Enable the Quarterly Topic Rotation automation script."
```

```bash
sed -n '1,120p' config/locales/client.en.yml
```

```output
en:
  js:
    discourse_automation:
      scriptables:
        quarterly_topic_rotation:
          title: Quarterly Topic Rotation
          description: >
            Seeds a dedicated category on first setup, then rotates it on the first day
            of each quarter in Discourse's time zone while healing incomplete prior runs.
          fields:
            target_category:
              label: Category
              description: Use a dedicated category for the quarterly topics managed by this automation.
            title_template:
              label: Topic title template
              description: >
                Template for the new topic's title.
                Include a quarter placeholder so each run renders a unique title.
                Placeholders: {{quarter_label}} (e.g. "Q3 2026"), {{quarter}} (e.g. "Q3"), {{year}} (e.g. "2026").
            post_body_template:
              label: Opening post body
              description: >
                Template for the first post of the new topic. Same placeholders as the title.
            closing_message:
              label: Closing message (optional)
              description: >
                A final reply posted once in the old topic before it is closed.
                Additional placeholder: {{new_topic_url}} (link to the new topic).
            archive_old_topic:
              label: Archive old topic
              description: >
                If enabled, the old topic will be archived (hidden from category listing)
                in addition to being closed. If disabled, it will only be closed.
            skip_quarter_check:
              label: Skip quarter-boundary check
              description: >
                If enabled, the script runs every time the trigger fires (useful for
                testing). If disabled, it only creates new quarter topics on the first day
                of January, April, July, and October in Discourse's time zone, except for
                the initial first-run seed and later cleanup recovery.
```

## 2. Admin-Facing Surface

The plugin is guarded by the site setting `quarterly_topic_rotation_enabled`, which is declared in `config/settings.yml` and activated from `plugin.rb` with `enabled_site_setting`.

The client locale file is important because it tells you exactly what the automation exposes to admins: a dedicated category, templates for the new topic title and opening post, an optional closing message, a flag for archiving the old topic, and a `skip_quarter_check` escape hatch for testing.

Those locale strings also describe the intended operational model: one managed quarterly stream per category, quarter-boundary execution in Discourse's `Time.zone`, and recovery from incomplete prior runs.

```bash
nl -ba plugin.rb | sed -n '1,55p'
```

```output
     1	# frozen_string_literal: true
     2	
     3	# name: discourse-quarterly-topic-rotation
     4	# about: Automatically rotates topics on a quarterly basis — archives the current topic and creates a new one with the next quarter's label.
     5	# version: 0.1.0
     6	# authors: Your Name
     7	# url: https://github.com/your-org/discourse-quarterly-topic-rotation
     8	# required_version: 2.7.0
     9	
    10	enabled_site_setting :quarterly_topic_rotation_enabled
    11	
    12	module ::QuarterlyTopicRotation
    13	  PLUGIN_NAME = "discourse-quarterly-topic-rotation"
    14	  QUARTER_KEY_FIELD = "quarterly_topic_rotation_quarter_key"
    15	
    16	  # Returns [quarter_number, year] for a given date
    17	  def self.quarter_for(date)
    18	    q = ((date.month - 1) / 3) + 1
    19	    [q, date.year]
    20	  end
    21	
    22	  # Returns the label like "Q2 2026"
    23	  def self.quarter_label(date)
    24	    q, y = quarter_for(date)
    25	    "Q#{q} #{y}"
    26	  end
    27	
    28	  def self.quarter_key(date)
    29	    q, y = quarter_for(date)
    30	    "#{y}-Q#{q}"
    31	  end
    32	
    33	  # Returns true if the given date is the first day of a quarter in Time.zone
    34	  def self.quarter_boundary?(date)
    35	    date.day == 1 && [1, 4, 7, 10].include?(date.month)
    36	  end
    37	
    38	  # Applies placeholder substitution to a template string.
    39	  #
    40	  #   {{quarter_label}} => "Q3 2026"
    41	  #   {{quarter}}        => "Q3"
    42	  #   {{year}}           => "2026"
    43	  #   {{prev_quarter_label}} => "Q2 2026"
    44	  #
    45	  def self.apply_placeholders(template, date)
    46	    q, y = quarter_for(date)
    47	    prev_date = date - 3.months
    48	    prev_q, prev_y = quarter_for(prev_date)
    49	
    50	    template
    51	      .gsub("{{quarter_label}}", "Q#{q} #{y}")
    52	      .gsub("{{quarter}}", "Q#{q}")
    53	      .gsub("{{year}}", y.to_s)
    54	      .gsub("{{prev_quarter_label}}", "Q#{prev_q} #{prev_y}")
    55	  end
```

## 3. Quarter Math And Template Rendering

The file starts by declaring plugin metadata, enabling the site setting, and opening the `QuarterlyTopicRotation` module.

The first helper cluster is pure date logic:

- `quarter_for` converts a month into a quarter number plus year.
- `quarter_label` turns that into a human-readable label like `Q2 2026`.
- `quarter_key` turns it into a storage key like `2026-Q2`.
- `quarter_boundary?` is the gate that treats only January 1, April 1, July 1, and October 1 as normal rotation days.
- `apply_placeholders` is the template engine used for titles, opening posts, and closing messages.

Two details matter here.
First, everything is driven from the single `now = Time.zone.now` timestamp taken later in the script, so labels and guard checks stay consistent within a run.
Second, `apply_placeholders` also computes the previous quarter, which is why the optional closing message can mention both the outgoing and incoming period without any additional lookups.

```bash
nl -ba plugin.rb | sed -n '57,145p'
```

```output
    57	  def self.rotation_state(category_id)
    58	    state = PluginStore.get(PLUGIN_NAME, store_key(category_id))
    59	
    60	    case state
    61	    when Integer
    62	      { "current_topic_id" => state }
    63	    when Hash
    64	      state.transform_keys(&:to_s)
    65	    else
    66	      {}
    67	    end
    68	  end
    69	
    70	  def self.save_rotation_state(category_id, topic_id:, quarter_key:, at:)
    71	    PluginStore.set(
    72	      PLUGIN_NAME,
    73	      store_key(category_id),
    74	      {
    75	        "current_topic_id" => topic_id,
    76	        "current_quarter_key" => quarter_key,
    77	        "last_success_at" => at.iso8601,
    78	      }
    79	    )
    80	  end
    81	
    82	  def self.topic_from_state(state, category_id)
    83	    topic_id = state["current_topic_id"]
    84	    return if topic_id.blank?
    85	
    86	    topic = Topic.find_by(id: topic_id)
    87	    topic if topic&.category_id == category_id
    88	  end
    89	
    90	  def self.find_topic_by_quarter(category_id, quarter_key)
    91	    TopicCustomField
    92	      .joins(:topic)
    93	      .where(name: QUARTER_KEY_FIELD, value: quarter_key, topics: { category_id: category_id })
    94	      .order("topics.created_at DESC")
    95	      .first
    96	      &.topic
    97	  end
    98	
    99	  def self.find_previous_managed_topic(category_id, current_topic_id:, current_quarter_key:)
   100	    TopicCustomField
   101	      .joins(:topic)
   102	      .where(name: QUARTER_KEY_FIELD, topics: { category_id: category_id })
   103	      .where.not(topic_id: current_topic_id)
   104	      .where.not(value: current_quarter_key)
   105	      .order("topics.created_at DESC")
   106	      .first
   107	      &.topic
   108	  end
   109	
   110	  def self.find_adoptable_topic(category_id, title, quarter_key)
   111	    Topic
   112	      .where(category_id: category_id, title: title, user_id: Discourse.system_user.id)
   113	      .order(created_at: :desc)
   114	      .find do |topic|
   115	        stored_quarter_key = topic.custom_fields[QUARTER_KEY_FIELD]
   116	        stored_quarter_key.blank? || stored_quarter_key == quarter_key
   117	      end
   118	  end
   119	
   120	  def self.managed_topic_exists?(category_id)
   121	    TopicCustomField.joins(:topic).where(name: QUARTER_KEY_FIELD, topics: { category_id: category_id }).exists?
   122	  end
   123	
   124	  def self.managed_topic_in_category?(topic, category_id)
   125	    topic.present? && topic.category_id == category_id && topic.custom_fields[QUARTER_KEY_FIELD].present?
   126	  end
   127	
   128	  def self.mark_topic!(topic, quarter_key)
   129	    return if topic.custom_fields[QUARTER_KEY_FIELD] == quarter_key
   130	
   131	    topic.custom_fields[QUARTER_KEY_FIELD] = quarter_key
   132	    topic.save_custom_fields
   133	  end
   134	
   135	  def self.store_key(category_id)
   136	    "rotation_state_#{category_id}"
   137	  end
   138	
   139	  def self.lock_key(category_id)
   140	    "#{PLUGIN_NAME}:rotate:#{category_id}"
   141	  end
   142	
   143	  def self.log(level, message)
   144	    Rails.logger.public_send(level, "[quarterly-topic-rotation] #{message}")
   145	  end
```

## 4. Persisted State And Managed Topic Tracking

The next helper cluster explains how the plugin stays re-entrant instead of guessing from category recency.

- `rotation_state` reads per-category state from `PluginStore` under a deterministic key like `rotation_state_42`.
- It tolerates an older integer-only shape by converting it into `{ "current_topic_id" => state }`, which keeps the reader compatible with previously stored data.
- `save_rotation_state` writes the current topic id, the quarter key, and the last successful timestamp.
- `topic_from_state` validates that the stored topic still belongs to the configured category.
- `find_topic_by_quarter` finds the managed topic for the current quarter by reading the registered topic custom field.
- `find_previous_managed_topic` finds the most recent managed topic in the same category that is not the current one.
- `find_adoptable_topic` allows the script to adopt an already-created system topic with the expected title when that topic is either unmarked or already marked for the same quarter.
- `managed_topic_exists?`, `managed_topic_in_category?`, and `mark_topic!` define what counts as a managed topic and how topics become explicitly tracked.

The core design is that `PluginStore` answers “what did the last successful run think was current?” while the topic custom field answers “which concrete topics in this category are managed by this plugin?”
Using both lets the script recover if state is stale, incomplete, or partially written.

```bash
nl -ba plugin.rb | sed -n '148,185p'
```

```output
   148	register_topic_custom_field_type QuarterlyTopicRotation::QUARTER_KEY_FIELD, :string
   149	
   150	after_initialize do
   151	  reloadable_patch do
   152	    if defined?(DiscourseAutomation)
   153	      DiscourseAutomation::Scriptable.add(:quarterly_topic_rotation) do
   154	        # ── Admin-configurable fields (auto-rendered in the UI) ──
   155	
   156	        # The category where quarterly topics live
   157	        field :target_category, component: :category, required: true
   158	
   159	        # Title template for the new topic. Supports placeholders:
   160	        #   {{quarter_label}}  =>  "Q3 2026"
   161	        #   {{quarter}}        =>  "Q3"
   162	        #   {{year}}           =>  "2026"
   163	        field :title_template,
   164	              component: :text,
   165	              required: true
   166	
   167	        # Body template for the opening post of the new topic.
   168	        # Same placeholders as above.
   169	        field :post_body_template, component: :message, required: true
   170	
   171	        # Optional message posted as the final reply in the old topic
   172	        # before it is closed. Supports {{new_topic_url}} in addition
   173	        # to the standard date placeholders.
   174	        field :closing_message, component: :message, required: false
   175	
   176	        # Whether to archive the old topic (true) or just close it (false).
   177	        field :archive_old_topic, component: :boolean
   178	
   179	        # If false, the script will only act on the first day of
   180	        # quarter-boundary months (Jan, Apr, Jul, Oct). If true, it runs
   181	        # every time the trigger fires — useful for testing.
   182	        field :skip_quarter_check, component: :boolean
   183	
   184	        version 1
   185	        triggerables %i[recurring point_in_time]
```

## 5. Plugin Registration And Automation Fields

After the helper module, the plugin registers the topic custom field type and then waits for `after_initialize` so Discourse core and the automation plugin are available.

Inside `reloadable_patch`, it registers a new automation scriptable named `:quarterly_topic_rotation` if `DiscourseAutomation` is defined.
The `field` declarations are the bridge between the admin UI and runtime behavior: each later `fields.dig(..., "value")` lookup inside the script corresponds directly to one of these declarations.

`triggerables %i[recurring point_in_time]` tells you this logic is designed to run under Discourse Automation's own scheduling system rather than a plugin-defined background job.

```bash
nl -ba plugin.rb | sed -n '187,223p'
```

```output
   187	        script do |_context, fields, _automation|
   188	          now = Time.zone.now
   189	
   190	          skip_check = fields.dig("skip_quarter_check", "value") || false
   191	
   192	          # ── Read configuration ──
   193	          category_id = fields.dig("target_category", "value")
   194	          title_template = fields.dig("title_template", "value")
   195	          post_body_template = fields.dig("post_body_template", "value")
   196	          closing_message_template = fields.dig("closing_message", "value")
   197	          should_archive = fields.dig("archive_old_topic", "value") || false
   198	
   199	          unless category_id && title_template && post_body_template
   200	            QuarterlyTopicRotation.log(
   201	              :warn,
   202	              "Missing required fields. " \
   203	                "category_id=#{category_id} title_template=#{title_template.present?} " \
   204	                "post_body_template=#{post_body_template.present?}"
   205	            )
   206	            next
   207	          end
   208	
   209	          category = Category.find_by(id: category_id)
   210	          unless category
   211	            QuarterlyTopicRotation.log(:warn, "Category #{category_id} not found.")
   212	            next
   213	          end
   214	
   215	          DistributedMutex.synchronize(QuarterlyTopicRotation.lock_key(category.id)) do
   216	            quarter_key = QuarterlyTopicRotation.quarter_key(now)
   217	            new_title = QuarterlyTopicRotation.apply_placeholders(title_template, now)
   218	            new_post_body = QuarterlyTopicRotation.apply_placeholders(post_body_template, now)
   219	            state = QuarterlyTopicRotation.rotation_state(category.id)
   220	            state_topic = QuarterlyTopicRotation.topic_from_state(state, category.id)
   221	            managed_topic_exists = QuarterlyTopicRotation.managed_topic_exists?(category.id)
   222	            boundary_run = skip_check || QuarterlyTopicRotation.quarter_boundary?(now)
   223	
```

## 6. Script Entry: Time, Inputs, Validation, Locking

The runtime path begins inside the automation `script` block.

The script immediately captures `now = Time.zone.now`, then reads all admin-configured values from `fields`.
Before it does any real work, it checks that the required values exist and that the target category still exists.
If either precondition fails, it logs a warning and exits early.

The important operational safeguard is `DistributedMutex.synchronize(QuarterlyTopicRotation.lock_key(category.id))`.
That makes the rest of the run single-threaded per category, which prevents two overlapping automation executions from both deciding they need to create the next quarter's topic.

```bash
nl -ba plugin.rb | sed -n '224,263p'
```

```output
   224	            current_topic = nil
   225	
   226	            if state["current_quarter_key"] == quarter_key &&
   227	                 QuarterlyTopicRotation.managed_topic_in_category?(state_topic, category.id) &&
   228	                 state_topic.custom_fields[QuarterlyTopicRotation::QUARTER_KEY_FIELD] == quarter_key
   229	              current_topic = state_topic
   230	            end
   231	
   232	            current_topic ||= QuarterlyTopicRotation.find_topic_by_quarter(category.id, quarter_key)
   233	
   234	            adopted_topic = nil
   235	            if current_topic.nil?
   236	              adopted_topic = QuarterlyTopicRotation.find_adoptable_topic(category.id, new_title, quarter_key)
   237	              current_topic = adopted_topic if adopted_topic
   238	            end
   239	
   240	            bootstrap_run = !managed_topic_exists
   241	
   242	            previous_topic = nil
   243	            if state_topic.present? && state_topic.id != current_topic&.id
   244	              previous_topic = state_topic
   245	            end
   246	
   247	            previous_topic ||= QuarterlyTopicRotation.find_previous_managed_topic(
   248	              category.id,
   249	              current_topic_id: current_topic&.id,
   250	              current_quarter_key: quarter_key,
   251	            )
   252	
   253	            healing_run =
   254	              current_topic.present? &&
   255	                previous_topic.present? &&
   256	                (!previous_topic.closed? || (should_archive && !previous_topic.archived?))
   257	
   258	            unless boundary_run || bootstrap_run || healing_run
   259	              QuarterlyTopicRotation.log(
   260	                :info,
   261	                "Not the first day of a quarter in Time.zone (#{now.to_date}), and no bootstrap or recovery work is needed. Skipping."
   262	              )
   263	              next
```

## 7. The Reconciliation Decision Tree

This is the heart of the plugin.
Within the lock, the script computes the current quarter key and the rendered title/body, then gathers enough state to answer three questions:

1. Do we already have the current quarter topic?
2. Is this category being initialized for the first time?
3. Do we have leftover cleanup to finish from a previous quarter?

The resolution order is deliberate.
It first trusts `PluginStore` only if the stored quarter key matches the current one and the referenced topic is still a managed topic in the same category.
If that check fails, it falls back to a direct custom-field lookup with `find_topic_by_quarter`.
If that still fails, it looks for an adoptable system-created topic with the expected title.

After that, it derives three booleans:

- `bootstrap_run`: there are no managed topics yet in this category.
- `boundary_run`: either the admin explicitly skipped the quarter check or today is a real quarter boundary.
- `healing_run`: a current topic exists, a previous managed topic exists, and the previous one still needs to be closed or archived.

The `unless boundary_run || bootstrap_run || healing_run` guard is what keeps the automation safe to schedule monthly or even more often.
If none of those conditions is true, the run exits without creating duplicate topics or doing unnecessary work.

```bash
nl -ba plugin.rb | sed -n '266,304p'
```

```output
   266	            if current_topic.nil?
   267	              creator = PostCreator.new(
   268	                Discourse.system_user,
   269	                title: new_title,
   270	                raw: new_post_body,
   271	                category: category.id,
   272	              )
   273	
   274	              new_post = creator.create
   275	              if new_post.blank?
   276	                QuarterlyTopicRotation.log(
   277	                  :error,
   278	                  "Failed to create topic: #{creator.errors.full_messages.join(', ')}"
   279	                )
   280	                next
   281	              end
   282	
   283	              current_topic = new_post.topic
   284	              log_message = if bootstrap_run && !boundary_run
   285	                "Created initial managed topic: '#{current_topic.title}' (id=#{current_topic.id})"
   286	              else
   287	                "Created new topic: '#{current_topic.title}' (id=#{current_topic.id})"
   288	              end
   289	              QuarterlyTopicRotation.log(:info, log_message)
   290	            elsif adopted_topic
   291	              log_message = if bootstrap_run && !boundary_run
   292	                "Adopted existing topic as the initial managed topic for #{quarter_key}: '#{current_topic.title}' (id=#{current_topic.id})"
   293	              else
   294	                "Adopted existing topic for #{quarter_key}: '#{current_topic.title}' (id=#{current_topic.id})"
   295	              end
   296	              QuarterlyTopicRotation.log(:info, log_message)
   297	            else
   298	              QuarterlyTopicRotation.log(
   299	                :info,
   300	                "Reusing managed topic for #{quarter_key}: '#{current_topic.title}' (id=#{current_topic.id})"
   301	              )
   302	            end
   303	
   304	            QuarterlyTopicRotation.mark_topic!(current_topic, quarter_key)
```

## 8. Current Quarter Topic: Create, Adopt, Or Reuse

Once the guard is passed, the script resolves the current quarter topic in exactly one of three ways.

If `current_topic` is still `nil`, it creates a brand-new topic through `PostCreator.new(...).create`, using `Discourse.system_user` as the author.
That is the normal rotation path and also the fallback bootstrap path when there is no adoptable topic.

If `adopted_topic` is present, the script does not create anything new; it just logs that it adopted the existing topic for the current quarter.
This is how the plugin avoids duplicates when a matching system-authored topic already exists.

Otherwise it logs that it is reusing an already managed topic for the current quarter.
That is the branch that makes reruns safe.

In all three cases, the next line is `mark_topic!`, which ensures the winning topic is tagged with the quarter custom field before any cleanup of the old topic begins.

```bash
nl -ba plugin.rb | sed -n '306,378p'
```

```output
   306	            if previous_topic.present?
   307	              if closing_message_template.present? && !previous_topic.closed?
   308	                closing_body = QuarterlyTopicRotation
   309	                  .apply_placeholders(closing_message_template, now)
   310	                  .gsub("{{new_topic_url}}", current_topic.url)
   311	
   312	                unless Post.where(
   313	                         topic_id: previous_topic.id,
   314	                         user_id: Discourse.system_user.id,
   315	                         raw: closing_body,
   316	                       ).exists?
   317	                  closing_creator = PostCreator.new(
   318	                    Discourse.system_user,
   319	                    topic_id: previous_topic.id,
   320	                    raw: closing_body,
   321	                  )
   322	
   323	                  closing_post = closing_creator.create
   324	                  if closing_post.blank?
   325	                    QuarterlyTopicRotation.log(
   326	                      :error,
   327	                      "Failed to post closing message in topic '#{previous_topic.title}' " \
   328	                        "(id=#{previous_topic.id}): #{closing_creator.errors.full_messages.join(', ')}"
   329	                    )
   330	                    next
   331	                  end
   332	
   333	                  QuarterlyTopicRotation.log(
   334	                    :info,
   335	                    "Posted closing message in old topic: '#{previous_topic.title}' (id=#{previous_topic.id})"
   336	                  )
   337	                end
   338	              end
   339	
   340	              unless previous_topic.closed?
   341	                begin
   342	                  previous_topic.update_status("closed", true, Discourse.system_user)
   343	                  QuarterlyTopicRotation.log(
   344	                    :info,
   345	                    "Closed old topic: '#{previous_topic.title}' (id=#{previous_topic.id})"
   346	                  )
   347	                rescue StandardError => e
   348	                  QuarterlyTopicRotation.log(
   349	                    :error,
   350	                    "Failed to close old topic '#{previous_topic.title}' (id=#{previous_topic.id}): #{e.message}"
   351	                  )
   352	                  next
   353	                end
   354	              end
   355	
   356	              if should_archive && !previous_topic.archived?
   357	                begin
   358	                  previous_topic.update_status("archived", true, Discourse.system_user)
   359	                  QuarterlyTopicRotation.log(
   360	                    :info,
   361	                    "Archived old topic: '#{previous_topic.title}' (id=#{previous_topic.id})"
   362	                  )
   363	                rescue StandardError => e
   364	                  QuarterlyTopicRotation.log(
   365	                    :error,
   366	                    "Failed to archive old topic '#{previous_topic.title}' (id=#{previous_topic.id}): #{e.message}"
   367	                  )
   368	                  next
   369	                end
   370	              end
   371	            end
   372	
   373	            QuarterlyTopicRotation.save_rotation_state(
   374	              category.id,
   375	              topic_id: current_topic.id,
   376	              quarter_key: quarter_key,
   377	              at: now,
   378	            )
```

## 9. Previous Topic Cleanup And Final State Write

If there is a `previous_topic`, the script performs cleanup in a fixed order.

First, if a closing message template was configured and the old topic is not already closed, it renders the message, substitutes `{{new_topic_url}}`, and checks whether an identical system-authored post already exists.
That existence check is an idempotence guard: if a prior run already posted the closing message, a healing rerun will not post it twice.

Second, it closes the old topic unless it is already closed.
Third, if `archive_old_topic` is enabled, it archives the old topic unless it is already archived.
Each mutating step logs success, rescues failures, and exits early on error so the run does not falsely record a successful final state.

Only after the current topic is confirmed and the old-topic cleanup has succeeded does the script call `save_rotation_state`.
That final write is what makes the whole flow re-entrant: future runs can reuse the current topic, detect unfinished cleanup, and continue from a known good checkpoint.

## End-To-End Mental Model

The simplest way to hold the whole plugin in your head is this:

1. The admin config defines one quarterly stream for one category.
2. Each run computes the current quarter in `Time.zone`.
3. The script looks for the current managed topic via state, then via custom field, then via adoptable title match.
4. If the category is new, the date is a quarter boundary, or cleanup is incomplete, the run proceeds.
5. It creates or adopts the current topic if needed, marks it as managed, finishes closing and optionally archiving the previous one, then persists the new current state.

That combination of quarter-key tagging, persisted state, and per-category locking is the whole implementation strategy.
