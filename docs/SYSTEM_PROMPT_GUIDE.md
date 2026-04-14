# System Prompt Guide

The **System Prompt** controls how the LLM behaves throughout the conversation. It's included with every message you send, providing persistent instructions that shape the LLM's responses and memory usage.

---

## Accessing the System Prompt

1. Look for the **System Prompt** collapsible section in the chat interface (near the message input area)
2. Click to expand it
3. View or edit the default instructions
4. Changes are saved automatically with your conversation

---

## Default Memory Instructions

Ollama Chat includes default instructions that tell the LLM how to use the memory system effectively:

### What's Included

- **Search first** — The LLM searches memories at conversation start to recall relevant context
- **Save silently** — Important information is saved automatically without announcing it
- **Memory types** — Guidelines for using `fact`, `preference`, `context`, and `episodic` types
- **Importance scoring** — How to set importance: high (0.8+), medium (0.5), low (0.2)
- **Best practices** — When to save, what not to save, how to avoid duplicates

### Default Behavior

With the default system prompt, the LLM will:

✅ **Automatically search** for relevant memories when a question might benefit from context  
✅ **Save new information** about your preferences, facts, projects, and significant events  
✅ **Work silently** — memory operations happen in the background without interrupting conversation  
✅ **Update existing memories** rather than creating duplicates  
✅ **Use appropriate importance** — critical info gets high importance, minor details get low

---

## Customizing Memory Behavior

You can modify the system prompt to change how aggressively or conservatively the LLM uses memory.

### Example Customizations

**More aggressive saving:**
```
Save memories more frequently, even for small details about my workflow, tools, and preferences.
Consider everything worth remembering unless it's truly ephemeral.
```

**More conservative saving:**
```
Only save memories when I explicitly ask you to, or when you learn critical information
that would significantly impact future conversations (e.g., my role, major project constraints,
strong preferences about code quality).
```

**Domain-specific focus:**
```
Focus memory exclusively on:
- Technical architecture decisions and their rationale
- Performance constraints and optimization strategies  
- Security requirements and compliance needs
- Project deadlines and delivery commitments

Ignore personal preferences about formatting, style, or tools unless they're project requirements.
```

**Importance tuning:**
```
Use high importance (0.8+) for:
- Security decisions and compliance requirements
- Architecture patterns and design principles
- Hard-learned lessons from production incidents

Use low importance (0.2-0.4) for:
- Anything I can easily look up in documentation
- Temporary project context that will change soon
- Tool preferences that aren't project-critical
```

**Explicit announcements:**
```
Always tell me when you save a memory. Include what you saved and why you deemed it important.
This helps me understand what you're learning and correct misunderstandings.
```

---

## Memory Tools Reference

The LLM has access to these memory tools (automatically available, no configuration needed):

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `memory_search` | Search stored memories | At conversation start, when context might help answer a question |
| `memory_save` | Save new memory | When learning something important about the user or project |
| `memory_list` | List all memories | When user asks "what do you know about me?" |
| `memory_update` | Update existing memory | When correcting or refining previously saved information |
| `memory_delete` | Delete a memory | When information is outdated or incorrect |

---

## Tips for Effective System Prompts

### Be Specific

❌ "Remember things better"  
✅ "Save memories for architecture decisions, naming conventions, and team preferences"

### Use Examples

```
When I mention a preference (e.g., "I prefer TypeScript over JavaScript"), 
save it as memory_type=preference with importance=0.7.

When I describe an ongoing project (e.g., "We're migrating to Kubernetes by Q3"),
save it as memory_type=context with importance=0.8.
```

### Set Boundaries

```
Do NOT save:
- Information from example code or hypothetical scenarios
- General programming facts you already know
- Temporary debugging context that won't matter tomorrow
```

### Combine with Other Instructions

The system prompt isn't just for memory — you can also include:

```
# Memory Guidelines
[memory instructions here]

# Response Style
- Be concise and direct
- Provide working code examples
- Explain trade-offs when suggesting solutions

# Preferences
- Always include error handling
- Prefer functional approaches when appropriate
- Use descriptive variable names
```

---

## Resetting to Default

If you want to restore the default memory instructions:

1. Expand the System Prompt section
2. Delete your custom text
3. Clear the conversation (or start a new one)
4. The default prompt will be automatically applied

Or manually paste the default from: `lib/ollama_chat_web/live/chat_live.ex` → `default_system_prompt/0`

---

## See Also

- **[Memory User Guide](MEMORY_USER_GUIDE.md)** — Complete documentation on the memory system
- **[Memory Browser](MEMORY_USER_GUIDE.md#memory-browser)** — How to view, edit, and manage stored memories
- **[Configuration](MEMORY_USER_GUIDE.md#configuration)** — Environment variables and system settings

---

## Quick Reference

| Goal | System Prompt Addition |
|------|----------------------|
| Save less frequently | "Only save memories when I explicitly ask or when learning critical information" |
| Save more frequently | "Save memories for any preference, fact, or context that might be useful later" |
| Focus on specific domain | "Focus memory on: [list specific topics]. Ignore everything else." |
| Get feedback on saves | "Always tell me when you save a memory and why you deemed it important" |
| Disable auto-save | "Never save memories automatically. Only save when I explicitly say 'remember this'" |
