defmodule OllamaChat.Repo do
  use Ecto.Repo,
    otp_app: :ollama_chat,
    adapter: Ecto.Adapters.Postgres
end
