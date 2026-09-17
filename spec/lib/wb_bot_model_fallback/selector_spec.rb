# frozen_string_literal: true

RSpec.describe WbBotModelFallback::Selector do
  fab!(:primary) { Fabricate(:llm_model, name: "primary-model") }
  fab!(:fallback) { Fabricate(:llm_model, name: "fallback-model") }
  fab!(:user)
  fab!(:other_user, :user)
  fab!(:post) { Fabricate(:post, user: user) }

  before do
    enable_current_plugin
    SiteSetting.wb_bot_model_fallback_llm = fallback.id.to_s
    SiteSetting.wb_bot_model_fallback_daily_calls = 3
  end

  def log_calls(count, user: self.user, feature: "bot", at: 1.hour.ago)
    count.times do
      Fabricate(:ai_api_audit_log, user_id: user.id, feature_name: feature, created_at: at)
    end
  end

  def selected(current_model: primary)
    described_class.new(post: post, current_model: current_model).fallback_model
  end

  it "defaults the threshold to 40 calls" do
    expect(SiteSetting.defaults[:wb_bot_model_fallback_daily_calls]).to eq(40)
  end

  it "keeps the primary model below the threshold" do
    log_calls(2)
    expect(selected).to be_nil
  end

  it "switches to the fallback model once the threshold is reached" do
    log_calls(3)
    expect(selected).to eq(fallback)
  end

  it "counts automation replies such as the weekend bot" do
    log_calls(3, feature: "automation - Weekend Auto-Reply")
    expect(selected).to eq(fallback)
  end

  it "does not count topic titles and other features" do
    log_calls(5, feature: "bot_title")
    log_calls(5, feature: "summarize")
    expect(selected).to be_nil
  end

  it "does not count calls older than 24 hours" do
    log_calls(5, at: 25.hours.ago)
    expect(selected).to be_nil
  end

  it "does not count other users' calls" do
    log_calls(5, user: other_user)
    expect(selected).to be_nil
  end

  it "does nothing while no fallback model is selected" do
    SiteSetting.wb_bot_model_fallback_llm = ""
    log_calls(5)
    expect(selected).to be_nil
  end

  it "does nothing when the plugin is disabled" do
    SiteSetting.wb_bot_model_fallback_enabled = false
    log_calls(5)
    expect(selected).to be_nil
  end

  it "does nothing when the bot already uses the fallback model" do
    log_calls(5)
    expect(selected(current_model: fallback)).to be_nil
  end

  it "ignores posts written by bots and the system user" do
    log_calls(5)
    bot_post = Fabricate(:post, user: Discourse.system_user)
    expect(described_class.new(post: bot_post, current_model: primary).fallback_model).to be_nil
  end
end
