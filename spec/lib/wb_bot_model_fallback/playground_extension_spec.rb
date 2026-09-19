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
    clear_keys
  end

  after do
    AiAgent.agent_cache.flush!
    clear_keys
  end

  def clear_keys
    %i[latch_key switch_notice_key return_notice_key].each do |k|
      Discourse.redis.del(WbBotModelFallback::Selector.public_send(k, user.id))
    end
    (1..5).each { |n| Discourse.redis.del(WbBotModelFallback::Selector.reminder_key(user.id, n)) }
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

  # вызовы одного ответа запасной моделью в журнале: заглушка ответов его не пишет
  def log_fallback_answer
    answered = Fabricate(:post, user: user)
    Fabricate(
      :ai_api_audit_log,
      user_id: user.id,
      post_id: answered.id,
      llm_id: fallback.id,
      feature_name: "bot",
    )
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

  it "tells the user once that the lighter version answers now, without naming models" do
    log_answers(3)
    reply, = reply_to(question)
    expect(reply.raw).to match(
      /\A> \*\*Вы задали помощнику 3 вопроса за сутки\. До \d\d\.\d\d в \d\d:\d\d \(МСК\)/,
    )
    expect(reply.raw).to end_with("Ответ")
    expect(reply.raw).not_to include(fallback.display_name, primary.display_name)
    expect(reply.revisions).to be_empty

    second, = reply_to(question)
    expect(model_id_of(second)).to eq(fallback.id)
    expect(second.raw).not_to start_with(">")
  end

  it "tells the user once that the main version is back after the period" do
    log_answers(3)
    reply_to(question)
    Discourse.redis.del(WbBotModelFallback::Selector.latch_key(user.id))
    AiApiAuditLog.update_all("created_at = created_at - interval '25 hours'")

    back, = reply_to(question)
    expect(model_id_of(back)).to eq(primary.id)
    expect(back.raw).to start_with("> **Снова отвечает основная версия помощника.**")

    later, = reply_to(question)
    expect(later.raw).not_to start_with(">")
  end

  it "reminds on every N-th answer of the lighter version, with the time the main one is back" do
    SiteSetting.wb_bot_model_fallback_reminder_every = 2
    log_answers(3)
    first, = reply_to(question)
    expect(first.raw).to start_with("> **Вы задали помощнику")
    log_fallback_answer # вызовы первого ответа запасной

    notices =
      4.times.map do
        log_fallback_answer # вызовы ответа, который сейчас напишет запасная
        reply, = reply_to(question)
        expect(model_id_of(reply)).to eq(fallback.id)
        reply.raw[/\A> .*$/]
      end

    # ответы запасной № 2–5: напоминание в 3-м и 5-м
    expect(notices.map(&:present?)).to eq([false, true, false, true])
    expect(notices[1]).to match(
      /\A> \*\*Напоминаем: сейчас на вопросы отвечает облегчённая версия помощника\. Основная версия вернётся \d\d\.\d\d в \d\d:\d\d \(МСК\)\.\*\*\z/,
    )
    # текст сверен целиком, так что названий моделей в нём нет; второе напоминание такое же
    expect(notices[3]).to eq(notices[1])
  end

  it "shows no reminder when its text is empty" do
    SiteSetting.wb_bot_model_fallback_reminder_every = 1
    SiteSetting.wb_bot_model_fallback_notice_reminder = ""
    log_answers(3)
    reply_to(question)
    2.times { log_fallback_answer }
    reply, = reply_to(question)
    expect(model_id_of(reply)).to eq(fallback.id)
    expect(reply.raw).to eq("Ответ")
  end

  it "shows no notice when the texts are empty" do
    SiteSetting.wb_bot_model_fallback_notice_switch = ""
    log_answers(3)
    reply, = reply_to(question)
    expect(model_id_of(reply)).to eq(fallback.id)
    expect(reply.raw).to eq("Ответ")
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
