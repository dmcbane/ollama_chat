defmodule OllamaChat.MarkdownTest do
  use ExUnit.Case, async: true

  alias OllamaChat.Markdown

  describe "render/1" do
    test "renders basic markdown to safe HTML" do
      {:safe, html} = Markdown.render("**bold** and *italic*")
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<em>italic</em>"
    end

    test "renders code blocks with syntax highlighting" do
      {:safe, html} = Markdown.render("```elixir\ndefmodule Foo do\nend\n```")
      assert html =~ "<pre"
      assert html =~ "<code"
      assert html =~ "language-elixir"
      # catppuccin_mocha inline styles should be present
      assert html =~ "style="
    end

    test "renders GFM tables" do
      md = """
      | Name | Value |
      |------|-------|
      | a    | 1     |
      """

      {:safe, html} = Markdown.render(md)
      assert html =~ "<table>"
      assert html =~ "<th>"
      assert html =~ "<td>"
    end

    test "renders GFM strikethrough" do
      {:safe, html} = Markdown.render("~~deleted~~")
      assert html =~ "<del>deleted</del>"
    end

    test "renders autolinks" do
      {:safe, html} = Markdown.render("Visit https://example.com for more")
      assert html =~ "<a"
      assert html =~ "https://example.com"
    end

    test "renders headings" do
      {:safe, html} = Markdown.render("# Title\n## Subtitle")
      assert html =~ "<h1>Title</h1>"
      assert html =~ "<h2>Subtitle</h2>"
    end

    test "renders lists" do
      {:safe, html} = Markdown.render("- item 1\n- item 2")
      assert html =~ "<ul>"
      assert html =~ "<li>"
    end

    test "renders blockquotes" do
      {:safe, html} = Markdown.render("> quoted text")
      assert html =~ "<blockquote>"
    end

    test "renders inline code" do
      {:safe, html} = Markdown.render("Use `mix test` to run tests")
      assert html =~ "<code>"
      assert html =~ "mix test"
    end

    test "returns safe empty string for nil" do
      assert Markdown.render(nil) == {:safe, ""}
    end

    test "returns safe empty string for empty string" do
      assert Markdown.render("") == {:safe, ""}
    end

    test "handles plain text without markdown" do
      {:safe, html} = Markdown.render("Just plain text")
      assert html =~ "Just plain text"
    end

    test "always returns a {:safe, binary} tuple" do
      {:safe, html} = Markdown.render("anything")
      assert is_binary(html)
    end
  end
end
