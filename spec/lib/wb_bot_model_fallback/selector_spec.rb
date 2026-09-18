# frozen_string_literal: true

RSpec.describe WbBotModelFallback::Selector do
  fab!(:primary) { Fabricate(:llm_model, name: "primary-model") }
  fab!(:fallback) { Fabricate(:llm_model, name: "fallback-model") }
  fab!(:user)
  fab!(:other_user, :user)
  fab!(:moderator)
  fab!(:admin)
  fab!(:post) { Fabricate(:post, user: user) }

  def clear_latches
    [user, other_user, moderator, admin].each do |u|
      Discourse.redis.del(described_class.latch_key(u.id))
    end
  end

  before do
    enable_current_plugin
    SiteSetting.wb_bot_model_fallback_llm = fallback.id.to_s
    SiteSetting.wb_bot_model_fallback_daily_answers = 3
    clear_latches
  end

  after { clear_latches }

  # один ответ — несколько вызовов модели с одним post_id, как в настоящем журнале
  def log_answers(count, user: self.user, feature: "bot", at: 1.hour.ago, llm: primary, calls: 3)
    count.times do
      question = Fabricate(:post, user: user)
      calls.times do
        Fabricate(
          :ai_api_audit_log,
          user_id: user.id,
          post_id: question.id,
          feature_name: feature,
          llm_id: llm.id,
          created_at: at,
        )
      end
    end
  end

  def selected(author_post = post, current_model: primary)
    described_class.new(post: author_post, current_model: current_model).fallback_model
  end

  def latch_ttl(owner = user)
    Discourse.redis.ttl(described_class.latch_key(owner.id))
  end

  it "defaults to 20 answers, a 24-hour switch and no limit for staff" do
    expect(SiteSetting.defaults[:wb_bot_model_fallback_daily_answers]).to eq(20)
    expect(SiteSetting.defaults[:wb_bot_model_fallback_hours]).to eq(24)
    expect(SiteSetting.defaults[:wb_bot_model_fallback_exempt_staff]).to eq(true)
  end

  it "keeps the primary model below the threshold" do
    log_answers(2)
    expect(selected).to be_nil
    expect(latch_ttl).to eq(-2)
  end

  it "counts answers, not model calls" do
    log_answers(2, calls: 10)
    expect(selected).to be_nil
  end

  it "switches to the fallback model after the threshold for the configured hours" do
    log_answers(3)
    expect(selected).to eq(fallback)
    expect(latch_ttl).to be_within(5).of(24.hours.to_i)
  end

  it "keeps the fallback model for the whole period even without new answers" do
    log_answers(3)
    selected
    AiApiAuditLog.delete_all
    expect(selected).to eq(fallback)
  end

  it "does not extend the period on later questions" do
    log_answers(3)
    selected
    Discourse.redis.expire(described_class.latch_key(user.id), 100)
    selected
    expect(latch_ttl).to be <= 100
  end

  it "starts the count over after the period: old answers and fallback answers do not count" do
    log_answers(3, at: 25.hours.ago)
    log_answers(5, llm: fallback)
    expect(selected).to be_nil
  end

  it "uses the configured period for the switch and the counting window" do
    SiteSetting.wb_bot_model_fallback_hours = 6
    log_answers(3, at: 7.hours.ago)
    expect(selected).to be_nil
    log_answers(3, at: 1.hour.ago)
    expect(selected).to eq(fallback)
    expect(latch_ttl).to be_within(5).of(6.hours.to_i)
  end

  it "counts automation replies such as the weekend bot" do
    log_answers(3, feature: "automation - Weekend Auto-Reply")
    expect(selected).to eq(fallback)
  end

  it "does not count topic titles and other features" do
    log_answers(5, feature: "bot_title")
    log_answers(5, feature: "summarize")
    expect(selected).to be_nil
  end

  it "does not count other users' answers" do
    log_answers(5, user: other_user)
    expect(selected).to be_nil
  end

  it "does not limit staff" do
    [moderator, admin].each do |staff|
      log_answers(5, user: staff)
      expect(selected(Fabricate(:post, user: staff))).to be_nil
      expect(latch_ttl(staff)).to eq(-2)
    end
  end

  it "limits staff as well when the exemption is turned off" do
    SiteSetting.wb_bot_model_fallback_exempt_staff = false
    log_answers(3, user: moderator)
    expect(selected(Fabricate(:post, user: moderator))).to eq(fallback)
  end

  it "does nothing while no fallback model is selected" do
    SiteSetting.wb_bot_model_fallback_llm = ""
    log_answers(5)
    expect(selected).to be_nil
  end

  it "does nothing when the plugin is disabled" do
    SiteSetting.wb_bot_model_fallback_enabled = false
    log_answers(5)
    expect(selected).to be_nil
  end

  it "does nothing when the bot already uses the fallback model" do
    log_answers(5)
    expect(selected(current_model: fallback)).to be_nil
  end

  it "ignores posts written by bots and the system user" do
    log_answers(5)
    expect(selected(Fabricate(:post, user: Discourse.system_user))).to be_nil
  end
end
