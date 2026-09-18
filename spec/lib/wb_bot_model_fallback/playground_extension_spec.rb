# frozen_string_literal: true

RSpec.describe WbBotModelFallback::PlaygroundExtension do
  fab!(:primary) { Fabricate(:llm_model, name: "primary-model", display_name: "Основная") }
  fab!(:fallback) { Fabricate(:llm_model, name: "fallback-model", display_name: "Запасная") }
  fab!(:bot_user) do
    SiteSetting.discourse_ai_enabled = true
    toggle_enabled_bots(bots: [primary])
    primary.reload.user
  end
  fab!(:user) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:pm) do
    Fabricate(
      :private_message_topic,
      user: user,
      topic_allowed_users: [
        Fabricate.build(:topic_allowed_user, user: user),
        Fabricate.build(:topic_allowed_user, user: bot_user),
      ],
    )
  end
  fab!(:question) do
    Fabricate(:post, topic: pm, user: user, post_number: 1, raw: "Как подключить реле?")
  end

  let(:agent) do
    AiAgent
      .find(DiscourseAi::Agents::Agent.system_agents[DiscourseAi::Agents::General])
      .class_instance
      .new
  end
  let(:bot) { DiscourseAi::Agents::Bot.as(bot_user, agent: agent) }
  let(:playground) { DiscourseAi::AiBot::Playground.new(bot) }

  before do
    # Порядок важен: смена discourse_ai_enabled пересобирает ботовых пользователей по списку
    # ai_bot_enabled_llms, а он в начале примера сброшен — без toggle бот-пользователь удалится.
    toggle_enabled_bots(bots: [primary])
    SiteSetting.discourse_ai_enabled = true
    SiteSetting.ai_embeddings_enabled = false
    enable_current_plugin
    SiteSetting.wb_bot_model_fallback_llm = fallback.id.to_s
    SiteSetting.wb_bot_model_fallback_daily_answers = 3
    Discourse.redis.del(WbBotModelFallback::Selector.latch_key(user.id))
  end

  after do
    AiAgent.agent_cache.flush!
    Discourse.redis.del(WbBotModelFallback::Selector.latch_key(user.id))
  end

  # ответы основной моделью: у каждого свой post_id и по три вызова, как в настоящем журнале
  def log_answers(count)
    count.times do
      answered = Fabricate(:post, user: user) # своя тема: в историю этого диалога не попадает
      3.times do
        Fabricate(
          :ai_api_audit_log,
          user_id: user.id,
          post_id: answered.id,
          llm_id: primary.id,
          feature_name: "bot",
          created_at: 1.hour.ago,
        )
      end
    end
  end

  def reply_to(post)
    reply = nil
    prompts = nil
    DiscourseAi::Completions::Llm.with_prepared_responses(["Ответ"]) do |_, _, recorded|
      reply = playground.reply_to(post, auto_set_title: false)
      prompts = recorded.dup
    end
    [reply, prompts]
  end

  def model_id_of(reply)
    reply.custom_fields[DiscourseAi::AiBot::POST_AI_LLM_MODEL_ID_FIELD].to_i
  end

  it "answers with the primary model below the threshold" do
    log_answers(2)
    reply, = reply_to(question)
    expect(model_id_of(reply)).to eq(primary.id)
  end

  it "answers with the fallback model once the threshold is reached and restores the bot" do
    log_answers(3)
    reply, = reply_to(question)
    expect(model_id_of(reply)).to eq(fallback.id)
    expect(playground.bot.model).to eq(primary)
  end

  it "keeps answering with the fallback model during the period" do
    log_answers(3)
    reply_to(question)
    AiApiAuditLog.delete_all
    reply, = reply_to(question)
    expect(model_id_of(reply)).to eq(fallback.id)
  end

  it "changes nothing when the plugin is disabled" do
    SiteSetting.wb_bot_model_fallback_enabled = false
    log_answers(10)
    reply, = reply_to(question)
    expect(model_id_of(reply)).to eq(primary.id)
  end

  context "with reasoning saved from an earlier answer of the primary model" do
    fab!(:earlier_answer) do
      Fabricate(
        :post,
        topic: pm,
        user: bot_user,
        post_number: 2,
        raw: "Ранний ответ",
        created_at: 5.minutes.ago,
      )
    end
    fab!(:follow_up) do
      Fabricate(:post, topic: pm, user: user, post_number: 3, raw: "А если на 24 В?")
    end

    before do
      earlier_answer.custom_fields[DiscourseAi::AiBot::POST_AI_LLM_MODEL_ID_FIELD] = primary.id
      earlier_answer.save_custom_fields
      PostCustomPrompt.create!(
        post: earlier_answer,
        custom_prompt: [
          [
            "Ранний ответ",
            bot_user.username,
            nil,
            nil,
            {
              "message" => "рассуждение",
              "provider_info" => {
                "open_ai_responses" => {
                  "reasoning_id" => "rs_1",
                  "encrypted_content" => "enc-primary",
                },
              },
            },
          ],
        ],
      )
    end

    def encrypted_sent(prompts)
      prompts
        .flat_map(&:messages)
        .filter_map { |m| m.dig(:thinking_provider_info, :open_ai_responses, :encrypted_content) }
    end

    it "still sends same-model reasoning below the threshold" do
      _, prompts = reply_to(follow_up)
      expect(encrypted_sent(prompts)).to eq(["enc-primary"])
    end

    it "does not send the primary model's reasoning to the fallback model" do
      log_answers(3)
      reply, prompts = reply_to(follow_up)
      expect(model_id_of(reply)).to eq(fallback.id)
      expect(encrypted_sent(prompts)).to be_empty
    end
  end
end
