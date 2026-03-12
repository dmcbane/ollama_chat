# Intermediate Events Storage Decision

**Date:** 2024-03-12
**Status:** Implemented
**Decision:** User preference toggle for storing intermediate events in localStorage

## Context

Intermediate events (tool calls, tool results, and intermediate response chunks) are captured during LLM streaming responses and displayed in a collapsible UI. These events can be quite verbose and significantly increase localStorage usage, especially for:

- Long tool responses (file contents, API responses)
- Multiple tool calls per message
- Verbose debugging output from tools

A single conversation with several tool-using responses can easily consume 10-100KB of storage. With the default limit of 100 conversations, this could exhaust the typical browser localStorage quota (5-10MB).

## Decision

**Option 2: Global User Preference Toggle**

We implement a user-controlled preference in the sidebar that allows users to decide whether to save intermediate events to localStorage. This preference applies globally to all conversations going forward.

### Implementation Details

- **UI**: Checkbox in sidebar settings area labeled "Save tool activity in history"
- **Default**: OFF (do not save intermediate events by default)
- **Storage**: Preference stored separately in localStorage key `ollama_chat_save_intermediate_events`
- **Behavior**: When saving a conversation, check this preference:
  - If OFF: Set `intermediate_events: []` (empty array)
  - If ON: Set `intermediate_events: intermediate` (full event list)
- **Scope**: Applied at save time; existing conversations retain their data

### Trade-offs

**Pros:**
- User decides based on their needs and storage constraints
- Simple to understand and implement
- Can be changed at any time
- Good balance between storage efficiency and information preservation
- Power users who need debugging info can opt-in
- Casual users save storage space

**Cons:**
- Adds one more UI setting to manage
- Need to educate users about what they're giving up
- Existing conversations still contain intermediate events (not retroactively cleaned)
- Users must remember to enable before important debugging sessions

## Alternatives Considered

### Option 1: Always Exclude Intermediate Events (Rejected)
**Description:** Never store intermediate events in localStorage.

**Pros:**
- Minimal storage usage
- Simplest implementation
- Fast save/load operations

**Cons:**
- Lost forever after page refresh - can't review tool activity
- Loss of debugging information for troubleshooting
- Less transparency about LLM tool usage
- Power users have no way to preserve this data

**Why Rejected:** Too restrictive; eliminates valuable debugging capability with no escape hatch.

### Option 3: Exclude by Default, Include on Demand (Rejected)
**Description:** Per-conversation toggle to include intermediate events when saving.

**Pros:**
- Save storage for most conversations
- Granular control per conversation
- Can enable for specific debugging sessions

**Cons:**
- More complex UI (need toggle on save action)
- More complex implementation (per-conversation metadata)
- Users might forget to enable when they need it
- Inconsistent UX (sometimes prompted, sometimes not)

**Why Rejected:** Over-engineered for the use case; global preference is simpler and sufficient.

### Option 4: Time-Based Pruning (Rejected)
**Description:** Keep intermediate events for recent conversations (e.g., last 5-10), automatically prune older ones.

**Pros:**
- Automatic balance between storage and utility
- Keeps recent data for debugging
- No user decision required

**Cons:**
- Complex implementation (background pruning job)
- Unpredictable - users don't know when data will be pruned
- Could lose data users wanted to keep
- Difficult to test and debug
- Still requires choosing arbitrary thresholds

**Why Rejected:** Too complex; adds significant implementation burden for marginal benefit. User preference is more predictable.

## Future Considerations

### If Storage Becomes an Issue Despite This Change

1. **Selective field storage**: Store only tool names and argument summaries, not full responses
2. **Compression**: Use browser compression APIs before storing
3. **External storage**: Offer export to file, cloud storage integration
4. **Smart pruning**: Prune intermediate events from old conversations automatically
5. **Size warnings**: Alert users when conversations are unusually large

### If Users Request More Control

1. **Per-conversation override**: Allow enabling for specific important conversations
2. **Retention period**: "Keep intermediate events for X days/conversations"
3. **Tool-specific filtering**: Save only certain tool types (e.g., save filesystem access, skip simple calculations)

## Related Files

- `lib/ollama_chat_web/live/chat_live.ex` - Where intermediate events are collected and saved
- `lib/ollama_chat_web/live/chat_live.ex` (JavaScript hooks) - Where localStorage operations happen

## Metrics to Monitor

- Average conversation size in localStorage
- User feedback about storage quota issues
- Adoption rate of the preference toggle
- Support requests related to missing tool activity after refresh