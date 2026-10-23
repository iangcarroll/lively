package sh.ian.lively.model

/**
 * The few lines Lively shows each reader in their own language, so the
 * person across the table never has to read the phone owner's language.
 */
data class Phrases(
    val waitingForConnection: String,
    val translationFailed: String,
    val listening: String,
    val tapToStart: String,
    /** Tells the reader to speak their language. */
    val speakHint: String,
    /** Shown while the speech service connects, before Lively can hear anyone. */
    val connecting: String,
) {
    fun map(transform: (String) -> String) = Phrases(
        transform(waitingForConnection), transform(translationFailed), transform(listening),
        transform(tapToStart), transform(speakHint), transform(connecting),
    )

    companion object {
        /** By language code; covers every language in [Language.SONIOX]. */
        val ALL: Map<String, Phrases> = mapOf(
        "en" to Phrases("Waiting for connection", "Translation failed · Retry", "Listening. Go ahead and talk.", "Tap the mic to start", "Speak English. Lively translates for the other person.", "Connecting…"),
        "zh" to Phrases("等待网络连接", "翻译失败 · 重试", "正在听，请直接说话", "点麦克风开始", "说中文就可以，Lively 会翻译给对方。", "正在连接…"),
        "af" to Phrases("Wag vir verbinding", "Vertaling het misluk · Probeer weer", "Luister. Praat maar.", "Tik op die mikrofoon om te begin", "Praat Afrikaans. Lively vertaal vir die ander persoon.", "Koppel tans…"),
        "sq" to Phrases("Në pritje të lidhjes", "Përkthimi dështoi · Riprovo", "Po dëgjon. Fol lirisht.", "Prek mikrofonin për të filluar", "Fol shqip. Lively përkthen për personin tjetër.", "Po lidhet…"),
        "ar" to Phrases("في انتظار الاتصال", "فشلت الترجمة · إعادة المحاولة", "أستمع إليك. تفضّل بالكلام.", "اضغط على الميكروفون للبدء", "تحدّث بالعربية. يترجم Lively للشخص الآخر.", "جارٍ الاتصال…"),
        "az" to Phrases("Bağlantı gözlənilir", "Tərcümə alınmadı · Yenidən cəhd et", "Dinləyirəm. Danışa bilərsiniz.", "Başlamaq üçün mikrofona toxunun", "Azərbaycanca danışın. Lively qarşı tərəf üçün tərcümə edir.", "Qoşulur…"),
        "eu" to Phrases("Konexioaren zain", "Itzulpenak huts egin du · Saiatu berriro", "Entzuten. Hitz egin lasai.", "Sakatu mikrofonoa hasteko", "Hitz egin euskaraz. Lively-k beste pertsonarentzat itzultzen du.", "Konektatzen…"),
        "be" to Phrases("Чаканне падключэння", "Памылка перакладу · Паўтарыць", "Слухаю. Гаварыце.", "Націсніце на мікрафон, каб пачаць", "Гаварыце па-беларуску. Lively перакладзе для суразмоўцы.", "Падключэнне…"),
        "bn" to Phrases("সংযোগের অপেক্ষায়", "অনুবাদ ব্যর্থ · আবার চেষ্টা করুন", "শুনছি। বলুন।", "শুরু করতে মাইকে ট্যাপ করুন", "বাংলায় বলুন। Lively অন্য ব্যক্তির জন্য অনুবাদ করে।", "সংযোগ হচ্ছে…"),
        "bs" to Phrases("Čeka se veza", "Prevod nije uspio · Pokušaj ponovo", "Slušam. Slobodno govorite.", "Dodirnite mikrofon za početak", "Govorite bosanski. Lively prevodi za drugu osobu.", "Povezivanje…"),
        "bg" to Phrases("Изчакване на връзка", "Неуспешен превод · Опитай отново", "Слушам. Говорете.", "Докоснете микрофона, за да започнете", "Говорете на български. Lively превежда за другия човек.", "Свързване…"),
        "ca" to Phrases("Esperant connexió", "Error de traducció · Torna-ho a provar", "Escoltant. Ja pots parlar.", "Toca el micròfon per començar", "Parla en català. Lively tradueix per a l'altra persona.", "Connectant…"),
        "hr" to Phrases("Čeka se veza", "Prijevod nije uspio · Pokušaj ponovno", "Slušam. Slobodno govorite.", "Dodirnite mikrofon za početak", "Govorite hrvatski. Lively prevodi za drugu osobu.", "Povezivanje…"),
        "cs" to Phrases("Čekání na připojení", "Překlad selhal · Zkusit znovu", "Poslouchám. Mluvte.", "Klepněte na mikrofon a začněte", "Mluvte česky. Lively překládá pro druhou osobu.", "Připojování…"),
        "da" to Phrases("Venter på forbindelse", "Oversættelse mislykkedes · Prøv igen", "Lytter. Bare tal.", "Tryk på mikrofonen for at starte", "Tal dansk. Lively oversætter for den anden person.", "Opretter forbindelse…"),
        "nl" to Phrases("Wachten op verbinding", "Vertaling mislukt · Opnieuw", "Ik luister. Spreek maar.", "Tik op de microfoon om te beginnen", "Spreek Nederlands. Lively vertaalt voor de ander.", "Verbinden…"),
        "et" to Phrases("Ühenduse ootamine", "Tõlkimine ebaõnnestus · Proovi uuesti", "Kuulan. Räägi julgelt.", "Alustamiseks puuduta mikrofoni", "Räägi eesti keeles. Lively tõlgib teisele inimesele.", "Ühendamine…"),
        "fi" to Phrases("Odotetaan yhteyttä", "Käännös epäonnistui · Yritä uudelleen", "Kuuntelen. Puhu vain.", "Aloita napauttamalla mikrofonia", "Puhu suomea. Lively kääntää toiselle henkilölle.", "Yhdistetään…"),
        "fr" to Phrases("En attente de connexion", "Échec de la traduction · Réessayer", "J'écoute. Vous pouvez parler.", "Touchez le micro pour commencer", "Parlez français. Lively traduit pour l'autre personne.", "Connexion…"),
        "gl" to Phrases("Agardando conexión", "Erro na tradución · Tentar de novo", "Escoitando. Podes falar.", "Toca o micrófono para comezar", "Fala en galego. Lively traduce para a outra persoa.", "Conectando…"),
        "de" to Phrases("Warte auf Verbindung", "Übersetzung fehlgeschlagen · Erneut versuchen", "Ich höre zu. Sprich einfach los.", "Tippe auf das Mikrofon, um zu starten", "Sprich Deutsch. Lively übersetzt für die andere Person.", "Verbinde…"),
        "el" to Phrases("Αναμονή σύνδεσης", "Η μετάφραση απέτυχε · Δοκιμή ξανά", "Ακούω. Μιλήστε.", "Πατήστε το μικρόφωνο για να ξεκινήσετε", "Μιλήστε ελληνικά. Το Lively μεταφράζει για τον άλλον.", "Σύνδεση…"),
        "gu" to Phrases("કનેક્શનની રાહ", "અનુવાદ નિષ્ફળ · ફરી પ્રયાસ કરો", "સાંભળી રહ્યું છે. બોલો.", "શરૂ કરવા માટે માઇક પર ટેપ કરો", "ગુજરાતીમાં બોલો. Lively બીજી વ્યક્તિ માટે અનુવાદ કરે છે.", "કનેક્ટ થઈ રહ્યું છે…"),
        "he" to Phrases("ממתין לחיבור", "התרגום נכשל · נסה שוב", "מקשיב. אפשר לדבר.", "הקש על המיקרופון כדי להתחיל", "דבר עברית. Lively מתרגם בשביל האדם השני.", "מתחבר…"),
        "hi" to Phrases("कनेक्शन का इंतज़ार", "अनुवाद विफल · फिर से कोशिश करें", "सुन रहा है। बोलिए।", "शुरू करने के लिए माइक पर टैप करें", "हिंदी में बोलिए। Lively दूसरे व्यक्ति के लिए अनुवाद करता है।", "कनेक्ट हो रहा है…"),
        "hu" to Phrases("Várakozás a kapcsolatra", "A fordítás sikertelen · Újra", "Figyelek. Nyugodtan beszéljen.", "Koppintson a mikrofonra a kezdéshez", "Beszéljen magyarul. A Lively lefordítja a másik félnek.", "Kapcsolódás…"),
        "id" to Phrases("Menunggu koneksi", "Terjemahan gagal · Coba lagi", "Mendengarkan. Silakan bicara.", "Ketuk mikrofon untuk mulai", "Bicaralah dalam bahasa Indonesia. Lively menerjemahkan untuk lawan bicara.", "Menghubungkan…"),
        "it" to Phrases("In attesa di connessione", "Traduzione non riuscita · Riprova", "In ascolto. Parla pure.", "Tocca il microfono per iniziare", "Parla in italiano. Lively traduce per l'altra persona.", "Connessione in corso…"),
        "ja" to Phrases("接続を待っています", "翻訳に失敗しました · 再試行", "聞いています。どうぞ話してください。", "マイクをタップして開始", "日本語で話してください。Lively が相手に通訳します。", "接続しています…"),
        "kn" to Phrases("ಸಂಪರ್ಕಕ್ಕಾಗಿ ಕಾಯುತ್ತಿದೆ", "ಅನುವಾದ ವಿಫಲವಾಗಿದೆ · ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ", "ಕೇಳುತ್ತಿದೆ. ಮಾತನಾಡಿ.", "ಪ್ರಾರಂಭಿಸಲು ಮೈಕ್ ಟ್ಯಾಪ್ ಮಾಡಿ", "ಕನ್ನಡದಲ್ಲಿ ಮಾತನಾಡಿ. Lively ಇನ್ನೊಬ್ಬರಿಗಾಗಿ ಅನುವಾದಿಸುತ್ತದೆ.", "ಸಂಪರ್ಕಿಸಲಾಗುತ್ತಿದೆ…"),
        "kk" to Phrases("Қосылым күтілуде", "Аударма сәтсіз · Қайталау", "Тыңдап тұрмын. Сөйлей беріңіз.", "Бастау үшін микрофонды түртіңіз", "Қазақша сөйлеңіз. Lively екінші адамға аударып береді.", "Қосылуда…"),
        "ko" to Phrases("연결 대기 중", "번역 실패 · 다시 시도", "듣고 있어요. 말씀하세요.", "마이크를 눌러 시작하세요", "한국어로 말하세요. Lively가 상대방에게 번역해 드려요.", "연결 중…"),
        "lv" to Phrases("Gaida savienojumu", "Tulkošana neizdevās · Mēģināt vēlreiz", "Klausos. Runājiet.", "Pieskarieties mikrofonam, lai sāktu", "Runājiet latviski. Lively tulko otram cilvēkam.", "Savienojas…"),
        "lt" to Phrases("Laukiama ryšio", "Vertimas nepavyko · Bandyti dar kartą", "Klausausi. Kalbėkite.", "Bakstelėkite mikrofoną, kad pradėtumėte", "Kalbėkite lietuviškai. Lively išverčia kitam žmogui.", "Jungiamasi…"),
        "mk" to Phrases("Се чека врска", "Преводот не успеа · Обиди се повторно", "Слушам. Зборувајте.", "Допрете го микрофонот за да започнете", "Зборувајте македонски. Lively преведува за другото лице.", "Се поврзува…"),
        "ms" to Phrases("Menunggu sambungan", "Terjemahan gagal · Cuba lagi", "Mendengar. Sila bercakap.", "Ketik mikrofon untuk bermula", "Bercakap dalam bahasa Melayu. Lively menterjemah untuk orang lain.", "Menyambung…"),
        "ml" to Phrases("കണക്ഷനായി കാത്തിരിക്കുന്നു", "വിവർത്തനം പരാജയപ്പെട്ടു · വീണ്ടും ശ്രമിക്കുക", "കേൾക്കുന്നു. സംസാരിച്ചോളൂ.", "ആരംഭിക്കാൻ മൈക്കിൽ ടാപ്പ് ചെയ്യുക", "മലയാളത്തിൽ സംസാരിക്കൂ. Lively മറ്റേയാൾക്കായി വിവർത്തനം ചെയ്യും.", "കണക്റ്റ് ചെയ്യുന്നു…"),
        "mr" to Phrases("कनेक्शनची वाट पाहत आहे", "भाषांतर अयशस्वी · पुन्हा प्रयत्न करा", "ऐकत आहे. बोला.", "सुरू करण्यासाठी माइकवर टॅप करा", "मराठीत बोला. Lively दुसऱ्या व्यक्तीसाठी भाषांतर करते.", "कनेक्ट होत आहे…"),
        "no" to Phrases("Venter på tilkobling", "Oversettelsen mislyktes · Prøv igjen", "Lytter. Bare snakk.", "Trykk på mikrofonen for å starte", "Snakk norsk. Lively oversetter for den andre personen.", "Kobler til…"),
        "fa" to Phrases("در انتظار اتصال", "ترجمه ناموفق بود · تلاش دوباره", "در حال گوش دادن. صحبت کنید.", "برای شروع روی میکروفون بزنید", "فارسی صحبت کنید. Lively برای طرف مقابل ترجمه می‌کند.", "در حال اتصال…"),
        "pl" to Phrases("Oczekiwanie na połączenie", "Tłumaczenie nie powiodło się · Ponów", "Słucham. Możesz mówić.", "Stuknij mikrofon, aby zacząć", "Mów po polsku. Lively tłumaczy dla drugiej osoby.", "Łączenie…"),
        "pt" to Phrases("Aguardando conexão", "Falha na tradução · Tentar novamente", "Ouvindo. Pode falar.", "Toque no microfone para começar", "Fale em português. O Lively traduz para a outra pessoa.", "Conectando…"),
        "pa" to Phrases("ਕਨੈਕਸ਼ਨ ਦੀ ਉਡੀਕ", "ਅਨੁਵਾਦ ਅਸਫਲ · ਦੁਬਾਰਾ ਕੋਸ਼ਿਸ਼ ਕਰੋ", "ਸੁਣ ਰਿਹਾ ਹੈ। ਬੋਲੋ।", "ਸ਼ੁਰੂ ਕਰਨ ਲਈ ਮਾਈਕ 'ਤੇ ਟੈਪ ਕਰੋ", "ਪੰਜਾਬੀ ਵਿੱਚ ਬੋਲੋ। Lively ਦੂਜੇ ਵਿਅਕਤੀ ਲਈ ਅਨੁਵਾਦ ਕਰਦਾ ਹੈ।", "ਕਨੈਕਟ ਹੋ ਰਿਹਾ ਹੈ…"),
        "ro" to Phrases("Se așteaptă conexiunea", "Traducerea a eșuat · Reîncearcă", "Ascult. Puteți vorbi.", "Atingeți microfonul pentru a începe", "Vorbiți în română. Lively traduce pentru cealaltă persoană.", "Se conectează…"),
        "ru" to Phrases("Ожидание подключения", "Ошибка перевода · Повторить", "Слушаю. Говорите.", "Нажмите на микрофон, чтобы начать", "Говорите по-русски. Lively переведёт для собеседника.", "Подключение…"),
        "sr" to Phrases("Чека се веза", "Превод није успео · Покушај поново", "Слушам. Слободно говорите.", "Додирните микрофон за почетак", "Говорите српски. Lively преводи за другу особу.", "Повезивање…"),
        "sk" to Phrases("Čaká sa na pripojenie", "Preklad zlyhal · Skúsiť znova", "Počúvam. Hovorte.", "Ťuknite na mikrofón a začnite", "Hovorte po slovensky. Lively prekladá pre druhú osobu.", "Pripája sa…"),
        "sl" to Phrases("Čakanje na povezavo", "Prevod ni uspel · Poskusi znova", "Poslušam. Kar govorite.", "Tapnite mikrofon za začetek", "Govorite slovensko. Lively prevaja za drugo osebo.", "Povezovanje…"),
        "es" to Phrases("Esperando conexión", "Error de traducción · Reintentar", "Escuchando. Habla cuando quieras.", "Toca el micrófono para empezar", "Habla en español. Lively traduce para la otra persona.", "Conectando…"),
        "sw" to Phrases("Inasubiri muunganisho", "Tafsiri imeshindwa · Jaribu tena", "Inasikiliza. Endelea kuongea.", "Gusa maikrofoni ili kuanza", "Ongea Kiswahili. Lively inatafsiri kwa mtu mwingine.", "Inaunganisha…"),
        "sv" to Phrases("Väntar på anslutning", "Översättningen misslyckades · Försök igen", "Lyssnar. Prata på.", "Tryck på mikrofonen för att börja", "Prata svenska. Lively översätter åt den andra personen.", "Ansluter…"),
        "tl" to Phrases("Naghihintay ng koneksyon", "Nabigo ang pagsasalin · Subukang muli", "Nakikinig. Magsalita ka lang.", "I-tap ang mikropono para magsimula", "Magsalita sa Tagalog. Isinasalin ng Lively para sa kausap mo.", "Kumokonekta…"),
        "ta" to Phrases("இணைப்புக்காக காத்திருக்கிறது", "மொழிபெயர்ப்பு தோல்வி · மீண்டும் முயல்க", "கேட்கிறது. பேசுங்கள்.", "தொடங்க மைக்கைத் தட்டவும்", "தமிழில் பேசுங்கள். Lively மற்றவருக்காக மொழிபெயர்க்கும்.", "இணைக்கிறது…"),
        "te" to Phrases("కనెక్షన్ కోసం వేచి ఉంది", "అనువాదం విఫలమైంది · మళ్లీ ప్రయత్నించండి", "వింటోంది. మాట్లాడండి.", "ప్రారంభించడానికి మైక్‌ను నొక్కండి", "తెలుగులో మాట్లాడండి. Lively అవతలి వ్యక్తి కోసం అనువదిస్తుంది.", "కనెక్ట్ అవుతోంది…"),
        "th" to Phrases("กำลังรอการเชื่อมต่อ", "แปลไม่สำเร็จ · ลองอีกครั้ง", "กำลังฟัง พูดได้เลย", "แตะไมค์เพื่อเริ่ม", "พูดภาษาไทยได้เลย Lively จะแปลให้อีกฝ่าย", "กำลังเชื่อมต่อ…"),
        "tr" to Phrases("Bağlantı bekleniyor", "Çeviri başarısız · Tekrar dene", "Dinliyorum. Konuşabilirsiniz.", "Başlamak için mikrofona dokunun", "Türkçe konuşun. Lively karşı taraf için çevirir.", "Bağlanıyor…"),
        "uk" to Phrases("Очікування з’єднання", "Помилка перекладу · Повторити", "Слухаю. Говоріть.", "Торкніться мікрофона, щоб почати", "Говоріть українською. Lively перекладе для співрозмовника.", "Підключення…"),
        "ur" to Phrases("کنکشن کا انتظار", "ترجمہ ناکام · دوبارہ کوشش کریں", "سن رہا ہے۔ بولیے۔", "شروع کرنے کے لیے مائیک پر ٹیپ کریں", "اردو میں بولیے۔ Lively دوسرے شخص کے لیے ترجمہ کرتا ہے۔", "کنکٹ ہو رہا ہے…"),
        "vi" to Phrases("Đang chờ kết nối", "Dịch thất bại · Thử lại", "Đang nghe. Bạn cứ nói.", "Chạm vào micrô để bắt đầu", "Hãy nói tiếng Việt. Lively sẽ dịch cho người kia.", "Đang kết nối…"),
        "cy" to Phrases("Yn aros am gysylltiad", "Methodd y cyfieithu · Ceisio eto", "Yn gwrando. Siaradwch.", "Tapiwch y meicroffon i ddechrau", "Siaradwch Gymraeg. Mae Lively yn cyfieithu i'r person arall.", "Yn cysylltu…"),
        )
    }
}

/** This language's phrases in the chosen Chinese script, or English for a language without them. */
fun Language.phrases(script: ChineseScript): Phrases {
    val phrases = Phrases.ALL[code] ?: return Phrases.ALL.getValue("en")
    return if (this == Language.CHINESE) phrases.map(script::convert) else phrases
}
