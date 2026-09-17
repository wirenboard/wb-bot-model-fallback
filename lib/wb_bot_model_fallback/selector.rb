# frozen_string_literal: true

module ::WbBotModelFallback
  # Решает, генерировать ли ответ на пост запасной моделью.
  #
  # Считает вызовы модели от имени автора поста за последние 24 часа по журналу AiApiAuditLog.
  # Журнал пишет каждый вызов, в том числе промежуточные вызовы инструментов, поэтому порог задан
  # в вызовах, а не в ответах: один ответ бота обычно 3–4 вызова. В счёт идут ответы в личных
  # диалогах (feature "bot") и ответы автоматизаций (feature "automation - …", например ночной бот).
  class Selector
    WINDOW = 24.hours
    COUNTED_FEATURES_SQL = "(feature_name = 'bot' OR feature_name LIKE 'automation - %')"

    def self.fallback_llm_id
      value = SiteSetting.wb_bot_model_fallback_llm.to_s.strip
      value.presence&.to_i
    end

    def initialize(post:, current_model:)
      @post = post
      @current_model = current_model
    end

    # LlmModel, которой надо сгенерировать ответ, или nil — оставить основную.
    def fallback_model
      return nil if !SiteSetting.wb_bot_model_fallback_enabled

      target_id = self.class.fallback_llm_id
      return nil if target_id.nil? || @current_model.nil? || @current_model.id == target_id
      return nil if author.nil? || author.id <= 0
      return nil if calls_in_window < SiteSetting.wb_bot_model_fallback_daily_calls

      LlmModel.find_by(id: target_id)
    end

    def calls_in_window
      @calls_in_window ||=
        AiApiAuditLog
          .where(user_id: author.id)
          .where("created_at > ?", WINDOW.ago)
          .where(COUNTED_FEATURES_SQL)
          .count
    end

    def author
      @post&.user
    end
  end
end
