# What the room or Telegram is told when the runtime reports error_kind
# "model_unavailable": the provider's CLI refused the resident's model before
# any request went out, because the model isn't offered to the subscription
# it runs on (Gemini 4 Argon left Antigravity's Pro plan on 2026-10-23 and
# Chris's runs failed silently for fourteen hours). The model named is the
# run's own structured model field, never error text.
class ModelUnavailableNotice

  def self.text(agent:, model:, link: true)
    label = AgentRuntimeInteraction.model_label_for(model).presence || "Its model"
    where = if link
      path = Rails.application.routes.url_helpers.edit_account_agent_path(agent.account, agent, tab: "settings")
      "[the resident's settings](#{path})"
    else
      "the resident's settings"
    end
    "#{label} isn't available on #{agent.name}'s subscription right now, so this run never reached a model. " \
      "Choose another model in #{where}, or wait for the provider to offer it again."
  end

end
