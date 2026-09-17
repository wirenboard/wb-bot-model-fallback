# frozen_string_literal: true

module ::WbBotModelFallback
  # Рассуждения модели Discourse сохраняет вместе с вызовами инструментов (post_custom_prompts) и
  # отправляет обратно в следующих ответах этой же переписки. Для Responses API это элементы
  # reasoning с зашифрованным содержимым. К модели они не привязаны, поэтому после переключения
  # запасная модель получила бы зашифрованные рассуждения основной, а когда пользователь вернётся
  # к основной, та получила бы рассуждения запасной. Такой запрос провайдер может отвергнуть.
  #
  # На время ответа запоминается модель, которой он генерируется, и из истории убираются
  # рассуждения постов, которые сгенерировала другая модель. Модель поста Discourse хранит в поле
  # ai_llm_model_id. Посты той же модели не трогаются, так что без переключений поведение прежнее.
  module ForeignReasoning
    CURRENT_MODEL = :wb_bot_model_fallback_current_model_id
    FOREIGN_STAMPS = :wb_bot_model_fallback_foreign_stamps

    def self.with_model(model_id)
      previous = Thread.current[CURRENT_MODEL]
      Thread.current[CURRENT_MODEL] = model_id
      yield
    ensure
      Thread.current[CURRENT_MODEL] = previous
    end

    def self.with_foreign(stamps)
      previous = Thread.current[FOREIGN_STAMPS]
      Thread.current[FOREIGN_STAMPS] = stamps
      yield
    ensure
      Thread.current[FOREIGN_STAMPS] = previous
    end

    # Время создания поста с точностью до микросекунды — ключ, по которому сообщения истории
    # сопоставляются с постами: построитель истории передаёт в push время поста, но не его id.
    def self.stamp(time)
      (time.to_r * 1_000_000).round
    end

    def self.foreign_stamps_for(post)
      model_id = Thread.current[CURRENT_MODEL]
      return nil if model_id.nil? || post&.topic_id.nil?

      PostCustomField
        .joins(:post)
        .where(
          name: DiscourseAi::AiBot::POST_AI_LLM_MODEL_ID_FIELD,
          posts: {
            topic_id: post.topic_id,
          },
        )
        .where.not(value: model_id.to_s)
        .pluck("posts.created_at")
        .map { |time| stamp(time) }
        .to_set
    end

    module BuilderClassExtension
      def messages_from_post(post, **kwargs)
        stamps = ForeignReasoning.foreign_stamps_for(post)
        return super if stamps.blank?

        ForeignReasoning.with_foreign(stamps) { super }
      end
    end

    module BuilderExtension
      def push(**kwargs)
        stamps = Thread.current[FOREIGN_STAMPS]
        if stamps && kwargs[:thinking] && kwargs[:created_at] &&
             stamps.include?(ForeignReasoning.stamp(kwargs[:created_at]))
          kwargs = kwargs.except(:thinking)
        end

        super(**kwargs)
      end
    end
  end
end
