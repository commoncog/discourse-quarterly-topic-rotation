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
else
  RSpec.describe "Quarterly topic rotation automation" do
    it "requires Discourse Automation to be loaded" do
      skip "DiscourseAutomation is not available in this test environment"
    end
  end
end
