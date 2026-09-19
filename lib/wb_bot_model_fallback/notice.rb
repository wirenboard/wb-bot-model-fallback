# frozen_string_literal: true

module ::WbBotModelFallback
  # Плашка в начале ответа бота: «перешли на облегчённую версию», напоминание об этом каждые N ответов
  # облегчённой версии или «снова основная».
  # Тексты — настройки сайта; %{questions} — порог со склонённым словом («20 вопросов»),
  # %{answers} — только число, %{until} — конец срока по Москве. Модели не называются.
  module Notice
    TIME_ZONE = "Europe/Moscow"

    def self.add(reply, selector, switched:)
      return if !reply.is_a?(Post) || !reply.persisted? || reply.raw.blank?
      return if selector.author.nil?

      text =
        if switched
          if selector.take_switch_notice!
            switch_text(selector)
          elsif SiteSetting.wb_bot_model_fallback_notice_reminder.present? &&
                selector.take_reminder!
            render(SiteSetting.wb_bot_model_fallback_notice_reminder, selector)
          end
        elsif selector.take_return_notice!
          SiteSetting.wb_bot_model_fallback_notice_return
        end
      return if text.blank?

      quoted = text.strip.gsub(/\r?\n/, "\n> ")
      reply.revise(
        reply.user,
        { raw: "> #{quoted}\n\n#{reply.raw}" },
        skip_validations: true,
        skip_revision: true,
      )
    rescue StandardError => e
      Rails.logger.warn("[wb-bot-model-fallback] notice failed for post #{reply&.id}: #{e.message}")
    end

    def self.switch_text(selector)
      render(SiteSetting.wb_bot_model_fallback_notice_switch, selector)
    end

    def self.render(template, selector)
      return if template.blank?

      threshold = SiteSetting.wb_bot_model_fallback_daily_answers
      ends_at =
        Time.zone.now + (selector.latch_ttl || SiteSetting.wb_bot_model_fallback_hours.hours.to_i)
      format_template(
        template,
        answers: threshold.to_s,
        questions:
          I18n.with_locale(:ru) { I18n.t("wb_bot_model_fallback.questions", count: threshold) },
        until: ends_at.in_time_zone(TIME_ZONE).strftime("%d.%m в %H:%M"),
      )
    end

    # %{name} без исключений на незнакомые подстановки: администратор может написать любой текст
    def self.format_template(template, values)
      template.gsub(/%\{(\w+)\}/) do
        values.fetch(Regexp.last_match(1).to_sym, Regexp.last_match(0))
      end
    end
  end
end
