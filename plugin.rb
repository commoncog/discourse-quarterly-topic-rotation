# frozen_string_literal: true

# name: discourse-quarterly-topic-rotation
# about: Automatically rotates topics on a quarterly basis — archives the current topic and creates a new one with the next quarter's label.
# version: 0.1.0
# authors: Cedric Chin
# url: https://github.com/commoncog/discourse-quarterly-topic-rotation
# required_version: 2.7.0

enabled_site_setting :quarterly_topic_rotation_enabled

module ::QuarterlyTopicRotation
  PLUGIN_NAME = "discourse-quarterly-topic-rotation"
  QUARTER_KEY_FIELD = "quarterly_topic_rotation_quarter_key"

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

  # Returns true if the given date is the first day of a quarter in Time.zone
  def self.quarter_boundary?(date)
    date.day == 1 && [1, 4, 7, 10].include?(date.month)
  end

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

  def self.find_adoptable_topic(category_id, title, quarter_key)
    Topic
      .where(category_id: category_id, title: title, user_id: Discourse.system_user.id)
      .order(created_at: :desc)
      .find do |topic|
        stored_quarter_key = topic.custom_fields[QUARTER_KEY_FIELD]
        stored_quarter_key.blank? || stored_quarter_key == quarter_key
      end
  end

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
end

register_topic_custom_field_type QuarterlyTopicRotation::QUARTER_KEY_FIELD, :string

after_initialize do
  reloadable_patch do
    if defined?(DiscourseAutomation)
      DiscourseAutomation::Scriptable.add(:quarterly_topic_rotation) do
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
            end

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
