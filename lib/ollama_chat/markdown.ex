defmodule OllamaChat.Markdown do
  @moduledoc """
  Renders markdown content to safe HTML using MDEx (comrak).
  Used for formatting assistant messages with GFM support and syntax highlighting.
  """

  require Logger

  @doc """
  Renders a markdown string to an HTML string (not wrapped in {:safe, ...}).
  Use this when storing HTML that needs to be JSON-serializable.

  Returns a plain HTML string on success, or an escaped `<pre>` fallback on error.
  """
  def render_to_string(markdown) when is_binary(markdown) do
    case MDEx.to_html(markdown,
           extension: [strikethrough: true, table: true, autolink: true],
           render: [unsafe_: true],
           syntax_highlight: [formatter: {:html_inline, theme: "catppuccin_mocha"}]
         ) do
      {:ok, html} ->
        html

      {:error, reason} ->
        Logger.warning("MDEx failed to render markdown: #{inspect(reason)}")
        escaped = markdown |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
        "<pre>" <> escaped <> "</pre>"
    end
  end

  def render_to_string(nil), do: ""
  def render_to_string(""), do: ""

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

      {:error, reason} ->
        Logger.warning("MDEx failed to render markdown: #{inspect(reason)}")
        escaped = markdown |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
        {:safe, "<pre>" <> escaped <> "</pre>"}
    end
  end

  def render(nil), do: {:safe, ""}
  def render(""), do: {:safe, ""}
end
