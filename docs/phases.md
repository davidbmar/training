# Conversation Phases

Every phone call to Smith Plumbing follows a natural conversational arc. We label each turn with one of 11 canonical phases. These labels serve two purposes: they tell the training pipeline which conversational skill each example teaches, and they power the per-phase evaluation rubrics that score model quality.

## The 9 Core Phases

These phases represent the standard booking flow. A complete happy-path call touches all 9 in order.

### 1. Greeting
**FSM state:** `greet`
**What happens:** Agent answers the phone with the business name and a warm opener.
**Agent behavior:** "Hi, Smith Plumbing, how can I help?" — brief, warm, sets the tone.
**Training signal:** Warmth, enthusiasm, personalization.
**Example:** "Thanks for calling Smith Plumbing! This is Lisa, how can I help?"

### 2. Problem Determination
**FSM state:** `ask_service`
**What happens:** Agent listens to the caller's issue and asks clarifying questions to identify the right service.
**Agent behavior:** Echo the caller's exact words back ("leaking sink" not "water damage"). Ask one question at a time. Show empathy before moving to scheduling.
**Training signal:** Empathy, active listening, clarifying questions, echo-back pattern.
**Example:** "Oh no, a leak under the bathroom sink — that's no fun. Is it a steady drip or more of a trickle?"

### 3. Solution Proposal
**FSM state:** (new phase, not yet in FSM)
**What happens:** Agent suggests the appropriate next step — send a plumber, DIY tip for simple issues, or explain what the service involves.
**Agent behavior:** Brief explanation. For simple issues (running toilet, jammed disposal), offer a quick fix first. For complex issues, move toward scheduling.
**Training signal:** Accuracy, helpfulness, setting expectations.
**Example:** "That sounds like a supply line issue — we can send someone out to take a look. Usually takes about an hour."

### 4. Time Preference
**FSM state:** `ask_time`
**What happens:** Agent asks when the caller wants the appointment.
**Agent behavior:** One question: "What day works for you?" Don't re-ask about the problem. If caller keeps talking about the issue, gently redirect.
**Training signal:** Efficiency, redirection, natural transition.
**Example:** "Sure thing! What day works best for you?"

### 5. Availability Check
**FSM state:** `find_slots`
**What happens:** Automatic calendar lookup. No conversation turns — this is a system action between phases 4 and 6.
**Training signal:** None (no agent text generated).

### 6. Match & Propose
**FSM state:** `offer_slots`
**What happens:** Agent presents available time slots and negotiates with the caller.
**Agent behavior:** Offer 2-3 options naturally. If the caller's preferred time isn't available, suggest the closest alternatives. For rushed callers, lead with the earliest slot.
**Training signal:** Flexibility, clear options, negotiation.
**Example:** "I've got Thursday at 10am or Friday at 2pm — which works better?"

### 7. Confirmation
**FSM state:** `confirm_booking`
**What happens:** Agent collects name and phone number, then reads back ALL booking details.
**Agent behavior:** Echo everything: service, date, time, name, phone. Wait for "yes" before proceeding. Use the caller's name.
**Training signal:** Echo-back completeness, detail accuracy, using caller's name.
**Example:** "Alright Mike, so that's drain cleaning on Thursday at 2pm. I've got you at 555-0142. Sound good?"

### 8. Summarize & Book
**FSM state:** `book_appointment`
**What happens:** Final summary and calendar insertion. Agent confirms the booking is set.
**Agent behavior:** Celebrate: "You're all set!" Mention next steps (text confirmation, what to expect). If booking fails, apologize and offer callback.
**Training signal:** Completeness, next steps, handling system errors gracefully.
**Example:** "You're all set for Thursday at 2pm! You'll get a text confirmation. Have a great day, Mike!"

### 9. Goodbye
**FSM state:** `exit`
**What happens:** Warm close to the conversation.
**Agent behavior:** Use the caller's name. Offer further help. Keep it brief and warm.
**Training signal:** Warmth, personalization, clean close.
**Example:** "Thanks for calling, Mike! We'll see you Thursday."

## The 2 Edge-Case Phases

These phases handle non-standard flows. They don't occur in happy-path bookings but are critical for real-world call quality.

### 10. Emergency Escalation
**What happens:** Caller reports an urgent situation — burst pipe, gas smell, flooding.
**Agent behavior:** SAFETY FIRST. For gas: "Leave the house immediately and call 911." For flooding: "Can you turn off the main water valve?" Triage the severity before scheduling. Fast-track to same-day dispatch.
**Training signal:** Safety prioritization, calm under pressure, correct triage protocol.
**Example:** "I hear you — first thing, can you find the main water shutoff valve? It's usually near the water meter."

### 11. Cancellation
**What happens:** Caller wants to cancel an existing appointment.
**Agent behavior:** Acknowledge, attempt gentle retention ("Is there a different time that works?"), accept gracefully when they insist. Never guilt-trip.
**Training signal:** Retention attempt, graceful acceptance, professionalism.
**Example:** "No problem at all! Is there a different day that might work, or would you like to cancel completely?"

## Special Label: Caller Hangup

`caller_hangup` is not a phase the agent controls — it marks the point where the caller ends the call abruptly. The agent's response to a hangup (or silence) is what we train: "Hello? ... Alright, give us a call back anytime!"

## Phase Sequence Rules

Legal transitions follow this general pattern:

```
greeting → problem_determination → solution_proposal → time_preference
    → match_propose → confirmation → summarize_book → goodbye
```

Allowed shortcuts:
- `greeting → emergency_escalation → confirmation → goodbye` (emergencies skip normal flow)
- `greeting → problem_determination → cancellation → goodbye` (cancellation calls)
- `greeting → problem_determination → solution_proposal → goodbye` (DIY recommendation, question-only)
- Any phase → `caller_hangup` (caller can leave at any point)

Illegal jumps:
- `greeting → confirmation` (can't confirm what hasn't been discussed)
- `greeting → summarize_book` (can't summarize without details)
- `match_propose → problem_determination` (don't go backwards to re-ask the problem)

## Phase Distribution in Training Data

The dataset targets balanced coverage across all phases:

| Phase | Train Examples | Purpose |
|-------|---------------|---------|
| greeting | 128 | Opening warmth and tone-setting |
| problem_determination | 232 | Active listening and echo-back |
| solution_proposal | 98 | Helpfulness and accuracy |
| time_preference | 79 | Efficient scheduling transition |
| match_propose | 52 | Slot negotiation and flexibility |
| confirmation | 76 | Detail read-back and accuracy |
| summarize_book | 50 | Booking finalization |
| goodbye | 127 | Warm close with personalization |
| emergency_escalation | 40 | Safety-first triage |
| cancellation | 27 | Retention and graceful handling |
| caller_hangup | 13 | Graceful response to abrupt exits |

**Total:** 922 turn-level training examples from 128 conversations.

## Per-Phase Evaluation Rubrics

Each phase is scored on 3 dimensions (1-5 scale) during tournament evaluation:

| Phase | Dimensions |
|-------|-----------|
| Greeting | warmth, enthusiasm, personalization |
| Discovery | empathy, listening, clarifying questions |
| Solution | accuracy, helpfulness, expectations set |
| Scheduling | flexibility, calendar check, options offered |
| Confirmation | echo back, calendar validated, details complete |
| Goodbye | warmth, offered help, used caller's name |

These rubrics are implemented in `phone_agent/evaluation/phase_eval.py` in the phone-agent-scheduler repo and will be used for tournament evaluation after fine-tuning.

## Related Docs

- [Fine-Tuning Guide](fine-tuning-guide.md) — how we use these phases in the training pipeline
- [Training Methodology](training-methodology.md) — how the training data is structured and split
- [Training Data Explorer](html/seed-training-pipeline.html) — browse conversations and filter by phase
- [README](../README.md) — project overview
