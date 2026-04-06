defmodule OllamaChat.Memory.Extractor do
  @moduledoc """
  Automatically extracts memories and summaries from completed conversations.

  ## Overview

  After a conversation ends (i.e. the user starts a new one with enough
  messages), the Extractor:

  1. Sends the conversation to the LLM with a structured extraction prompt.
  2. Parses the JSON array response into candidate memory items.
  3. Deduplicates each candidate against existing memories via pgvector
     cosine-distance similarity.
  4. Saves unique memories with `source: "auto_extract"`.
  5. Generates and stores a concise `ConversationSummary` record.

  ## Non-blocking Usage

  Use `extract_and_save_async/3` to fire-and-forget extraction inside a
  background `Task`.  The calling process (ChatLive) is not blocked.

      Memory.Extractor.extract_and_save_async(conversation_id, messages)

  ## Testability

  All LLM calls accept an optional `:chat_fn` keyword override, and all
  embedding operations accept an optional `:embedding_fn` keyword override.
  This enables unit testing without a running Ollama instance.

      Extractor.deduplicate(text, embedding_fn: fn _ -> {:ok, my_vec} end)

  ## Configuration

  | App config key                        | Default | Description                            |
  |---------------------------------------|---------|----------------------------------------|
  | `:memory_extraction_min_messages`     | 5       | Min messages before extraction runs   |
  | `:memory_extraction_dedup_threshold`  | 0.15    | Cosine distance below which = dupe    |

  ## Error Handling

  All public functions return `{:ok, result}` or `{:error, reason}` tuples.
  Errors are never swallowed — callers can always distinguish success from failure.
  """

  require Logger

  alias OllamaChat.Memory
  alias OllamaChat.Memory.ConversationSummary
  alias OllamaChat.OllamaClient

  # Default cosine-distance threshold for deduplication.
  # pgvector reports cosine distance in [0.0, 2.0] where 0.0 = identical vectors.
  # 0.15 corresponds to roughly ≥ 0.85 cosine similarity.
  @default_dedup_threshold 0.15

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Returns `true` if the conversation is long enough to trigger extraction.

  The threshold is read from the `:memory_extraction_min_messages` app config
  key, defaulting to 5.
  """
  @spec should_extract?(messages :: list()) :: boolean()
  def should_extract?(messages) when is_list(messages) do
    length(messages) >= min_messages_threshold()
  end

  @doc """
  Asynchronously extracts memories and summarises a conversation.

  Spawns a background `Task` that runs `extract_from_conversation/3` then
  `summarize/3`.  Returns `:ok` immediately — the calling process is not
  blocked.  All errors are logged but not propagated.

  ## Options

  Accepts the same options as `extract_from_conversation/3` and `summarize/3`.
  """
  @spec extract_and_save_async(
          conversation_id :: String.t(),
          messages :: list(map()),
          opts :: keyword()
        ) :: :ok
  def extract_and_save_async(conversation_id, messages, opts \\ []) do
    Task.start(fn ->
      Logger.info(
        "Async memory extraction started for conversation=#{conversation_id} " <>
          "(#{length(messages)} messages)"
      )

      case extract_from_conversation(conversation_id, messages, opts) do
        {:ok, %{memories_saved: saved, memories_skipped: skipped}} ->
          Logger.info(
            "Memory extraction complete for conversation=#{conversation_id}: " <>
              "#{saved} saved, #{skipped} skipped"
          )

        {:error, reason} ->
          Logger.warning(
            "Memory extraction failed for conversation=#{conversation_id}: #{inspect(reason)}"
          )
      end

      case summarize(conversation_id, messages, opts) do
        {:ok, _summary} ->
          Logger.info("Conversation summary stored for conversation=#{conversation_id}")

        {:error, reason} ->
          Logger.warning(
            "Conversation summarization failed for conversation=#{conversation_id}: " <>
              inspect(reason)
          )
      end
    end)

    :ok
  end

  @doc """
  Extracts memories from a completed conversation and saves them to the database.

  Sends the conversation to the LLM with a structured JSON extraction prompt,
  parses the response, deduplicates candidates against existing memories, and
  persists unique ones with `source: "auto_extract"`.

  Returns `{:ok, %{memories_saved: integer, memories_skipped: integer}}` on
  success.

  ## Options

  - `:chat_fn` — Override the LLM call. Signature:
    `(messages :: list(map()), opts :: keyword()) -> {:ok, response} | {:error, reason}`.
    Defaults to `OllamaClient.chat/2`.
  - `:embedding_fn` — Override embedding generation. Signature:
    `(text :: String.t()) -> {:ok, list(float())} | {:error, reason}`.
    Defaults to `OllamaClient.generate_embedding/1`.
  - `:dedup_threshold` — Cosine distance threshold (default: #{@default_dedup_threshold}).
    Memories within this distance are considered duplicates and skipped.
  - `:model` — Ollama model to use for extraction (default: configured default).
  """
  @spec extract_from_conversation(
          conversation_id :: String.t(),
          messages :: list(map()),
          opts :: keyword()
        ) ::
          {:ok, %{memories_saved: non_neg_integer(), memories_skipped: non_neg_integer()}}
          | {:error, term()}
  def extract_from_conversation(conversation_id, messages, opts \\ []) do
    if Memory.enabled?() do
      do_extract(conversation_id, messages, opts)
    else
      {:error, :memory_disabled}
    end
  end

  @doc """
  Checks whether a candidate memory text is a semantic duplicate of an
  existing memory.

  Generates an embedding for `text`, then searches for existing memories
  whose stored embedding is within the deduplication distance threshold.

  Returns `:new` when no duplicate is found, or `{:duplicate, %Entry{}}`
  when one is.  When embedding generation fails, `:new` is returned — when
  in doubt, it is better to save the memory than to silently lose it.

  ## Options

  - `:embedding_fn` — Override embedding generation (useful for testing).
  - `:threshold` — Cosine distance threshold (default: #{@default_dedup_threshold}).
  """
  @spec deduplicate(text :: String.t(), opts :: keyword()) ::
          :new | {:duplicate, OllamaChat.Memory.Entry.t()}
  def deduplicate(text, opts \\ []) when is_binary(text) do
    embedding_fn = Keyword.get(opts, :embedding_fn, &default_embedding_fn/1)
    threshold = Keyword.get(opts, :threshold, dedup_threshold())

    case embedding_fn.(text) do
      {:ok, embedding} when is_list(embedding) ->
        find_duplicate(embedding, threshold)

      {:error, reason} ->
        Logger.debug(
          "Deduplication embedding failed, treating candidate as new: #{inspect(reason)}"
        )

        :new
    end
  end

  @doc """
  Generates and stores a conversation summary.

  Sends the formatted conversation to the LLM with a summarisation prompt
  and stores the result in the `conversation_summaries` table via
  `Memory.create_conversation_summary/1`.

  Returns `{:ok, %ConversationSummary{}}` on success.

  ## Options

  - `:chat_fn` — Override the LLM call (see `extract_from_conversation/3`).
  - `:model` — Ollama model to use for summarisation.
  """
  @spec summarize(
          conversation_id :: String.t(),
          messages :: list(map()),
          opts :: keyword()
        ) ::
          {:ok, ConversationSummary.t()} | {:error, term()}
  def summarize(conversation_id, messages, opts \\ []) do
    if Memory.enabled?() do
      do_summarize(conversation_id, messages, opts)
    else
      {:error, :memory_disabled}
    end
  end

  # ── Private: extraction pipeline ────────────────────────────────────────────

  defp do_extract(conversation_id, messages, opts) do
    chat_fn = Keyword.get(opts, :chat_fn, &default_chat_fn/2)
    embedding_fn = Keyword.get(opts, :embedding_fn, &default_embedding_fn/1)
    dedup_thr = Keyword.get(opts, :dedup_threshold, dedup_threshold())
    model = Keyword.get(opts, :model)

    formatted = format_messages(messages)
    prompt_messages = [%{role: "user", content: extraction_prompt(formatted)}]
    chat_opts = if model, do: [model: model], else: []

    case chat_fn.(prompt_messages, chat_opts) do
      {:ok, response} ->
        content = extract_content(response)

        case parse_extraction_response(content) do
          {:ok, items} ->
            save_extracted_memories(items, conversation_id, embedding_fn, dedup_thr)

          {:error, :empty} ->
            {:ok, %{memories_saved: 0, memories_skipped: 0}}

          {:error, reason} ->
            Logger.warning("Could not parse extraction response: #{inspect(reason)}")
            {:ok, %{memories_saved: 0, memories_skipped: 0}}
        end

      {:error, reason} ->
        Logger.warning("Extraction LLM call failed: #{inspect(reason)}")
        {:error, {:chat_failed, reason}}
    end
  end

  defp save_extracted_memories(items, conversation_id, embedding_fn, dedup_thr) do
    Enum.reduce(items, {:ok, %{memories_saved: 0, memories_skipped: 0}}, fn
      item, {:ok, acc} ->
        content = item |> Map.get("content", "") |> to_string() |> String.trim()
        memory_type = item |> Map.get("memory_type", "fact") |> validate_memory_type()
        importance = item |> Map.get("importance", 0.5) |> clamp_importance()

        if content == "" do
          {:ok, %{acc | memories_skipped: acc.memories_skipped + 1}}
        else
          save_single_memory(
            content,
            memory_type,
            importance,
            conversation_id,
            embedding_fn,
            dedup_thr,
            acc
          )
        end
    end)
  end

  # Generates the embedding once, uses it for both dedup check and synchronous
  # storage. Storing synchronously (rather than in a background Task) ensures that
  # the next item's dedup check in the same extraction pass sees the just-saved
  # embedding and correctly identifies true semantic duplicates.
  defp save_single_memory(
         content,
         memory_type,
         importance,
         conversation_id,
         embedding_fn,
         dedup_thr,
         acc
       ) do
    # Generate embedding once — reused for dedup and storage.
    embedding_result = embedding_fn.(content)

    dedup_result =
      case embedding_result do
        {:ok, embedding} -> find_duplicate(embedding, dedup_thr)
        # When embedding fails, treat as new — better to save than silently lose.
        {:error, _reason} -> :new
      end

    case dedup_result do
      :new ->
        attrs = %{
          content: content,
          memory_type: memory_type,
          importance: importance,
          source: "auto_extract",
          conversation_id: conversation_id
        }

        case Memory.create_memory(attrs) do
          {:ok, entry} ->
            # Store embedding synchronously so subsequent dedup checks in this
            # same extraction pass can find it via similarity search.
            case embedding_result do
              {:ok, embedding} ->
                _ = OllamaChat.Embeddings.store_embedding(entry, embedding)

              {:error, _} ->
                :ok
            end

            {:ok, %{acc | memories_saved: acc.memories_saved + 1}}

          {:error, reason} ->
            Logger.warning("Failed to save extracted memory: #{inspect(reason)}")
            {:ok, %{acc | memories_skipped: acc.memories_skipped + 1}}
        end

      {:duplicate, existing} ->
        Logger.debug("Skipping duplicate of #{existing.id}: #{String.slice(content, 0, 60)}")

        {:ok, %{acc | memories_skipped: acc.memories_skipped + 1}}
    end
  end

  # ── Private: summarisation pipeline ─────────────────────────────────────────

  defp do_summarize(conversation_id, messages, opts) do
    chat_fn = Keyword.get(opts, :chat_fn, &default_chat_fn/2)
    model = Keyword.get(opts, :model)

    formatted = format_messages(messages)
    prompt_messages = [%{role: "user", content: summarization_prompt(formatted)}]
    chat_opts = if model, do: [model: model], else: []

    case chat_fn.(prompt_messages, chat_opts) do
      {:ok, response} ->
        summary_text = response |> extract_content() |> String.trim()

        Memory.create_conversation_summary(%{
          conversation_id: conversation_id,
          summary: summary_text,
          key_topics: [],
          message_count: length(messages)
        })

      {:error, reason} ->
        Logger.warning("Summarisation LLM call failed: #{inspect(reason)}")
        {:error, {:chat_failed, reason}}
    end
  end

  # ── Private: deduplication ───────────────────────────────────────────────────

  defp find_duplicate(embedding, threshold) when is_list(embedding) do
    case Memory.search_by_similarity_with_scores(embedding, limit: 1) do
      {:ok, [{entry, distance} | _]} when distance < threshold ->
        {:duplicate, entry}

      {:ok, _} ->
        :new

      {:error, _reason} ->
        # Gracefully degrade — treat as new when the DB query fails
        :new
    end
  end

  # ── Private: message formatting ──────────────────────────────────────────────

  # Converts a list of message maps (atom- or string-keyed) to a readable
  # conversation transcript for passing to the LLM.
  defp format_messages(messages) do
    Enum.map_join(messages, "\n\n", fn msg ->
      role = (msg[:role] || msg["role"] || "user") |> to_string()
      content = (msg[:content] || msg["content"] || "") |> to_string()
      label = if role == "user", do: "User", else: "Assistant"
      "#{label}: #{content}"
    end)
  end

  # ── Private: prompts ─────────────────────────────────────────────────────────

  defp extraction_prompt(formatted_conversation) do
    """
    Review the following conversation and extract key information about the user
    that is worth remembering for future interactions.

    Focus on:
    - Personal facts (name, role, location, background)
    - Technical context (projects, tools, languages, frameworks they use)
    - Preferences (communication style, detail level, tools liked/disliked)
    - Important decisions or outcomes from this conversation

    For each item worth remembering, output a JSON object with:
    - "content"     — the fact/preference/context (concise, written in third person)
    - "memory_type" — one of: "fact", "preference", "context", "episodic"
    - "importance"  — a float 0.0–1.0 (0.9 = crucial, 0.7 = important, 0.5 = useful, 0.3 = minor)

    Rules:
    - Respond ONLY with a valid JSON array. No preamble, no explanation, no markdown fences.
    - If nothing is worth remembering, respond with exactly: []
    - Do not invent information not present in the conversation.

    Example response:
    [{"content": "User's name is Alice", "memory_type": "fact", "importance": 0.9},
     {"content": "User prefers concise answers", "memory_type": "preference", "importance": 0.7}]

    Conversation:
    #{formatted_conversation}
    """
  end

  defp summarization_prompt(formatted_conversation) do
    """
    Summarise the following conversation in 2–3 concise sentences.
    Write in third person (e.g. "The user asked about…").
    Focus on the main topics discussed and any key outcomes or decisions made.
    Do not add commentary — only the summary.

    Conversation:
    #{formatted_conversation}
    """
  end

  # ── Private: response parsing ────────────────────────────────────────────────

  # Extracts the text content from an OllamaClient chat response.
  defp extract_content(%{"message" => %{"content" => content}}), do: content
  defp extract_content(%{"content" => content}), do: content
  defp extract_content(content) when is_binary(content), do: content
  defp extract_content(_), do: ""

  # Parses the LLM's JSON extraction response.
  # Handles optional markdown code fences that some models produce.
  defp parse_extraction_response(text) when is_binary(text) do
    cleaned = text |> String.trim() |> strip_markdown_fences()

    case Jason.decode(cleaned) do
      {:ok, list} when is_list(list) and list != [] ->
        {:ok, list}

      {:ok, []} ->
        {:error, :empty}

      {:ok, _} ->
        {:error, {:invalid_format, "Expected a JSON array"}}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  defp parse_extraction_response(_), do: {:error, :empty}

  # Strips ```json ... ``` or ``` ... ``` markdown code fences.
  defp strip_markdown_fences(text) do
    text
    |> String.replace(~r/\A```(?:json)?\s*\n?/m, "")
    |> String.replace(~r/\n?```\s*\z/m, "")
    |> String.trim()
  end

  # ── Private: validation helpers ──────────────────────────────────────────────

  @valid_memory_types ~w(fact preference context episodic)

  defp validate_memory_type(type) when type in @valid_memory_types, do: type
  defp validate_memory_type(_), do: "fact"

  defp clamp_importance(v) when is_number(v), do: v |> max(0.0) |> min(1.0)
  defp clamp_importance(_), do: 0.5

  # ── Private: defaults ────────────────────────────────────────────────────────

  defp default_chat_fn(messages, opts), do: OllamaClient.chat(messages, opts)
  defp default_embedding_fn(text), do: OllamaClient.generate_embedding(text)

  defp min_messages_threshold do
    Application.get_env(:ollama_chat, :memory_extraction_min_messages, 5)
  end

  defp dedup_threshold do
    Application.get_env(
      :ollama_chat,
      :memory_extraction_dedup_threshold,
      @default_dedup_threshold
    )
  end
end
