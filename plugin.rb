# frozen_string_literal: true

# name: wb-bot-model-fallback
# about: После заданного числа ответов основной моделью за сутки переводит пользователя на запасную (более дешёвую) модель на сутки; сотрудники не ограничиваются
# version: 0.2.0
# authors: Wiren Board
# url: https://github.com/wirenboard/wb-bot-model-fallback
# required_version: 2026.7.0

enabled_site_setting :wb_bot_model_fallback_enabled

module ::WbBotModelFallback
  PLUGIN_NAME = "wb-bot-model-fallback"
end

after_initialize do
  next unless defined?(DiscourseAi::AiBot::Playground)

  require_relative "lib/wb_bot_model_fallback/selector"
  require_relative "lib/wb_bot_model_fallback/foreign_reasoning"
  require_relative "lib/wb_bot_model_fallback/playground_extension"

  # Модель ответа выбирается при создании бота; подменяем её для одного ответа.
  DiscourseAi::AiBot::Playground.prepend(WbBotModelFallback::PlaygroundExtension)

  # История переписки собирается здесь; убираем из неё рассуждения чужой модели.
  DiscourseAi::Completions::PromptMessagesBuilder.singleton_class.prepend(
    WbBotModelFallback::ForeignReasoning::BuilderClassExtension,
  )
  DiscourseAi::Completions::PromptMessagesBuilder.prepend(
    WbBotModelFallback::ForeignReasoning::BuilderExtension,
  )
end
