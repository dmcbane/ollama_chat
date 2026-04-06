defmodule OllamaChatWeb.MemoriesTabTest do
  use OllamaChatWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OllamaChat.Memory

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Opens the settings dialog and navigates to the Memories tab.
  defp open_memories_tab(view) do
    view |> element("#open-settings-btn") |> render_click()
    view |> element("#settings-tab-memories") |> render_click()
  end

  # Creates a memory with sensible defaults; merges in any overrides.
  defp create_memory!(overrides \\ %{}) do
    %{
      content: "User prefers Elixir over Ruby",
      memory_type: "fact",
      source: "user_manual"
    }
    |> Map.merge(overrides)
    |> Memory.create_memory!()
  end

  # ── Navigation ───────────────────────────────────────────────────────────────

  describe "memories tab navigation" do
    test "shows Memories tab button in settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("#open-settings-btn") |> render_click()

      assert has_element?(view, "#settings-tab-memories")
    end

    test "switches to memories tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      assert has_element?(view, "#settings-memories-tab-panel")
      refute has_element?(view, "#settings-general-tab-panel")
    end

    test "loads memories when switching to memories tab", %{conn: conn} do
      memory = create_memory!(%{content: "I love writing Elixir code every single day"})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      html = render(view)
      assert html =~ memory.content
    end
  end

  # ── Display ──────────────────────────────────────────────────────────────────

  describe "memories tab display" do
    test "shows empty state when no memories", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      assert has_element?(view, "#settings-memories-tab-panel")
      html = render(view)
      assert html =~ "No memories found"
    end

    test "shows memory list with multiple memories", %{conn: conn} do
      mem1 = create_memory!(%{content: "User loves functional programming paradigms"})
      mem2 = create_memory!(%{content: "User works on distributed systems at scale"})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      html = render(view)
      assert html =~ mem1.content
      assert html =~ mem2.content
    end

    test "shows memory stats section", %{conn: conn} do
      create_memory!(%{content: "Stats section test memory", importance: 0.7})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      html = render(view)
      assert html =~ "Total Memories"
    end

    test "shows memory importance as a percentage", %{conn: conn} do
      create_memory!(%{content: "High importance memory entry", importance: 0.9})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      html = render(view)
      # Importance is rendered as trunc(importance * 100)% — 0.9 → "90% importance"
      assert html =~ "90%"
    end

    test "shows memory type label", %{conn: conn} do
      create_memory!(%{content: "A preference memory entry", memory_type: "preference"})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      html = render(view)
      assert html =~ "preference"
    end
  end

  # ── Search ───────────────────────────────────────────────────────────────────

  describe "memory search" do
    test "filters memories by search query", %{conn: conn} do
      mem1 = create_memory!(%{content: "User prefers dark mode in all editors"})
      mem2 = create_memory!(%{content: "User knows Elixir and Phoenix very well"})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      render_hook(view, "memories_search", %{"query" => "dark mode"})

      html = render(view)
      assert html =~ mem1.content
      refute html =~ mem2.content
    end

    test "shows all memories when search query is cleared", %{conn: conn} do
      mem1 = create_memory!(%{content: "User prefers dark mode theme"})
      mem2 = create_memory!(%{content: "User enjoys writing tests first"})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      render_hook(view, "memories_search", %{"query" => "dark mode"})

      html = render(view)
      assert html =~ mem1.content
      refute html =~ mem2.content

      render_hook(view, "memories_search", %{"query" => ""})

      html = render(view)
      assert html =~ mem1.content
      assert html =~ mem2.content
    end
  end

  # ── Type Filter ──────────────────────────────────────────────────────────────

  describe "memory type filter" do
    test "filters memories by type", %{conn: conn} do
      fact =
        create_memory!(%{
          content: "Elixir is a functional language on the BEAM",
          memory_type: "fact"
        })

      pref =
        create_memory!(%{
          content: "User prefers concise, direct answers",
          memory_type: "preference"
        })

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      render_hook(view, "memories_filter_type", %{"type" => "fact"})

      html = render(view)
      assert html =~ fact.content
      refute html =~ pref.content
    end

    test "shows all memories when type filter is cleared", %{conn: conn} do
      fact =
        create_memory!(%{content: "OTP provides fault-tolerance primitives", memory_type: "fact"})

      pref =
        create_memory!(%{
          content: "User prefers pattern matching over conditionals",
          memory_type: "preference"
        })

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      render_hook(view, "memories_filter_type", %{"type" => "fact"})

      html = render(view)
      assert html =~ fact.content
      refute html =~ pref.content

      render_hook(view, "memories_filter_type", %{"type" => ""})

      html = render(view)
      assert html =~ fact.content
      assert html =~ pref.content
    end
  end

  # ── Editing ──────────────────────────────────────────────────────────────────

  describe "memory editing" do
    test "opens edit form when edit button is clicked", %{conn: conn} do
      memory = create_memory!(%{content: "Memory entry that will be edited inline"})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      view
      |> element("#edit-memory-btn-#{memory.id}")
      |> render_click()

      # Inline edit form is rendered with the entry's own ID
      assert has_element?(view, "#memory-edit-#{memory.id}")
    end

    test "cancels editing and closes the edit form", %{conn: conn} do
      memory = create_memory!(%{content: "Memory entry to edit then cancel"})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      view
      |> element("#edit-memory-btn-#{memory.id}")
      |> render_click()

      assert has_element?(view, "#memory-edit-#{memory.id}")

      # The cancel button is rendered per-entry
      view |> element("#cancel-edit-memory-#{memory.id}") |> render_click()

      refute has_element?(view, "#memory-edit-#{memory.id}")
    end

    test "saves memory changes and closes the edit form", %{conn: conn} do
      memory =
        create_memory!(%{
          content: "Memory whose importance will be updated",
          memory_type: "fact",
          importance: 0.5
        })

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      view
      |> element("#edit-memory-btn-#{memory.id}")
      |> render_click()

      assert has_element?(view, "#memory-edit-#{memory.id}")

      # save_memory receives id, importance, and memory_type as phx-value-* params
      render_hook(view, "save_memory", %{
        "id" => memory.id,
        "importance" => "0.8",
        "memory_type" => "preference"
      })

      # Edit form should be dismissed after a successful save
      refute has_element?(view, "#memory-edit-#{memory.id}")

      # Updated importance (0.8) is rendered as "80% importance"
      html = render(view)
      assert html =~ "80%"
    end
  end

  # ── Deletion ─────────────────────────────────────────────────────────────────

  describe "memory deletion" do
    test "deletes a single memory from the list", %{conn: conn} do
      memory = create_memory!(%{content: "This specific memory will be deleted permanently"})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      html = render(view)
      assert html =~ memory.content

      # The delete button lives inside the per-entry edit form — open it first
      view |> element("#edit-memory-btn-#{memory.id}") |> render_click()
      view |> element("#delete-memory-#{memory.id}") |> render_click()

      html = render(view)
      refute html =~ memory.content
    end

    test "deleted memory is removed from the database", %{conn: conn} do
      memory = create_memory!(%{content: "Memory that should be removed from the DB"})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      # Delete via the event directly — no need to drive the full edit-then-delete UI flow
      render_hook(view, "delete_memory", %{"id" => memory.id})

      assert {:ok, nil} = Memory.get_memory(memory.id)
    end

    test "deletes all memories and shows empty state", %{conn: conn} do
      mem1 = create_memory!(%{content: "First memory entry to be cleared away"})
      mem2 = create_memory!(%{content: "Second memory entry to be cleared away"})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      html = render(view)
      assert html =~ mem1.content
      assert html =~ mem2.content

      # The delete-all button only appears when the list is non-empty
      view |> element("#delete-all-memories-btn") |> render_click()

      html = render(view)
      refute html =~ mem1.content
      refute html =~ mem2.content
    end

    test "delete_all_memories removes all records from the database", %{conn: conn} do
      create_memory!(%{content: "Will be wiped — first"})
      create_memory!(%{content: "Will be wiped — second"})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      view |> element("#delete-all-memories-btn") |> render_click()

      assert {:ok, []} = Memory.list_memories()
    end
  end

  # ── Export ───────────────────────────────────────────────────────────────────

  describe "memory export" do
    test "export_memories pushes a download_file event to the client", %{conn: conn} do
      create_memory!(%{content: "Memory data to be exported as JSON", importance: 0.9})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      render_hook(view, "export_memories", %{})

      # push_event/3 sends atom-keyed payload: %{content: json, filename: ..., mime_type: ...}
      assert_push_event(view, "download_file", %{})
    end

    test "export_memories download payload contains the memory content", %{conn: conn} do
      create_memory!(%{content: "Exportable memory with unique content XYZ123"})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      render_hook(view, "export_memories", %{})

      # Payload uses atom keys from push_event/3
      assert_push_event(view, "download_file", %{content: content, filename: filename})
      assert content =~ "XYZ123"
      assert filename =~ "memories_"
      assert filename =~ ".json"
    end

    test "export_memories download payload includes mime_type", %{conn: conn} do
      create_memory!(%{content: "Another exportable memory entry"})

      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      render_hook(view, "export_memories", %{})

      assert_push_event(view, "download_file", %{mime_type: "application/json"})
    end

    test "export_memories works even when the memory store is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      open_memories_tab(view)

      # Event is sent directly via render_hook — no button required in the DOM
      render_hook(view, "export_memories", %{})

      assert_push_event(view, "download_file", %{content: content})
      # Empty store produces a JSON array with no entries
      assert content == "[]"
    end
  end
end
