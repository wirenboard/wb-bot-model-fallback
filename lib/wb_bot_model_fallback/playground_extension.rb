# frozen_string_literal: true

module ::WbBotModelFallback
  # Playground#reply_to — общий путь ответа бота: личные диалоги, упоминания и автоматизации
  # (Playground.reply_to_post). Модель ответа берётся из bot.model, поэтому на один ответ бот
  # подменяется копией с запасной моделью и после ответа возвращается.
  module PlaygroundExtension
    def reply_to(post, **kwargs, &blk)
      return super if !SiteSetting.wb_bot_model_fallback_enabled

      original_bot = @bot
      selector = Selector.new(post: post, current_model: original_bot&.model)
      target = selector.fallback_model

      if target
        @bot =
          DiscourseAi::Agents::Bot.as(original_bot.bot_user, agent: original_bot.agent, model: target)
        Rails.logger.info(
          "[wb-bot-model-fallback] topic=#{post.topic_id} post=#{post.id} user=#{post.user_id} " \
            "calls_24h=#{selector.calls_in_window} " \
            "threshold=#{SiteSetting.wb_bot_model_fallback_daily_calls} " \
            "model #{original_bot.model.id} -> #{target.id}",
        )
      end

      ForeignReasoning.with_model(@bot&.model&.id) { super }
    ensure
      @bot = original_bot if original_bot
    end
  end
end
