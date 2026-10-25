/// Per-intent slot extraction with deterministic rules.
///
/// Regex + keyword heuristics for the slots the prompt templates and
/// device actions need: time expressions ("tomorrow 6am" ->
/// 2026-10-26T06:00), recipients ("to my boss", "அம்மாவுக்கு"), languages,
/// tone words, arithmetic for calculate, place types for findNearby,
/// on/off for torch.
///
/// Honest by design: when a rule does not fire, the slot is simply absent
/// and the caller asks the user — we never invent values. Pure Dart, no
/// locale packages; a [clock] is injected so time math is testable.
library;

import '../../../domain/entities/intent.dart';
import '../../../domain/entities/slot.dart';
import '../../../domain/usecases/orchestrate_user_request.dart'
    show SlotFilling;

/// Extracts slots from a transcript for a known intent.
class SlotExtractor implements SlotFilling {
  SlotExtractor({DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final DateTime Function() _now;

  @override
  SlotSet extract({required VaaniIntent intent, required String transcript}) {
    final String text = transcript.trim();
    if (text.isEmpty) {
      return const SlotSet.empty();
    }
    final List<Slot> slots = <Slot>[];

    slots.addAll(_languageSlots(text));
    final Slot? tone = _toneSlot(text, intent);
    if (tone != null) {
      slots.add(tone);
    }

    switch (intent) {
      case VaaniIntent.draftMessage:
      case VaaniIntent.draftLetter:
        _addRecipient(slots, text);
        _addContent(slots, text);
      case VaaniIntent.setReminder:
      case VaaniIntent.scheduleAppointment:
        _addTimeSlot(slots, text);
        _addContent(slots, text);
      case VaaniIntent.makeCall:
      case VaaniIntent.sendLocation:
        _addRecipient(slots, text);
      case VaaniIntent.translate:
        _addContent(slots, text);
      case VaaniIntent.calculate:
        _addExpression(slots, text);
      case VaaniIntent.findNearby:
        _addLocationType(slots, text);
      case VaaniIntent.torchControl:
        _addDeviceAction(slots, text);
      case VaaniIntent.answerQuestion:
      case VaaniIntent.howToQuestion:
      case VaaniIntent.practiceEnglish:
      case VaaniIntent.explainMedicine:
        slots.add(
          Slot(name: SlotNames.query, value: text, confidence: 0.95),
        );
      case VaaniIntent.readDocument:
      case VaaniIntent.fillForm:
      case VaaniIntent.marketPrice:
      case VaaniIntent.weatherNews:
      case VaaniIntent.copyText:
      case VaaniIntent.dateTime:
        // Document/form/market text arrives through other channels
        // (OCR, cached feeds); the device clock answers dateTime
        // without the LLM. No extra slots here.
        break;
    }
    return SlotSet(slots);
  }

  // -- digits ---------------------------------------------------------------

  /// Latinizes Devanagari, Bengali, Tamil, Telugu, Kannada and
  /// Arabic-Indic digits ("६" -> "6") so the number rules work across
  /// scripts.
  static String normalizeDigits(String text) {
    const List<int> digitRangeStarts = <int>[
      0x0966, // Devanagari
      0x09E6, // Bengali
      0x0BE6, // Tamil
      0x0C66, // Telugu
      0x0CE6, // Kannada
      0x06F0, // Arabic-Indic
    ];
    final StringBuffer out = StringBuffer();
    for (final int code in text.runes) {
      int c = code;
      for (final int start in digitRangeStarts) {
        if (c >= start && c <= start + 9) {
          c = 0x30 + (c - start);
          break;
        }
      }
      out.writeCharCode(c);
    }
    return out.toString();
  }

  // -- languages -------------------------------------------------------------

  static const Map<String, String> _languageWords = <String, String>{
    'tamil': 'ta',
    'தமிழ்': 'ta',
    'தமிழில்': 'ta',
    'hindi': 'hi',
    'हिंदी': 'hi',
    'हिन्दी': 'hi',
    'bengali': 'bn',
    'bangla': 'bn',
    'বাংলা': 'bn',
    'kannada': 'kn',
    'ಕನ್ನಡ': 'kn',
    'telugu': 'te',
    'తెలుగు': 'te',
    'marathi': 'mr',
    'मराठी': 'mr',
    'bhojpuri': 'bho',
    'भोजपुरी': 'bho',
    'maithili': 'mai',
    'मैथिली': 'mai',
    'english': 'en',
    'angrezi': 'en',
    'ஆங்கிலம்': 'en',
    'अंग्रेज़ी': 'en',
    'अंग्रेजी': 'en',
    'ইংরেজি': 'en',
    'ಇಂಗ್ಲಿಷ್': 'en',
  };

  List<Slot> _languageSlots(String text) {
    final List<String> codes = <String>[];
    for (final String rawWord in text.toLowerCase().split(RegExp(r'\s+'))) {
      final String word = rawWord.replaceAll(RegExp(r'[.,!?;:।॥]'), '');
      final String? code = _languageWords[word];
      if (code != null && !codes.contains(code)) {
        codes.add(code);
      }
    }
    if (codes.isEmpty) {
      return const <Slot>[];
    }
    // Last mention is the target ("translate X to Hindi"); an earlier,
    // different mention is the source ("translate Tamil to Hindi").
    final List<Slot> slots = <Slot>[
      Slot(name: SlotNames.targetLanguage, value: codes.last, confidence: 0.8),
    ];
    if (codes.length > 1) {
      slots.add(
        Slot(name: SlotNames.sourceLanguage, value: codes.first, confidence: 0.7),
      );
    }
    return slots;
  }

  // -- tone -------------------------------------------------------------------

  static const Map<String, List<String>> _toneWords = <String, List<String>>{
    // 'casual' is checked before 'formal' because "informal" contains
    // "formal" — a plain substring scan would misread it.
    'casual': <String>['casual', 'informal', 'आम बोलचाल'],
    'formal': <String>[
      'formal', 'official', 'respectful', 'respectfully', 'सम्मान',
      'मर्यादा', 'மரியாதை',
    ],
    'apologetic': <String>[
      'sorry', 'apology', 'apologize', 'apologise', 'माफ़', 'माफी',
      'மன்னிப்பு', 'ক্ষমা',
    ],
    'requesting': <String>[
      'request', 'requesting', 'विनती', 'निवेदन', 'வேண்டுகோள்',
    ],
    'urgent': <String>[
      'urgent', 'urgently', 'immediately', 'तुरंत', 'உடனடியாக', 'त्वरित',
    ],
  };

  Slot? _toneSlot(String text, VaaniIntent intent) {
    final String lower = text.toLowerCase();
    for (final MapEntry<String, List<String>> entry in _toneWords.entries) {
      for (final String word in entry.value) {
        if (lower.contains(word)) {
          return Slot(name: SlotNames.tone, value: entry.key, confidence: 0.7);
        }
      }
    }
    // Sensible defaults only where the prompt needs a tone at all.
    if (intent == VaaniIntent.draftLetter) {
      return const Slot(
        name: SlotNames.tone,
        value: 'formal',
        confidence: 0.5,
      );
    }
    if (intent == VaaniIntent.draftMessage) {
      return const Slot(
        name: SlotNames.tone,
        value: 'casual',
        confidence: 0.5,
      );
    }
    return null;
  }

  // -- recipient ---------------------------------------------------------------

  static const List<String> _personStopWords = <String>[
    'message', 'letter', 'text', 'sms', 'whatsapp', 'location', 'the', 'a',
    'that', 'saying', 'him', 'her', 'them',
  ];

  void _addRecipient(List<Slot> slots, String text) {
    final String lower = text.toLowerCase();

    // "call my son", "phone the doctor"
    final RegExp callRe = RegExp(
      r'\b(?:call|phone|dial|ring)\s+(?:my\s+|our\s+)?([a-z]{2,}(?:\s+[a-z]{2,}){0,2})',
    );
    final RegExpMatch? callMatch = callRe.firstMatch(lower);
    if (callMatch != null) {
      final String? person = _cleanPerson(callMatch.group(1));
      if (person != null) {
        slots.add(Slot(name: SlotNames.recipient, value: person, confidence: 0.8));
        return;
      }
    }

    // "to my boss", "to priya"
    final RegExp toRe = RegExp(
      r'\bto\s+(?:my\s+|our\s+)?([a-z]{2,}(?:\s+[a-z]{2,}){0,2})',
    );
    final RegExpMatch? toMatch = toRe.firstMatch(lower);
    if (toMatch != null) {
      final String? person = _cleanPerson(toMatch.group(1));
      if (person != null) {
        slots.add(Slot(name: SlotNames.recipient, value: person, confidence: 0.75));
        return;
      }
    }

    // Tamil dative suffix: "அம்மாவுக்கு" -> "அம்மா"
    for (final String word in text.split(RegExp(r'\s+'))) {
      if (word.contains('ுக்கு') || word.endsWith('க்கு') || word.endsWith('க்காக')) {
        final String stripped = word
            .replaceAll('ுக்கு', '')
            .replaceAll('க்கு', '')
            .replaceAll('க்காக', '');
        if (stripped.length >= 3) {
          slots.add(
            Slot(name: SlotNames.recipient, value: stripped, confidence: 0.6),
          );
          return;
        }
      }
    }

    // Postpositions: Hindi "को / के लिए", Telugu "కి / కు", Kannada "ಗೆ",
    // Bengali "কে" — the word right before is the recipient.
    final RegExp postRe =
        RegExp(r'(\S+)\s+(?:के लिए|को|కి|కు|ಗೆ|কে)');
    final RegExpMatch? postMatch = postRe.firstMatch(text);
    if (postMatch != null) {
      final String person = postMatch.group(1)!.trim();
      if (person.length >= 2) {
        slots.add(Slot(name: SlotNames.recipient, value: person, confidence: 0.6));
      }
    }
  }

  String? _cleanPerson(String? raw) {
    if (raw == null) {
      return null;
    }
    final List<String> kept = <String>[];
    for (final String word in raw.trim().split(RegExp(r'\s+'))) {
      if (word.isEmpty || word == 'my' || word == 'our') {
        continue;
      }
      if (_languageWords.containsKey(word) ||
          _personStopWords.contains(word)) {
        // "to my boss that I ..." — the person phrase ends at "that".
        break;
      }
      kept.add(word);
      if (kept.length == 2) {
        break; // Names and roles are short.
      }
    }
    if (kept.isEmpty) {
      return null;
    }
    return kept.join(' ');
  }

  // -- content -------------------------------------------------------------------

  static final RegExp _quotedRe = RegExp('[“"]([^“”"]{2,})[”"]');
  static final RegExp _thatRe = RegExp(
    r'(?:that|saying|कि|என்று|అని|ಎಂದು|বলে)\s+(.+)$',
  );

  void _addContent(List<Slot> slots, String text) {
    final RegExpMatch? quoted = _quotedRe.firstMatch(text);
    if (quoted != null) {
      slots.add(
        Slot(name: SlotNames.content, value: quoted.group(1)!.trim(), confidence: 0.9),
      );
      return;
    }
    final RegExpMatch? that = _thatRe.firstMatch(text);
    if (that != null) {
      final String content = that.group(1)!.trim();
      if (content.length >= 2) {
        slots.add(Slot(name: SlotNames.content, value: content, confidence: 0.7));
      }
    }
  }

  // -- time -------------------------------------------------------------------

  static const List<String> _tomorrowWords = <String>[
    'tomorrow', 'நாளை', 'कल', 'kal', 'రేపు', 'ನಾಳೆ', 'আগামীকাল', 'उद्या',
  ];
  static const List<String> _dayAfterWords = <String>[
    'day after tomorrow', 'மறுநாள்', 'அடுத்த நாள்', 'परसों',
  ];
  static const List<String> _todayWords = <String>[
    'today', 'இன்று', 'आज', 'ఈరోజు', 'ಇಂದು', 'আজ',
  ];
  static const List<String> _weekdayNames = <String>[
    'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday',
    'sunday',
  ];
  static const List<String> _morningWords = <String>[
    'morning', 'सुबह', 'காலை', 'ఉదయం', 'ಬೆಳಿಗ್ಗೆ', 'সকাল',
  ];
  static const List<String> _eveningWords = <String>[
    'evening', 'night', 'शाम', 'रात', 'மாலை', 'இரவு', 'సాయంత్రం', 'ಸಂಜೆ',
    'সন্ধ্যা', 'রাত',
  ];

  void _addTimeSlot(List<Slot> slots, String text) {
    final String lower = normalizeDigits(text.toLowerCase());
    final DateTime now = _now();

    // "in 10 minutes" / "in 2 hours" — relative first, it is unambiguous.
    final RegExp inRe = RegExp(
      r'in\s+(\d{1,3})\s*(minute|min|minutes|hour|hours|hr|घंटे|घंटा|मिनट|நிமிடம்|நிமிடங்கள்|గంటలు|నిమిషాలు|ಗಂಟೆ|ನಿಮಿಷ)',
    );
    final RegExpMatch? inMatch = inRe.firstMatch(lower);
    if (inMatch != null) {
      final int amount = int.parse(inMatch.group(1)!);
      final String unit = inMatch.group(2)!;
      // Everything not explicitly a "minute" word counts as hours.
      final bool hours = !(unit.startsWith('min') ||
          unit.contains('நிமிட') ||
          unit.contains('मिनट') ||
          unit.contains('ನಿಮಿಷ') ||
          unit.contains('నిమిష'));
      final DateTime when = now.add(
        Duration(minutes: hours ? amount * 60 : amount),
      );
      slots.add(
        Slot(name: SlotNames.time, value: _isoDateTime(when), confidence: 0.8),
      );
      return;
    }

    DateTime? date;
    double confidence = 0;
    if (_dayAfterWords.any(lower.contains)) {
      date = DateTime(now.year, now.month, now.day + 2);
      confidence = 0.7;
    } else if (_tomorrowWords.any(lower.contains)) {
      date = DateTime(now.year, now.month, now.day + 1);
      confidence = 0.7;
    } else if (_todayWords.any(lower.contains)) {
      date = DateTime(now.year, now.month, now.day);
      confidence = 0.7;
    } else {
      for (int i = 0; i < _weekdayNames.length; i++) {
        if (lower.contains(_weekdayNames[i])) {
          final int delta = (i + 1 - now.weekday + 7) % 7;
          date = DateTime(now.year, now.month, now.day + delta);
          confidence = 0.65;
          break;
        }
      }
    }

    // Clock time: "6am", "6:30 pm", "at 8", "8 மணிக்கு", "8 बजे".
    final RegExp clockRe = RegExp(
      r'(?:at\s+)?(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|बजे|மணிக்கு|గంటకు|గంటలకు|ಗಂಟೆಗೆ)',
    );
    final RegExpMatch? clock = clockRe.firstMatch(lower);
    int? hour;
    int minute = 0;
    bool pm = false;
    if (clock != null) {
      hour = int.parse(clock.group(1)!);
      if (hour < 0 || hour > 23) {
        hour = null;
      } else {
        minute = int.tryParse(clock.group(2) ?? '') ?? 0;
        final String marker = clock.group(3)!;
        if (marker == 'pm') {
          pm = true;
        } else if (_morningWords.any(lower.contains)) {
          pm = false;
        } else if (_eveningWords.any(lower.contains)) {
          pm = true;
        } else if (marker != 'am' && hour <= 7) {
          // "8 மணிக்கு" without a day part is ambiguous; evening is the
          // more common reminder window, but we keep it low-confidence.
          pm = true;
        }
        if (pm && hour < 12) {
          hour += 12;
        }
        if (minute > 59) {
          minute = 0;
        }
      }
    }

    if (date != null && hour != null) {
      slots.add(
        Slot(
          name: SlotNames.time,
          value: '${_isoDate(date)}T${_two(hour)}:${_two(minute)}',
          confidence: 0.85,
        ),
      );
    } else if (hour != null) {
      slots.add(
        Slot(
          name: SlotNames.time,
          value:
              '${_isoDate(DateTime(now.year, now.month, now.day))}T${_two(hour)}:${_two(minute)}',
          confidence: 0.8,
        ),
      );
    } else if (date != null) {
      slots.add(
        Slot(name: SlotNames.time, value: _isoDate(date), confidence: confidence),
      );
    }
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${_two(d.month)}-${_two(d.day)}';
  static String _isoDateTime(DateTime d) => '${_isoDate(d)}T'
      '${_two(d.hour)}:${_two(d.minute)}';

  // -- calculate -----------------------------------------------------------------

  void _addExpression(List<Slot> slots, String text) {
    final String lower = normalizeDigits(text.toLowerCase())
        .replaceAll('multiplied by', '*')
        .replaceAll('multiply', '*')
        .replaceAll('times', '*')
        .replaceAll('divided by', '/')
        .replaceAll('divide', '/')
        .replaceAll(' plus ', ' + ')
        .replaceAll(' minus ', ' - ')
        .replaceAll(' x ', ' * ')
        .replaceAll('into', '*')
        .replaceAll('×', '*')
        .replaceAll('÷', '/')
        .replaceAll('percent of', '% of')
        .replaceAll('जोड़ो', '+')
        .replaceAll('जोड़', '+')
        .replaceAll('घटाओ', '-')
        .replaceAll('गुणा', '*')
        .replaceAll('भाग', '/')
        .replaceAll('கூட்டு', '+')
        .replaceAll('கழி', '-')
        .replaceAll('பெருக்கு', '*')
        .replaceAll('வகு', '/');

    final RegExp runRe = RegExp(r'[0-9\s.+\-*/%()]{3,}');
    for (final RegExpMatch match in runRe.allMatches(lower)) {
      final String candidate = match.group(0)!.trim();
      final bool hasDigit = candidate.contains(RegExp(r'\d'));
      final bool hasOperator =
          candidate.contains(RegExp(r'[+\-*/%]'));
      if (hasDigit && hasOperator && candidate.length >= 3) {
        slots.add(
          Slot(
            name: SlotNames.expression,
            value: candidate.replaceAll(RegExp(r'\s+'), ' '),
            confidence: 0.85,
          ),
        );
        return;
      }
    }
    // A lone number still carries information for the calculator.
    final RegExp numberRe = RegExp(r'\d+(?:\.\d+)?');
    final RegExpMatch? number = numberRe.firstMatch(lower);
    if (number != null) {
      slots.add(
        Slot(name: SlotNames.expression, value: number.group(0)!, confidence: 0.6),
      );
    }
  }

  // -- findNearby ----------------------------------------------------------------

  static const Map<String, List<String>> _placeWords = <String, List<String>>{
    'hospital': <String>[
      'hospital', 'மருத்துவமனை', 'हस्पताल', 'अस्पताल', 'ఆసుపత్రి', 'ಆಸ್ಪತ್ರೆ',
      'হাসপাতাল',
    ],
    'police': <String>[
      'police', 'காவல்', 'पुलिस', 'పోలీస్', 'ಪೊಲೀಸ್', 'পুলিশ',
    ],
    'pharmacy': <String>[
      'pharmacy', 'medical shop', 'chemist', 'மருந்தகம்', 'दवा की दुकान',
      'मेडिकल', 'మెడికల్', 'औषಧಿ ಅಂಗಡಿ',
    ],
    'bank': <String>['bank', 'வங்கி', 'बैंक', 'బ్యాంకు', 'ಬ್ಯಾಂಕ್', 'ব্যাংক'],
    'atm': <String>['atm', 'ஏடிஎம்', 'एटीएम'],
    'school': <String>[
      'school', 'பள்ளி', 'स्कूल', 'विद्यालय', 'పాఠశాల', 'ಶಾಲೆ', 'স্কুল',
    ],
    'bus_stop': <String>[
      'bus stop', 'bus stand', 'பேருந்து நிறுத்தம்', 'बस स्टैंड',
      'బస్ స్టాప్',
    ],
  };

  void _addLocationType(List<Slot> slots, String text) {
    final String lower = text.toLowerCase();
    for (final MapEntry<String, List<String>> entry in _placeWords.entries) {
      for (final String word in entry.value) {
        if (lower.contains(word.toLowerCase())) {
          slots.add(
            Slot(name: SlotNames.locationType, value: entry.key, confidence: 0.8),
          );
          return;
        }
      }
    }
  }

  // -- torch ---------------------------------------------------------------------

  static const List<String> _onWords = <String>[
    'on', 'turn on', 'switch on', 'ஆன்', 'போடு', 'चालू', 'जलाओ', 'ఆన్', 'ಆನ್',
    'ஜோதி',
  ];
  static const List<String> _offWords = <String>[
    'off', 'turn off', 'switch off', 'ஆஃப்', 'அணை', 'बंद', 'ఆఫ్', 'ಆಫ್',
  ];

  void _addDeviceAction(List<Slot> slots, String text) {
    final String lower = text.toLowerCase();
    String action = 'on'; // People overwhelmingly ask to turn it on...
    double confidence = 0.4;
    if (_offWords.any(lower.contains) && !_onWords.any(lower.contains)) {
      action = 'off';
      confidence = 0.85;
    } else if (_onWords.any(lower.contains) &&
        !_offWords.any(lower.contains)) {
      confidence = 0.85;
    }
    slots.add(
      Slot(name: SlotNames.deviceAction, value: action, confidence: confidence),
    );
  }
}
