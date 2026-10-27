/// Codegen-free localization for Neyam Vaani.
///
/// This Dart table is what the app reads today — zero codegen, zero extra
/// dependencies, CI-simple. The `.arb` files beside it mirror the exact
/// same strings so a later move to `flutter gen-l10n` is a mechanical
/// import swap, not a rewrite. See `l10n/README.md` for the dual-system
/// contract and the steward workflow.
///
/// Rules (TENDER_UX_PRINCIPLES.md, docs/use-cases.md):
/// - English is the base table; every other language carries exactly the
///   same key set (enforced by `test/l10n_strings_test.dart`).
/// - Tone everywhere: calm, feminine voice persona, simple everyday
///   words, respectful to elders. No exclamation marks, ever.
/// - Every non-English table ships behind a `steward review pending`
///   marker until a native-speaker steward signs off. No machine
///   translation ships unreviewed.
/// - Unknown language codes and missing keys fall back to English — a
///   grandmother never sees a blank screen, a raw key, or an error code.
library;

/// All user-facing strings of the app, resolved per language.
class AppStrings {
  /// Creates strings for [langCode] (use [AppStrings.of] to normalize
  /// unknown codes to English first).
  const AppStrings(this.langCode);

  /// BCP-47-ish code of the language these strings resolve in.
  final String langCode;

  /// The string tables, keyed by language code. English is the base:
  /// every non-English table must carry exactly the same keys.
  static const Map<String, Map<String, String>> table =
      <String, Map<String, String>>{
        'en': <String, String>{
          'appName': 'Neyam Vaani',
          'settingsTitle': 'Settings',
          'yourLanguage': 'Your language',
          'languageSubtitle': 'Used for listening and speaking',
          'listening': 'I\'m listening…',
          'thinking': 'I\'m thinking…',
          'speaking': 'I\'m speaking…',
          'transcribing': 'I\'m writing that down…',
          'tapAndSpeak': 'Tap the microphone and speak',
          'talkToVaani': 'Talk to Vaani',
          'couldNotHear': 'I couldn\'t hear you clearly. Can you try again?',
          'tryAgain': 'Try again',
          'iDontKnow': 'I don\'t know',
          'clearHistory': 'Clear conversation history',
          'clearHistoryDesc': 'Deletes everything, immediately',
          'scanDocument': 'Scan a document',
          'readAloud': 'Read it aloud',
          'photosNotSaved': 'Your photo is not saved anywhere',
          'needsRetype': 'You will need to type it again',
          'permissionMicWhy': 'To hear you',
          'permissionSmsWhy': 'To send the message you asked for',
          'permissionCallWhy': 'To make the call you asked for',
          'actionDone': 'Done',
          'actionFailed': 'I couldn\'t do that. Can we try again?',
          'greetingReply': 'Hello. I am Vaani. You can ask me about helpline numbers, fever, government schemes, or today\'s date and time.',
          'dateTimeReply': 'Today is {date}. The time is {time}.',
          'noAnswerYet': 'I don\'t know that yet. On this phone I can tell you helpline numbers, basic fever care, government schemes, and the date and time.',
          'voiceUnavailable': 'I can\'t use the microphone right now. You can type your question below.',
          'typeHere': 'Type your question',
          'send': 'Send',
        },
        // steward review pending (Tamil) — native-speaker sign-off required.
        'ta': <String, String>{
          'appName': 'நேயம் வாணி',
          'settingsTitle': 'அமைப்புகள்',
          'yourLanguage': 'உங்கள் மொழி',
          'languageSubtitle': 'கேட்கவும், பேசவும் பயன்படும்',
          'listening': 'கேட்குது…',
          'thinking': 'யோசிக்கிறேன்…',
          'speaking': 'சொல்கிறேன்…',
          'transcribing': 'எழுதி வருகிறேன்…',
          'tapAndSpeak': 'மைக்கைத் தட்டிப் பேசுங்கள்',
          'talkToVaani': 'வாணியுடன் பேசுங்கள்',
          'couldNotHear': 'நன்றாகக் கேட்கவில்லை. மீண்டும் முயற்சிக்கவா?',
          'tryAgain': 'மீண்டும் முயற்சிக்கவும்',
          'iDontKnow': 'எனக்குத் தெரியவில்லை',
          'clearHistory': 'உரையாடல் வரலாற்றை அழிக்கவும்',
          'clearHistoryDesc': 'எல்லாம் உடனடியாக அழிக்கப்படும்',
          'scanDocument': 'ஆவணத்தை ஸ்கேன் செய்யவும்',
          'readAloud': 'சத்தமாகப் படிக்கவும்',
          'photosNotSaved': 'உங்கள் புகைப்படம் எங்கேயும் சேமிக்கப்படாது',
          'needsRetype': 'இதை மீண்டும் தட்டச்சு செய்ய வேண்டும்',
          'permissionMicWhy': 'உங்களைக் கேட்க',
          'permissionSmsWhy': 'நீங்கள் கேட்ட செய்தியை அனுப்ப',
          'permissionCallWhy': 'நீங்கள் கேட்ட அழைப்பை மேற்கொள்ள',
          'actionDone': 'முடிந்தது',
          'actionFailed': 'அதைச் செய்ய முடியவில்லை. மீண்டும் முயற்சிக்கலாமா?',
          'greetingReply': 'வணக்கம். நான் வாணி. உதவி எண்கள், காய்ச்சல், அரசுத் திட்டங்கள், இன்றைய தேதி, நேரம் பற்றி என்னிடம் கேட்கலாம்.',
          'dateTimeReply': 'இன்று {date}. நேரம் {time}.',
          'noAnswerYet': 'இது எனக்கு இன்னும் தெரியாது. உதவி எண்கள், காய்ச்சல் கவனிப்பு, அரசுத் திட்டங்கள், தேதி, நேரம் பற்றி சொல்ல முடியும்.',
          'voiceUnavailable': 'இப்போது மைக்கைப் பயன்படுத்த முடியவில்லை. கீழே உங்கள் கேள்வியைத் தட்டச்சு செய்யலாம்.',
          'typeHere': 'உங்கள் கேள்வியைத் தட்டச்சு செய்யுங்கள்',
          'send': 'அனுப்பு',
        },
        // steward review pending (Hindi) — native-speaker sign-off required.
        'hi': <String, String>{
          'appName': 'नेयम वाणी',
          'settingsTitle': 'सेटिंग्स',
          'yourLanguage': 'आपकी भाषा',
          'languageSubtitle': 'सुनने और बोलने के लिए',
          'listening': 'सुन रही हूँ…',
          'thinking': 'सोच रही हूँ…',
          'speaking': 'बोल रही हूँ…',
          'transcribing': 'लिख रही हूँ…',
          'tapAndSpeak': 'माइक पर टैप करके बोलिए',
          'talkToVaani': 'वाणी से बात कीजिए',
          'couldNotHear': 'मैं ठीक से नहीं सुन पाई. फिर से बोलिए.',
          'tryAgain': 'फिर से कोशिश करें',
          'iDontKnow': 'मुझे नहीं पता',
          'clearHistory': 'बातचीत का इतिहास मिटाइए',
          'clearHistoryDesc': 'सब कुछ तुरंत मिट जाएगा',
          'scanDocument': 'दस्तावेज़ स्कैन कीजिए',
          'readAloud': 'पढ़कर सुनाइए',
          'photosNotSaved': 'आपकी फ़ोटो कहीं सेव नहीं होती',
          'needsRetype': 'इसे दोबारा टाइप करना होगा',
          'permissionMicWhy': 'आपको सुनने के लिए',
          'permissionSmsWhy': 'आपके कहे संदेश भेजने के लिए',
          'permissionCallWhy': 'आपके कहे कॉल करने के लिए',
          'actionDone': 'हो गया',
          'actionFailed': 'यह काम नहीं हो पाया. फिर से कोशिश करें?',
          'greetingReply': 'नमस्ते. मैं वाणी हूँ. आप मुझसे हेल्पलाइन नंबर, बुखार, सरकारी योजनाओं, या आज की तारीख और समय के बारे में पूछ सकते हैं.',
          'dateTimeReply': 'आज {date} है. समय {time} है.',
          'noAnswerYet': 'यह मुझे अभी नहीं पता. इस फ़ोन पर मैं हेल्पलाइन नंबर, बुखार की देखभाल, सरकारी योजनाएँ, और तारीख-समय बता सकती हूँ.',
          'voiceUnavailable': 'अभी मैं माइक इस्तेमाल नहीं कर पा रही हूँ. आप नीचे अपना सवाल टाइप कर सकते हैं.',
          'typeHere': 'अपना सवाल टाइप कीजिए',
          'send': 'भेजें',
        },
        // steward review pending (Bengali) — native-speaker sign-off required.
        'bn': <String, String>{
          'appName': 'নেয়াম ভাণী',
          'settingsTitle': 'সেটিংস',
          'yourLanguage': 'আপনার ভাষা',
          'languageSubtitle': 'শোনা ও বলার জন্য',
          'listening': 'শুনছি…',
          'thinking': 'ভাবছি…',
          'speaking': 'বলছি…',
          'transcribing': 'লিখছি…',
          'tapAndSpeak': 'মাইক ছুঁয়ে বলুন',
          'talkToVaani': 'ভাণীর সঙ্গে কথা বলুন',
          'couldNotHear': 'ভালো করে শুনতে পারিনি. আবার বলবেন?',
          'tryAgain': 'আবার চেষ্টা করুন',
          'iDontKnow': 'আমি জানি না',
          'clearHistory': 'কথোপকথনের ইতিহাস মুছে দিন',
          'clearHistoryDesc': 'সব কিছু সঙ্গে সঙ্গে মুছে যাবে',
          'scanDocument': 'নথি স্ক্যান করুন',
          'readAloud': 'পড়ে শোনান',
          'photosNotSaved': 'আপনার ছবি কোথাও সেভ হয় না',
          'needsRetype': 'এটি আবার টাইপ করতে হবে',
          'permissionMicWhy': 'আপনাকে শোনার জন্য',
          'permissionSmsWhy': 'আপনার বলা বার্তা পাঠানোর জন্য',
          'permissionCallWhy': 'আপনার বলা কল করার জন্য',
          'actionDone': 'হয়ে গেছে',
          'actionFailed': 'কাজটি হয়নি. আবার চেষ্টা করবেন?',
          'greetingReply': 'নমস্কার. আমি ভাণী. হেল্পলাইন নম্বর, জ্বর, সরকারি প্রকল্প, বা আজকের তারিখ ও সময় নিয়ে আমাকে জিজ্ঞেস করতে পারেন.',
          'dateTimeReply': 'আজ {date}. এখন সময় {time}.',
          'noAnswerYet': 'এটা আমি এখনও জানি না. এই ফোনে আমি হেল্পলাইন নম্বর, জ্বরের যত্ন, সরকারি প্রকল্প, আর তারিখ ও সময় বলতে পারি.',
          'voiceUnavailable': 'এখন মাইক ব্যবহার করতে পারছি না. নিচে আপনার প্রশ্ন লিখতে পারেন.',
          'typeHere': 'আপনার প্রশ্ন লিখুন',
          'send': 'পাঠান',
        },
        // steward review pending (Kannada) — native-speaker sign-off required.
        'kn': <String, String>{
          'appName': 'ನೇಯಮ್ ವಾಣಿ',
          'settingsTitle': 'ಸೆಟ್ಟಿಂಗ್‌ಗಳು',
          'yourLanguage': 'ನಿಮ್ಮ ಭಾಷೆ',
          'languageSubtitle': 'ಕೇಳಲು ಮತ್ತು ಮಾತನಾಡಲು',
          'listening': 'ಕೇಳುತ್ತಿದ್ದೇನೆ…',
          'thinking': 'ಯೋಚಿಸುತ್ತಿದ್ದೇನೆ…',
          'speaking': 'ಹೇಳುತ್ತಿದ್ದೇನೆ…',
          'transcribing': 'ಬರೆಯುತ್ತಿದ್ದೇನೆ…',
          'tapAndSpeak': 'ಮೈಕ್ ಒತ್ತಿ ಮಾತನಾಡಿ',
          'talkToVaani': 'ವಾಣಿಯೊಂದಿಗೆ ಮಾತನಾಡಿ',
          'couldNotHear': 'ಚೆನ್ನಾಗಿ ಕೇಳಲಿಲ್ಲ. ಇನ್ನೊಮ್ಮೆ ಹೇಳುತ್ತೀರಾ?',
          'tryAgain': 'ಇನ್ನೊಮ್ಮೆ ಪ್ರಯತ್ನಿಸಿ',
          'iDontKnow': 'ನನಗೆ ಗೊತ್ತಿಲ್ಲ',
          'clearHistory': 'ಸಂಭಾಷಣೆಯ ಇತಿಹಾಸ ಅಳಿಸಿ',
          'clearHistoryDesc': 'ಎಲ್ಲವೂ ತಕ್ಷಣ ಅಳಿಸಲ್ಪಡುತ್ತದೆ',
          'scanDocument': 'ದಾಖಲೆಯನ್ನು ಸ್ಕ್ಯಾನ್ ಮಾಡಿ',
          'readAloud': 'ಜೋರಾಗಿ ಓದಿ',
          'photosNotSaved': 'ನಿಮ್ಮ ಫೋಟು ಎಲ್ಲೂ ಉಳಿಸಲ್ಪಡುವುದಿಲ್ಲ',
          'needsRetype': 'ಇದನ್ನು ಮತ್ತೆ ಟೈಪ್ ಮಾಡಬೇಕಾಗುತ್ತದೆ',
          'permissionMicWhy': 'ನಿಮ್ಮನ್ನು ಕೇಳಲು',
          'permissionSmsWhy': 'ನೀವು ಕೇಳಿದ ಸಂದೇಶ ಕಳುಹಿಸಲು',
          'permissionCallWhy': 'ನೀವು ಕೇಳಿದ ಕರೆ ಮಾಡಲು',
          'actionDone': 'ಆಯಿತು',
          'actionFailed': 'ಅದು ಆಗಲಿಲ್ಲ. ಇನ್ನೊಮ್ಮೆ ಪ್ರಯತ್ನಿಸಿದರಾ?',
          'greetingReply': 'ನಮಸ್ಕಾರ. ನಾನು ವಾಣಿ. ಸಹಾಯವಾಣಿ ಸಂಖ್ಯೆಗಳು, ಜ್ವರ, ಸರ್ಕಾರಿ ಯೋಜನೆಗಳು, ಅಥವಾ ಇಂದಿನ ದಿನಾಂಕ ಮತ್ತು ಸಮಯದ ಬಗ್ಗೆ ನನ್ನನ್ನು ಕೇಳಬಹುದು.',
          'dateTimeReply': 'ಇಂದು {date}. ಸಮಯ {time}.',
          'noAnswerYet': 'ಇದು ನನಗೆ ಇನ್ನೂ ಗೊತ್ತಿಲ್ಲ. ಈ ಫೋನಿನಲ್ಲಿ ಸಹಾಯವಾಣಿ ಸಂಖ್ಯೆಗಳು, ಜ್ವರದ ಆರೈಕೆ, ಸರ್ಕಾರಿ ಯೋಜನೆಗಳು, ದಿನಾಂಕ ಮತ್ತು ಸಮಯ ಹೇಳಬಲ್ಲೆ.',
          'voiceUnavailable': 'ಈಗ ಮೈಕ್ ಬಳಸಲು ಆಗುತ್ತಿಲ್ಲ. ಕೆಳಗೆ ನಿಮ್ಮ ಪ್ರಶ್ನೆಯನ್ನು ಟೈಪ್ ಮಾಡಬಹುದು.',
          'typeHere': 'ನಿಮ್ಮ ಪ್ರಶ್ನೆಯನ್ನು ಟೈಪ್ ಮಾಡಿ',
          'send': 'ಕಳುಹಿಸಿ',
        },
        // steward review pending (Telugu) — native-speaker sign-off required.
        'te': <String, String>{
          'appName': 'నేయమ్ వాణి',
          'settingsTitle': 'సెట్టింగ్‌లు',
          'yourLanguage': 'మీ భాష',
          'languageSubtitle': 'వినడానికి మరియు మాట్లాడటానికి',
          'listening': 'వింటున్నాను…',
          'thinking': 'ఆలోచిస్తున్నాను…',
          'speaking': 'చెబుతున్నాను…',
          'transcribing': 'రాస్తున్నాను…',
          'tapAndSpeak': 'మైక్ నొక్కి మాట్లాడండి',
          'talkToVaani': 'వాణితో మాట్లాడండి',
          'couldNotHear': 'సరిగ్గా వినపడలేదు. మళ్ళీ చెబుతారా?',
          'tryAgain': 'మళ్ళీ ప్రయత్నించండి',
          'iDontKnow': 'నాకు తెలియదు',
          'clearHistory': 'సంభాషణ చరిత్రను తొలగించండి',
          'clearHistoryDesc': 'అంతా వెంటనే తొలగిపోతుంది',
          'scanDocument': 'పత్రాన్ని స్కాన్ చేయండి',
          'readAloud': 'బిగ్గరగా చదివి వినిపించండి',
          'photosNotSaved': 'మీ ఫోటో ఎక్కడా సేవ్ చేయబడదు',
          'needsRetype': 'ఇది మళ్ళీ టైప్ చేయాలి',
          'permissionMicWhy': 'మిమ్మల్ని వినడానికి',
          'permissionSmsWhy': 'మీరు అడిగిన సందేశం పంపడానికి',
          'permissionCallWhy': 'మీరు అడిగిన కాల్ చేయడానికి',
          'actionDone': 'అయిపోయింది',
          'actionFailed': 'అది చేయబడలేదు. మళ్ళీ ప్రయత్నించాలా?',
          'greetingReply': 'నమస్కారం. నేను వాణి. హెల్ప్‌లైన్ నంబర్లు, జ్వరం, ప్రభుత్వ పథకాలు, లేదా ఈరోజు తేదీ, సమయం గురించి నన్ను అడగవచ్చు.',
          'dateTimeReply': 'ఈరోజు {date}. సమయం {time}.',
          'noAnswerYet': 'ఇది నాకు ఇంకా తెలియదు. ఈ ఫోన్‌లో హెల్ప్‌లైన్ నంబర్లు, జ్వరం జాగ్రత్తలు, ప్రభుత్వ పథకాలు, తేదీ, సమయం చెప్పగలను.',
          'voiceUnavailable': 'ఇప్పుడు మైక్ వాడలేకపోతున్నాను. కింద మీ ప్రశ్నను టైప్ చేయవచ్చు.',
          'typeHere': 'మీ ప్రశ్నను టైప్ చేయండి',
          'send': 'పంపండి',
        },
        // steward review pending (Marathi) — native-speaker sign-off required.
        'mr': <String, String>{
          'appName': 'नेयम वाणी',
          'settingsTitle': 'सेटिंग्ज',
          'yourLanguage': 'तुमची भाषा',
          'languageSubtitle': 'ऐकण्यासाठी आणि बोलण्यासाठी',
          'listening': 'ऐकते आहे…',
          'thinking': 'विचार करते आहे…',
          'speaking': 'सांगते आहे…',
          'transcribing': 'लिहिते आहे…',
          'tapAndSpeak': 'मायक दाबून बोला',
          'talkToVaani': 'वाणीशी बोला',
          'couldNotHear': 'नीट ऐकू आले नाही. पुन्हा सांगाल का?',
          'tryAgain': 'पुन्हा प्रयत्न करा',
          'iDontKnow': 'मला माहीत नाही',
          'clearHistory': 'संभाषणाचा इतिहास पुसून टाका',
          'clearHistoryDesc': 'सर्व काही लगेच पुसले जाईल',
          'scanDocument': 'दस्तऐवज स्कॅन करा',
          'readAloud': 'वाचून दाखवा',
          'photosNotSaved': 'तुमचा फोटो कुठेही सेव्ह होत नाही',
          'needsRetype': 'हे पुन्हा टाइप करावे लागेल',
          'permissionMicWhy': 'तुम्हाला ऐकण्यासाठी',
          'permissionSmsWhy': 'तुम्ही सांगितलेला संदेश पाठवण्यासाठी',
          'permissionCallWhy': 'तुम्ही सांगितलेला कॉल करण्यासाठी',
          'actionDone': 'झाले',
          'actionFailed': 'ते होऊ शकले नाही. पुन्हा प्रयत्न करू का?',
          'greetingReply': 'नमस्कार. मी वाणी. हेल्पलाइन नंबर, ताप, सरकारी योजना, किंवा आजची तारीख आणि वेळ याबद्दल मला विचारू शकता.',
          'dateTimeReply': 'आज {date} आहे. वेळ {time} आहे.',
          'noAnswerYet': 'हे मला अजून माहीत नाही. या फोनवर मी हेल्पलाइन नंबर, तापाची काळजी, सरकारी योजना, आणि तारीख-वेळ सांगू शकते.',
          'voiceUnavailable': 'आत्ता मायक वापरता येत नाही. खाली तुमचा प्रश्न टाइप करू शकता.',
          'typeHere': 'तुमचा प्रश्न टाइप करा',
          'send': 'पाठवा',
        },
        // steward review pending (Bhojpuri) — native-speaker sign-off required.
        'bho': <String, String>{
          'appName': 'नेयम वाणी',
          'settingsTitle': 'सेटिंग',
          'yourLanguage': 'आपन भाषा',
          'languageSubtitle': 'सुनला आ बोलला खातिर',
          'listening': 'सुनत बानी…',
          'thinking': 'सोचत बानी…',
          'speaking': 'कहत बानी…',
          'transcribing': 'लिखत बानी…',
          'tapAndSpeak': 'माइक दबाके बोली',
          'talkToVaani': 'वाणी से बात करीं',
          'couldNotHear': 'नीके से ना सुन पाइनी. फिर से कहीं?',
          'tryAgain': 'फिर से कोसिस करीं',
          'iDontKnow': 'मोके पता नइखे',
          'clearHistory': 'बातचीत के इतिहास मेटाईं',
          'clearHistoryDesc': 'सब कुछ तुरंत मेट जाई',
          'scanDocument': 'कागजाद स्कैन करीं',
          'readAloud': 'पढ़के सुनाईं',
          'photosNotSaved': 'आपन फोटो कतहुँ ना सेव होला',
          'needsRetype': 'एकरा फिर से टाइप करे के पड़ी',
          'permissionMicWhy': 'आपना सुने खातिर',
          'permissionSmsWhy': 'आपना कहल संदेस भेजे खातिर',
          'permissionCallWhy': 'आपना कहल कॉल करे खातिर',
          'actionDone': 'भइल',
          'actionFailed': 'ई ना हो पाइल. फिर से कोसिस करीं का?',
          'greetingReply': 'प्रणाम. हम वाणी हईं. हेल्पलाइन नंबर, बुखार, सरकारी योजना, भा आज के तारीख आ समय के बारे में पूछ सकेनी.',
          'dateTimeReply': 'आज {date} बा. समय {time} बा.',
          'noAnswerYet': 'ई हमके अबहीं ना पता. एह फोन पर हम हेल्पलाइन नंबर, बुखार के देखभाल, सरकारी योजना, आ तारीख-समय बता सकेनी.',
          'voiceUnavailable': 'अबहीं माइक ना चल पावत बा. नीचे आपन सवाल टाइप करीं.',
          'typeHere': 'आपन सवाल टाइप करीं',
          'send': 'भेजीं',
        },
        // steward review pending (Maithili) — native-speaker sign-off required.
        'mai': <String, String>{
          'appName': 'नेयम वाणी',
          'settingsTitle': 'सेटिंग',
          'yourLanguage': 'अहाँक भाषा',
          'languageSubtitle': 'सुनबाक आ बाजबाक लेल',
          'listening': 'सुनि रहल छी…',
          'thinking': 'विचारि रहल छी…',
          'speaking': 'कहि रहल छी…',
          'transcribing': 'लिखि रहल छी…',
          'tapAndSpeak': 'माइक दबाकए बाजू',
          'talkToVaani': 'वाणी सँग बाजू',
          'couldNotHear': 'नीकसँ सुनि नहि पाइलहुँ. फिनु कहबै का?',
          'tryAgain': 'फिनु कोशिश करू',
          'iDontKnow': 'हमके नहि मालूम',
          'clearHistory': 'बातचीतक इतिहास मेटाऊ',
          'clearHistoryDesc': 'सब किछु तुरते मेटि जएताह',
          'scanDocument': 'दस्तावेज स्कैन करू',
          'readAloud': 'पढ़कए सुनाऊ',
          'photosNotSaved': 'अहाँक फोटो कतहु नहि सेव होइत अछि',
          'needsRetype': 'एकरा फिनु टाइप करबाक पड़त',
          'permissionMicWhy': 'अहाँके सुनबाक लेल',
          'permissionSmsWhy': 'अहाँक कहल संदेश पठाबैक लेल',
          'permissionCallWhy': 'अहाँक कहल कॉल करबाक लेल',
          'actionDone': 'भेल',
          'actionFailed': 'ई नहि हो पाल. फिनु कोशिश करू का?',
          'greetingReply': 'प्रणाम. हम वाणी छी. हेल्पलाइन नंबर, बुखार, सरकारी योजना, वा आजुक तारीख आ समयक बारेमे पूछि सकैत छी.',
          'dateTimeReply': 'आइ {date} अछि. समय {time} अछि.',
          'noAnswerYet': 'ई हमरा एखन नहि बुझल अछि. एहि फोन पर हम हेल्पलाइन नंबर, बुखारक देखभाल, सरकारी योजना, आ तारीख-समय कहि सकैत छी.',
          'voiceUnavailable': 'एखन माइक नहि चलि रहल अछि. नीचाँ अपन प्रश्न टाइप करू.',
          'typeHere': 'अपन प्रश्न टाइप करू',
          'send': 'पठाउ',
        },
      };

  /// Strings for [langCode], falling back to English for unknown codes.
  factory AppStrings.of(String langCode) =>
      AppStrings(table.containsKey(langCode) ? langCode : 'en');

  Map<String, String> get _values => table[langCode] ?? table['en']!;

  /// Resolves [key]: the user's language first, then the English base,
  /// then the calm generic English sentence — never a blank, never a raw
  /// key on a user's screen.
  String resolve(String key) =>
      _values[key] ?? table['en']![key] ?? table['en']!['actionFailed']!;

  // Typed lookups, so a renamed key is a compile-time error, not a
  // silently missing sentence.

  String get appName => resolve('appName');
  String get settingsTitle => resolve('settingsTitle');
  String get yourLanguage => resolve('yourLanguage');
  String get languageSubtitle => resolve('languageSubtitle');
  String get listening => resolve('listening');
  String get thinking => resolve('thinking');
  String get speaking => resolve('speaking');
  String get transcribing => resolve('transcribing');
  String get tapAndSpeak => resolve('tapAndSpeak');
  String get talkToVaani => resolve('talkToVaani');
  String get couldNotHear => resolve('couldNotHear');
  String get tryAgain => resolve('tryAgain');
  String get iDontKnow => resolve('iDontKnow');
  String get clearHistory => resolve('clearHistory');
  String get clearHistoryDesc => resolve('clearHistoryDesc');
  String get scanDocument => resolve('scanDocument');
  String get readAloud => resolve('readAloud');
  String get photosNotSaved => resolve('photosNotSaved');
  String get needsRetype => resolve('needsRetype');
  String get permissionMicWhy => resolve('permissionMicWhy');
  String get permissionSmsWhy => resolve('permissionSmsWhy');
  String get permissionCallWhy => resolve('permissionCallWhy');
  String get actionDone => resolve('actionDone');
  String get actionFailed => resolve('actionFailed');
  String get greetingReply => resolve('greetingReply');
  String get noAnswerYet => resolve('noAnswerYet');
  String get voiceUnavailable => resolve('voiceUnavailable');
  String get typeHere => resolve('typeHere');
  String get send => resolve('send');

  /// "Today is {date}. The time is {time}." with both filled in.
  String dateTimeReply({required String date, required String time}) =>
      resolve('dateTimeReply')
          .replaceAll('{date}', date)
          .replaceAll('{time}', time);
}
