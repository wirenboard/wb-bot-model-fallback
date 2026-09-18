# frozen_string_literal: true

module ::WbBotModelFallback
  # Решает, генерировать ли ответ на пост запасной моделью.
  #
  # Правило: у пользователя N ответов основной моделью за скользящие сутки. Следующий вопрос
  # переводит его на запасную модель на заданный срок (по умолчанию сутки), потом счёт начинается
  # заново. Ответ — пост пользователя, на который отвечал бот: в журнале AiApiAuditLog это разные
  # post_id, сколько бы вызовов модели ни ушло на один ответ. Ответы запасной модели не считаются —
  # иначе активный пользователь после срока сразу возвращался бы на запасную. Учитываются личные
  # диалоги (feature "bot") и ответы автоматизаций (feature "automation - …", например ночной бот).
  # Сотрудники (staff) по умолчанию не ограничены.
  #
  # Срок — ключ в Redis со временем жизни. Ставится один раз (NX) и не продлевается. Вместе с ним
  # ставятся два флага для сообщений пользователю: «перешёл на облегчённую версию» (снимается после
  # первого удачного ответа запасной модели) и «был на облегчённой» (снимается после первого удачного
  # ответа основной модели, когда срок кончился). Флаги снимаются только после удачного ответа, чтобы
  # сообщение не потерялось, если ответ не получился.
  class Selector
    COUNTED_FEATURES_SQL = "(feature_name = 'bot' OR feature_name LIKE 'automation - %')"
    # сколько после конца срока помнить, что пользователь был на запасной, чтобы сказать о возврате
    RETURN_NOTICE_GRACE = 7.days

    def self.fallback_llm_id
      value = SiteSetting.wb_bot_model_fallback_llm.to_s.strip
      value.presence&.to_i
    end

    def self.window
      SiteSetting.wb_bot_model_fallback_hours.hours
    end

    def self.latch_key(user_id)
      "wb_bot_model_fallback:until:#{user_id}"
    end

    def self.switch_notice_key(user_id)
      "wb_bot_model_fallback:notice_switch:#{user_id}"
    end

    def self.return_notice_key(user_id)
      "wb_bot_model_fallback:notice_return:#{user_id}"
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
      return nil if SiteSetting.wb_bot_model_fallback_exempt_staff && author.staff?

      target = LlmModel.find_by(id: target_id)
      return nil if target.nil?
      return target if latched?
      return nil if primary_answers_in_window < SiteSetting.wb_bot_model_fallback_daily_answers

      latch!
      target
    end

    def latched?
      Discourse.redis.exists?(self.class.latch_key(author.id))
    end

    # Сообщение «перешёл на облегчённую версию» ещё не показано: снимаем флаг, если он был.
    def take_switch_notice!
      Discourse.redis.del(self.class.switch_notice_key(author.id)).to_i > 0
    end

    # Срок кончился, а о возврате на основную модель пользователю ещё не сказали.
    def take_return_notice!
      return false if latched?

      Discourse.redis.del(self.class.return_notice_key(author.id)).to_i > 0
    end

    # Секунды до конца срока на запасной модели; nil — срока нет.
    def latch_ttl
      ttl = Discourse.redis.ttl(self.class.latch_key(author.id))
      ttl.positive? ? ttl : nil
    end

    def primary_answers_in_window
      @primary_answers_in_window ||=
        AiApiAuditLog
          .where(user_id: author.id)
          .where("created_at > ?", self.class.window.ago)
          .where(COUNTED_FEATURES_SQL)
          .where.not(post_id: nil)
          .where("llm_id IS NULL OR llm_id <> ?", self.class.fallback_llm_id)
          .distinct
          .count(:post_id)
    end

    def author
      @post&.user
    end

    private

    def latch!
      seconds = self.class.window.to_i
      set =
        Discourse.redis.set(
          self.class.latch_key(author.id),
          Time.zone.now.to_i,
          ex: seconds,
          nx: true,
        )
      return if !set

      Discourse.redis.set(self.class.switch_notice_key(author.id), 1, ex: seconds)
      Discourse.redis.set(
        self.class.return_notice_key(author.id),
        1,
        ex: seconds + RETURN_NOTICE_GRACE.to_i,
      )
    end
  end
end
