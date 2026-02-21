defmodule OllamaChat.Markdown do
  @moduledoc """
  Renders markdown content to safe HTML using MDEx (comrak).
  Used for formatting assistant messages with GFM support and syntax highlighting.
  """

  @doc """
  Renders a markdown string to HTML safe for HEEx interpolation.

  Returns `{:safe, html}` on success, or a safe `<pre>` fallback on error.
  """
  def render(markdown) when is_binary(markdown) do
    case MDEx.to_html(markdown,
           extension: [strikethrough: true, table: true, autolink: true],
           render: [unsafe_: true],
           syntax_highlight: [formatter: {:html_inline, theme: "catppuccin_mocha"}]
         ) do
      {:ok, html} ->
        {:safe, html}

      {:error, _reason} ->
        escaped = markdown |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
        {:safe, "<pre>" <> escaped <> "</pre>"}
    end
  end

  def render(nil), do: {:safe, ""}
  def render(""), do: {:safe, ""}
end
