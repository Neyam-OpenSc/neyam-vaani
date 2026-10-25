# Target Users & Use Cases

## The people we're building for

### Lakshmi, 52 — Tamil Nadu
Runs a small flower shop. Smartphone-literate but uncomfortable typing in
Tamil. Wants to draft WhatsApp messages to suppliers, check market prices,
set reminders, and read letters customers bring in.
*Phone: Redmi 9A, 2GB RAM, intermittent 4G.*

### Raju, 34 — Telangana
Auto-rickshaw driver. Speaks Telugu and Hindi, reads slowly. Wants to
navigate without typing, send voice messages, calculate fares, fill
government forms.
*Phone: Realme C25, 3GB RAM, prepaid data.*

### Aisha, 28 — West Bengal
Homemaker, caregiver to elderly in-laws. Speaks Bengali, basic English.
Wants to read medicine labels aloud, set medication reminders, ask health
questions without judgment, draft emails to her kids' school.
*Phone: Samsung A06, 4GB RAM.*

### Kamal, 19 — Bihar
Student, first-generation learner. Speaks Bhojpuri and Hindi. Wants to
dictate notes, ask homework questions in Bhojpuri, practice English
speaking, summarize textbooks.
*Phone: Infinix Hot 30, 4GB RAM, shared family Wi-Fi.*

## Top 20 use cases (the v1 scope)

Everything outside this table is out of scope for v1. No exceptions —
this is how we protect the roadmap.

| # | Use case | Intent id | Language priority |
|---|---|---|---|
| 1 | Voice-search a question, get a spoken answer | `answer_question` | All |
| 2 | Dictate a WhatsApp/SMS message | `draft_message` | All |
| 3 | Read aloud a document (PDF/photo of paper) | `read_document` | All |
| 4 | Set a reminder / alarm | `set_reminder` | All |
| 5 | Make a call by voice | `make_call` | All |
| 6 | Calculate something (math, currency, units) | `calculate` | All |
| 7 | Translate between two vernacular languages | `translate` | All pairs |
| 8 | Fill a form by voice (govt, school forms) | `fill_form` | Hi, Ta, Bn first |
| 9 | Ask about local market / commodity prices | `market_price` | Ta, Hi, Te first |
| 10 | Get weather / news summary | `weather_news` | All |
| 11 | Draft a formal letter (leave application, complaint) | `draft_letter` | All |
| 12 | Practice English conversation | `practice_english` | All |
| 13 | Read a medicine label and explain dosage | `explain_medicine` | All |
| 14 | Schedule appointment (basic calendar) | `schedule_appointment` | All |
| 15 | Convert voice to text and copy anywhere | `copy_text` | All |
| 16 | Ask "how do I…" questions (cooking, repairs) | `how_to_question` | All |
| 17 | Voice-controlled flashlight / torch | `torch_control` | All |
| 18 | Find a nearby hospital / police station | `find_nearby` | All |
| 19 | Send location to family by voice | `send_location` | All |
| 20 | Hear today's date / time / day in their language | `date_time` | All |

## Languages (priority order)

1. Tamil · 2. Hindi · 3. Bengali · 4. Kannada · 5. Telugu ·
6. Marathi · 7. Bhojpuri · 8. Maithili · 9. English (secondary)

Bhojpuri and Maithili are deliberately included despite low-resource
status — exactly the languages commercial assistants skip.
