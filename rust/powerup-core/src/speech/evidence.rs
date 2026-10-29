//! The evidence a statistical answer in a Latin or Cyrillic script must
//! agree with before the core names it (HK-425).
//!
//! whatlang's confidence is how far its best trigram score stands above
//! the runner-up's, and on the short, terse prose replies are made of it is
//! confidently wrong: "Same connection, de-dup and drop paths as a real pad
//! (a drop releases held buttons)." is French to it at 0.93, a Czech reply
//! Portuguese, Swahili Indonesian, where NLLanguageRecognizer said English,
//! Czech and nothing. No confidence gate separates those from its right
//! answers, so for the 24 languages written in these two scripts the core
//! asks two other questions of the text, and names the answer only when
//! both agree with it:
//!
//! 1. Its letters fit the answer's alphabet: no letter of the answer's
//!    script that the language does not write (`ř` is no Portuguese letter,
//!    `ў` and `і` no Russian ones). ASCII letters fit every Latin alphabet,
//!    and letters of other scripts are not looked at.
//! 2. Its function words point to the answer alone: the text holds more
//!    of the answer's commonest function words than of any other listed
//!    language's whose alphabet the letters fit, and than of English's
//!    whatever the letters (an English sentence quoting "Zürich" is still
//!    English). A word is a run of Alphabetic scalars, lowercased, so
//!    `l'erreur` is `l` and `erreur`; a word several lists hold counts for
//!    each of them. A capital `İ` lowers to `i` alone ([`lowered`]), so
//!    Turkish `İçin` is `için`, not `i` and `çin`.
//!
//! An answer the evidence does not back is undecided, which reads as
//! English: a wrong voice is worse than the fallback.

/// The script a language's alphabet is checked in.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Script {
    /// U+00C0..U+024F and U+1E00..U+1EFF; ASCII letters fit every Latin
    /// alphabet.
    Latin,
    /// U+0400..U+052F.
    Cyrillic,
}

/// What a language's answer is checked against.
struct Evidence {
    /// The subtag the core answers for it.
    code: &'static str,
    /// The script its alphabet is checked in.
    script: Script,
    /// The lowercase letters of that script it writes: outside ASCII for
    /// Latin, the whole alphabet for Cyrillic.
    letters: &'static str,
    /// Its commonest function words, lowercase, sorted by bytes.
    words: &'static [&'static str],
}

/// Every language whose answer the evidence checks, in the order of
/// `language::LANGUAGES`.
const TABLE: [Evidence; 24] = [
    Evidence {
        code: "en",
        script: Script::Latin,
        letters: "",
        words: &[
            "a", "after", "all", "also", "an", "and", "any", "are", "as", "at", "be", "been",
            "before", "but", "by", "can", "could", "did", "do", "does", "each", "every", "for",
            "from", "had", "has", "have", "he", "here", "how", "i", "if", "in", "instead", "into",
            "is", "it", "its", "just", "ll", "never", "no", "not", "now", "of", "on", "one",
            "only", "or", "over", "own", "per", "plus", "s", "same", "she", "should", "so",
            "still", "t", "than", "that", "the", "then", "there", "these", "they", "this", "those",
            "to", "two", "via", "was", "we", "were", "what", "when", "where", "which", "who",
            "why", "will", "with", "would", "you",
        ],
    },
    Evidence {
        code: "es",
        script: Script::Latin,
        letters: "áéíñóúü",
        words: &[
            "a", "ahora", "al", "como", "con", "cuando", "de", "del", "el", "en", "era", "es",
            "esa", "ese", "esta", "este", "está", "están", "fue", "ha", "han", "hasta", "hay",
            "he", "la", "las", "lo", "los", "me", "mi", "muy", "más", "nada", "no", "o", "para",
            "pero", "por", "porque", "que", "qué", "se", "si", "sobre", "son", "su", "sus", "sí",
            "también", "te", "todavía", "todo", "todos", "tu", "un", "una", "unas", "unos", "y",
            "ya", "yo",
        ],
    },
    Evidence {
        code: "pt",
        script: Script::Latin,
        letters: "àáâãçéêíóôõú",
        words: &[
            "a", "agora", "ainda", "ao", "aos", "as", "com", "como", "da", "das", "de", "do",
            "dos", "e", "ela", "ele", "em", "era", "essa", "esse", "esta", "este", "está", "estão",
            "eu", "foi", "isso", "isto", "já", "mais", "mas", "muito", "na", "nada", "nas", "no",
            "nos", "não", "o", "os", "ou", "para", "pela", "pelo", "por", "porque", "quando",
            "que", "se", "seu", "sua", "são", "só", "também", "tem", "todas", "todo", "todos",
            "um", "uma", "umas", "uns", "você", "é",
        ],
    },
    Evidence {
        code: "it",
        script: Script::Latin,
        letters: "àèéìíîòóùú",
        words: &[
            "ai", "al", "alla", "anche", "ancora", "che", "ci", "come", "con", "da", "dal",
            "dalla", "dei", "del", "della", "delle", "dello", "di", "e", "ed", "era", "fra", "già",
            "gli", "ha", "hanno", "ho", "i", "il", "in", "l", "la", "le", "lo", "ma", "mi", "nel",
            "nella", "niente", "non", "o", "ora", "per", "perché", "più", "quando", "quella",
            "quello", "questa", "questo", "si", "solo", "sono", "su", "sul", "sulla", "ti", "tra",
            "tutte", "tutti", "tutto", "un", "una", "uno", "è",
        ],
    },
    Evidence {
        code: "fr",
        script: Script::Latin,
        letters: "àâæçèéêëîïôùûüÿœ",
        words: &[
            "a",
            "ai",
            "au",
            "aussi",
            "aux",
            "avec",
            "ce",
            "ces",
            "cette",
            "comme",
            "dans",
            "de",
            "des",
            "du",
            "déjà",
            "elle",
            "en",
            "encore",
            "est",
            "et",
            "il",
            "ils",
            "j",
            "je",
            "l",
            "la",
            "le",
            "les",
            "maintenant",
            "mais",
            "mon",
            "n",
            "ne",
            "nous",
            "on",
            "ont",
            "ou",
            "où",
            "par",
            "parce",
            "pas",
            "plus",
            "pour",
            "qu",
            "quand",
            "que",
            "qui",
            "rien",
            "se",
            "si",
            "son",
            "sont",
            "sur",
            "ton",
            "tous",
            "tout",
            "toutes",
            "très",
            "tu",
            "un",
            "une",
            "vous",
            "était",
        ],
    },
    Evidence {
        code: "de",
        script: Script::Latin,
        letters: "ßäöü",
        words: &[
            "aber", "alle", "als", "am", "auch", "auf", "aus", "bei", "das", "dass", "dem", "den",
            "der", "des", "dich", "die", "diese", "dieser", "dieses", "dir", "du", "durch", "ein",
            "eine", "einem", "einen", "einer", "er", "es", "für", "gerade", "habe", "haben", "hat",
            "ich", "ihr", "im", "ist", "jetzt", "kann", "kein", "keine", "mich", "mir", "mit",
            "nach", "nicht", "nichts", "noch", "nur", "ob", "oder", "schon", "sich", "sie", "sind",
            "soll", "und", "uns", "von", "war", "warum", "weil", "wenn", "werden", "wie", "wir",
            "wird", "wurde", "zu", "zum", "zur",
        ],
    },
    Evidence {
        code: "pl",
        script: Script::Latin,
        letters: "óąćęłńśźż",
        words: &[
            "a",
            "ale",
            "bo",
            "był",
            "była",
            "było",
            "co",
            "czy",
            "dla",
            "do",
            "go",
            "i",
            "ich",
            "ja",
            "jak",
            "jego",
            "jej",
            "jest",
            "jestem",
            "jeszcze",
            "już",
            "która",
            "które",
            "który",
            "lub",
            "ma",
            "mam",
            "mi",
            "mnie",
            "na",
            "nic",
            "niczego",
            "nie",
            "o",
            "od",
            "oraz",
            "po",
            "przez",
            "przy",
            "się",
            "są",
            "ta",
            "tak",
            "te",
            "ten",
            "teraz",
            "też",
            "to",
            "ty",
            "tylko",
            "w",
            "we",
            "wszystkie",
            "z",
            "za",
            "ze",
            "został",
            "została",
            "zostało",
            "zostały",
            "że",
        ],
    },
    Evidence {
        code: "nb",
        script: Script::Latin,
        letters: "åæéòóôø",
        words: &[
            "alle",
            "at",
            "av",
            "bare",
            "ble",
            "blitt",
            "de",
            "deg",
            "den",
            "denne",
            "der",
            "dere",
            "det",
            "dette",
            "disse",
            "du",
            "ei",
            "en",
            "enn",
            "ennå",
            "er",
            "et",
            "etter",
            "for",
            "fordi",
            "fra",
            "får",
            "fått",
            "hadde",
            "han",
            "har",
            "her",
            "hun",
            "hva",
            "hvilken",
            "hvis",
            "i",
            "ikke",
            "ingen",
            "ingenting",
            "jeg",
            "kan",
            "kunne",
            "med",
            "meg",
            "men",
            "mer",
            "mye",
            "noe",
            "nå",
            "og",
            "også",
            "om",
            "på",
            "skal",
            "skulle",
            "som",
            "så",
            "til",
            "var",
            "vet",
            "vi",
            "vil",
        ],
    },
    Evidence {
        code: "da",
        script: Script::Latin,
        letters: "åæéø",
        words: &[
            "af", "alle", "at", "blev", "blevet", "de", "den", "denne", "der", "det", "dette",
            "dig", "disse", "du", "efter", "en", "end", "endnu", "er", "et", "for", "fordi", "fra",
            "han", "har", "havde", "her", "hun", "hvad", "hvilken", "hvis", "i", "ikke", "ingen",
            "intet", "jeg", "kan", "kun", "kunne", "med", "meget", "men", "mere", "mig", "noget",
            "nu", "og", "også", "om", "på", "skal", "skulle", "som", "så", "til", "var", "ved",
            "vi", "vil",
        ],
    },
    Evidence {
        code: "sv",
        script: Script::Latin,
        letters: "äåéö",
        words: &[
            "alla", "att", "av", "bara", "blev", "blivit", "de", "den", "denna", "dessa", "det",
            "detta", "dig", "du", "där", "eftersom", "en", "ett", "från", "för", "hade", "han",
            "har", "hon", "här", "i", "ingen", "inget", "inte", "jag", "kan", "kunde", "med",
            "men", "mer", "mig", "mycket", "ni", "nu", "något", "och", "också", "om", "på", "ska",
            "skulle", "som", "så", "till", "var", "vet", "vi", "vilken", "vill", "än", "är",
        ],
    },
    Evidence {
        code: "fi",
        script: Script::Latin,
        letters: "äåöšž",
        words: &[
            "ei", "en", "et", "että", "he", "hän", "ja", "jo", "jos", "kaikki", "koska", "kuin",
            "kun", "me", "mikä", "minä", "mitä", "mitään", "mutta", "myös", "niin", "nyt", "ole",
            "olen", "olet", "oli", "on", "ovat", "se", "sen", "sinä", "sitä", "tai", "te", "tämä",
            "tätä", "vain", "vielä", "voi",
        ],
    },
    Evidence {
        code: "tr",
        script: Script::Latin,
        letters: "âçîöûüğış",
        words: &[
            "ama", "artık", "ben", "bir", "biz", "bu", "da", "daha", "de", "değil", "en", "gibi",
            "henüz", "her", "hiç", "ile", "için", "kadar", "ki", "mi", "mu", "mü", "mı", "nasıl",
            "ne", "neden", "o", "olarak", "onlar", "sen", "siz", "sonra", "tüm", "var", "ve",
            "yok", "çok", "çünkü", "önce", "şimdi", "şu",
        ],
    },
    Evidence {
        code: "nl",
        script: Script::Latin,
        letters: "áèéëíïóöúü",
        words: &[
            "aan", "al", "alle", "als", "bij", "dat", "de", "deze", "die", "dit", "door", "een",
            "en", "er", "geen", "heb", "hebben", "heeft", "het", "hij", "hoe", "ik", "in", "is",
            "je", "jij", "kan", "kun", "kunt", "maar", "met", "moet", "naar", "niet", "niets",
            "nog", "nu", "of", "om", "ook", "op", "te", "u", "uit", "van", "voor", "waarom", "was",
            "wat", "we", "wel", "werd", "wij", "worden", "wordt", "zal", "ze", "zij", "zijn",
        ],
    },
    Evidence {
        code: "hu",
        script: Script::Latin,
        letters: "áéíóöúüőű",
        words: &[
            "a", "az", "azt", "be", "csak", "de", "egy", "el", "ez", "ezt", "fel", "ha", "hogy",
            "is", "itt", "kell", "ki", "le", "lesz", "meg", "mert", "mi", "minden", "mint", "most",
            "már", "még", "nem", "nincs", "sem", "te", "ti", "vagy", "van", "volt", "én", "és",
            "ő", "ők",
        ],
    },
    Evidence {
        code: "cs",
        script: Script::Latin,
        letters: "áéíóúýčďěňřšťůž",
        words: &[
            "a", "ale", "by", "bych", "byl", "byla", "bylo", "co", "do", "i", "jak", "je", "jen",
            "jestli", "ještě", "jsem", "jsi", "jsme", "jsou", "já", "která", "které", "který",
            "mi", "má", "mám", "mě", "na", "ne", "nic", "o", "od", "po", "pro", "protože", "při",
            "s", "se", "si", "ta", "tak", "také", "tato", "ten", "tento", "teď", "to", "ty", "už",
            "v", "ve", "všechny", "z", "za", "ze", "že",
        ],
    },
    Evidence {
        code: "ro",
        script: Script::Latin,
        letters: "âîăşţșț",
        words: &[
            "a", "aceasta", "aceea", "acest", "acum", "ai", "am", "au", "ca", "care", "ce", "cu",
            "că", "dacă", "dar", "de", "din", "după", "ea", "ei", "el", "era", "este", "eu", "iar",
            "la", "mai", "mi", "nimic", "noi", "nu", "o", "pe", "pentru", "sau", "se", "sunt",
            "să", "toate", "tot", "tu", "un", "voi", "îmi", "în", "încă", "îți", "şi", "și",
        ],
    },
    Evidence {
        code: "hr",
        script: Script::Latin,
        letters: "ćčđšž",
        words: &[
            "a", "ali", "bi", "bila", "bilo", "bio", "biti", "da", "do", "i", "ima", "imam", "ja",
            "je", "jer", "jesam", "još", "kao", "koja", "koje", "koji", "li", "me", "mi", "na",
            "ne", "nema", "nije", "nisam", "ništa", "o", "od", "ova", "ovaj", "ovo", "po", "pri",
            "s", "sa", "sada", "sam", "samo", "se", "si", "smo", "ste", "su", "sve", "svi", "ta",
            "taj", "tako", "također", "ti", "to", "treba", "u", "već", "za", "što",
        ],
    },
    Evidence {
        code: "vi",
        script: Script::Latin,
        letters: "àáâãèéêìíòóôõùúýăđĩũơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ",
        words: &[
            "ba", "bạn", "cho", "chưa", "các", "có", "cũng", "cả", "của", "gì", "hai", "khi",
            "không", "luôn", "là", "lên", "một", "mới", "nhé", "nhưng", "những", "nào", "này",
            "nếu", "ra", "rồi", "sẽ", "thì", "trong", "tôi", "từ", "và", "vì", "với", "đang", "đã",
            "đó", "được", "đều", "để",
        ],
    },
    Evidence {
        code: "id",
        script: Script::Latin,
        letters: "",
        words: &[
            "ada", "akan", "anda", "apa", "apakah", "atau", "belum", "bisa", "dalam", "dan",
            "dari", "dengan", "di", "hanya", "harus", "ini", "itu", "jika", "juga", "kami", "kamu",
            "karena", "ke", "kita", "lagi", "masih", "mereka", "oleh", "pada", "satu", "saya",
            "sebagai", "sekarang", "semua", "sudah", "tetapi", "tidak", "untuk", "yang",
        ],
    },
    Evidence {
        code: "sk",
        script: Script::Latin,
        letters: "áäéíóôúýčďĺľňŕšťž",
        words: &[
            "a", "ako", "ale", "bol", "bola", "bolo", "by", "do", "ešte", "i", "ja", "je", "ktorá",
            "ktoré", "ktorý", "len", "ma", "mi", "má", "mám", "na", "nie", "nič", "o", "od", "po",
            "pre", "pretože", "pri", "s", "sa", "si", "sme", "som", "sú", "tak", "ten", "tento",
            "teraz", "tiež", "to", "ty", "táto", "už", "v", "vo", "všetky", "z", "za", "zo", "či",
            "čo", "že",
        ],
    },
    Evidence {
        code: "ca",
        script: Script::Latin,
        letters: "àçèéíïòóúü",
        words: &[
            "a", "al", "als", "amb", "aquell", "aquella", "aquest", "aquesta", "ara", "com", "d",
            "de", "del", "dels", "el", "els", "em", "en", "encara", "era", "es", "està", "et",
            "fins", "ha", "han", "he", "hi", "i", "ja", "l", "la", "les", "li", "m", "molt", "més",
            "no", "o", "per", "perquè", "però", "quan", "que", "res", "se", "seu", "seva", "si",
            "sobre", "són", "també", "tot", "totes", "tots", "un", "una", "unes", "uns", "és",
        ],
    },
    Evidence {
        code: "ru",
        script: Script::Cyrillic,
        letters: "абвгдежзийклмнопрстуфхцчшщъыьэюяё",
        words: &[
            "а",
            "бы",
            "был",
            "была",
            "были",
            "было",
            "в",
            "во",
            "все",
            "всё",
            "вы",
            "для",
            "до",
            "его",
            "если",
            "есть",
            "еще",
            "ещё",
            "её",
            "же",
            "за",
            "и",
            "из",
            "или",
            "к",
            "как",
            "которая",
            "которые",
            "который",
            "ли",
            "меня",
            "мне",
            "мы",
            "на",
            "не",
            "нет",
            "но",
            "нужно",
            "о",
            "об",
            "он",
            "она",
            "они",
            "оно",
            "от",
            "по",
            "пока",
            "потому",
            "с",
            "со",
            "так",
            "тебя",
            "теперь",
            "только",
            "ты",
            "у",
            "уже",
            "что",
            "чтобы",
            "эта",
            "эти",
            "это",
            "этот",
            "эту",
            "я",
        ],
    },
    Evidence {
        code: "uk",
        script: Script::Cyrillic,
        letters: "абвгдежзийклмнопрстуфхцчшщьюяєіїґ",
        words: &[
            "а",
            "або",
            "але",
            "б",
            "бо",
            "був",
            "була",
            "були",
            "було",
            "в",
            "вже",
            "ви",
            "вона",
            "вони",
            "воно",
            "все",
            "всі",
            "від",
            "він",
            "для",
            "до",
            "же",
            "з",
            "за",
            "зі",
            "й",
            "його",
            "лише",
            "мене",
            "мені",
            "ми",
            "на",
            "не",
            "немає",
            "о",
            "по",
            "поки",
            "про",
            "так",
            "тебе",
            "тепер",
            "ти",
            "тому",
            "треба",
            "тільки",
            "у",
            "усі",
            "це",
            "цей",
            "цю",
            "ця",
            "ці",
            "чи",
            "ще",
            "що",
            "щоб",
            "я",
            "як",
            "яка",
            "який",
            "якщо",
            "які",
            "є",
            "і",
            "із",
            "її",
        ],
    },
    Evidence {
        code: "bg",
        script: Script::Cyrillic,
        letters: "абвгдежзийклмнопрстуфхцчшщъьюя",
        words: &[
            "а",
            "аз",
            "ако",
            "бе",
            "беше",
            "бях",
            "в",
            "вече",
            "вие",
            "всички",
            "всичко",
            "във",
            "го",
            "да",
            "до",
            "е",
            "за",
            "защото",
            "и",
            "или",
            "как",
            "които",
            "кой",
            "който",
            "коя",
            "която",
            "към",
            "ли",
            "ме",
            "ми",
            "моля",
            "на",
            "не",
            "ние",
            "но",
            "няма",
            "от",
            "още",
            "по",
            "при",
            "с",
            "са",
            "само",
            "сега",
            "си",
            "сме",
            "съм",
            "със",
            "тази",
            "така",
            "те",
            "тези",
            "ти",
            "то",
            "това",
            "този",
            "той",
            "тя",
            "че",
            "ще",
            "я",
        ],
    },
];

/// The script `scalar` is checked in, if any.
fn script_of(scalar: char) -> Option<Script> {
    match u32::from(scalar) {
        0x00C0..=0x024F | 0x1E00..=0x1EFF => Some(Script::Latin),
        0x0400..=0x052F => Some(Script::Cyrillic),
        _ => None,
    }
}

/// Whether every letter of `language`'s script in `lowered` is one it
/// writes.
fn fits(language: &Evidence, lowered: &[char]) -> bool {
    lowered
        .iter()
        .filter(|scalar| scalar.is_alphabetic() && script_of(**scalar) == Some(language.script))
        .all(|scalar| language.letters.contains(*scalar))
}

/// `text` lowercased scalar by scalar, with `İ` (U+0130) lowered to `i`.
/// Unicode lowers `İ` to `i` and a combining dot above (U+0307), which is
/// no Alphabetic scalar, so it would end the word there: every Turkish
/// sentence opening with `İlk`, `İki` or `İşlem` gave English (whose list
/// holds `i`) a word, and a clear Turkish reply came out undecided. `İ` is
/// the only scalar Unicode lowers to more than one
/// (`only_the_dotted_capital_i_lowers_to_more_than_one_scalar`), so every
/// scalar of `text` stays one scalar here.
fn lowered(text: &str) -> Vec<char> {
    text.chars()
        .flat_map(|scalar| {
            if scalar == '\u{130}' {
                'i'.to_lowercase()
            } else {
                scalar.to_lowercase()
            }
        })
        .collect()
}

/// Whether the evidence backs `code` as the language of `text`: `None`
/// when the core holds no evidence for `code` (a script other than Latin
/// or Cyrillic), else whether both checks agree with it.
pub(super) fn confirms(text: &str, code: &str) -> Option<bool> {
    let answer = TABLE.iter().position(|language| language.code == code)?;
    let lowered = lowered(text);
    let fitting = |language: &Evidence| fits(language, &lowered);
    if !TABLE.get(answer).is_some_and(fitting) {
        return Some(false);
    }
    let mut counts = [0usize; TABLE.len()];
    for word in lowered
        .split(|scalar| !scalar.is_alphabetic())
        .filter(|word| !word.is_empty())
    {
        let word: String = word.iter().collect();
        for (count, language) in counts.iter_mut().zip(&TABLE) {
            if language.words.binary_search(&word.as_str()).is_ok() {
                *count += 1;
            }
        }
    }
    let own = counts.get(answer).copied().unwrap_or(0);
    let led = TABLE
        .iter()
        .zip(counts)
        .enumerate()
        .filter(|(index, (language, _))| {
            *index != answer && (language.code == "en" || fitting(language))
        })
        .all(|(_, (_, count))| count < own);
    Some(led)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_list_is_sorted_lowercase_and_unique() {
        for language in &TABLE {
            assert!(
                language.words.windows(2).all(|pair| pair[0] < pair[1]),
                "{}",
                language.code
            );
            for word in language.words {
                assert!(
                    !word.is_empty() && word.chars().all(char::is_alphabetic),
                    "{word:?}"
                );
                assert_eq!(word.to_lowercase(), *word);
            }
            for letter in language.letters.chars() {
                assert_eq!(script_of(letter), Some(language.script), "{letter:?}");
                assert!(
                    letter.is_alphabetic() && letter.is_lowercase(),
                    "{letter:?}"
                );
            }
        }
    }

    #[test]
    fn a_language_without_evidence_is_not_checked() {
        assert_eq!(confirms("مرحبا بالعالم", "ar"), None);
        assert_eq!(confirms("", "zh"), None);
    }

    #[test]
    fn english_function_words_veto_a_romance_answer() {
        // whatlang: French at 0.93; NLLanguageRecognizer: English.
        let text =
            "Same connection, de-dup and drop paths as a real pad (a drop releases held buttons).";
        assert_eq!(confirms(text, "fr"), Some(false));
        assert_eq!(confirms(text, "en"), Some(true));
        // "plus" is an English word too.
        assert_eq!(
            confirms(
                "newline-split stdout lines (order-preserving) plus a bounded stderr tail",
                "fr"
            ),
            Some(false)
        );
    }

    #[test]
    fn a_letter_outside_the_alphabet_vetoes_the_answer() {
        // whatlang: Portuguese; ř is no Portuguese letter.
        let czech = "Aktualizoval jsem dokumentaci a přidal do projektu dva nové testy.";
        assert_eq!(confirms(czech, "pt"), Some(false));
        assert_eq!(confirms(czech, "cs"), Some(true));
        // Belarusian: ў and і are no Russian letters.
        let belarusian = "Я абнавіў дакументацыю і дадаў два новыя тэсты ў гэты праект сёння.";
        assert_eq!(confirms(belarusian, "ru"), Some(false));
        // A word in another script is not looked at.
        assert_eq!(
            confirms(
                "Я исправил ошибку в функции parseJSON, и теперь все тесты проходят.",
                "ru"
            ),
            Some(true)
        );
    }

    #[test]
    fn a_tie_or_no_function_word_is_no_evidence() {
        // Danish and Norwegian share every function word here.
        assert_eq!(
            confirms(
                "Jeg ændrede tre filer og skrev to nye test til tomt input.",
                "da"
            ),
            Some(false)
        );
        // Swahili: whatlang says Indonesian, and no Indonesian word is there.
        assert_eq!(
            confirms(
                "Ndimesasisha nyaraka na kuongeza majaribio mawili mapya kwenye mradi.",
                "id"
            ),
            Some(false)
        );
    }

    #[test]
    fn a_rival_the_letters_rule_out_does_not_count() {
        // ř rules out Slovak, Croatian and Polish, whose lists share "s" and
        // "do" with Czech; English still counts, and holds only "s".
        assert_eq!(
            confirms(
                "Přidal jsem opakování s exponenciálním čekáním do síťového klienta.",
                "cs"
            ),
            Some(true)
        );
        // English counts whatever the letters: an English sentence quoting
        // a French dish is no French (whatlang: French at 0.72;
        // NLLanguageRecognizer: English). French holds two words here ("a",
        // "la"), and the letters rule out every other language that holds
        // any (û is French's alone), so without English as a rival French
        // would lead. English holds five ("the", "a", "are", "as", "one"),
        // so French is vetoed. English itself writes no è, so its own
        // answer is undecided, which reads as English all the same.
        let quoting = "Fixed the crème brûlée example: a la carte entries are parsed as one.";
        assert_eq!(confirms(quoting, "fr"), Some(false));
        assert_eq!(confirms(quoting, "en"), Some(false));
        assert_eq!(
            confirms(
                "Use a résumé or CV, de facto the same, as a real input.",
                "pt"
            ),
            Some(false)
        );
    }

    #[test]
    fn a_capital_dotted_i_is_one_letter_of_its_word() {
        // Unicode lowers İ to i and U+0307; split there, each İ gave English
        // an "i", which tied or beat Turkish's own words.
        assert_eq!(lowered("İşlem"), ['i', 'ş', 'l', 'e', 'm']);
        for turkish in [
            "İşlem tamamlandı, yeni sürüm yayınlandı ve belgeler güncellendi.",
            "İlk olarak yapılandırmayı güncelledim. İkinci adımda testleri çalıştırdım.",
            "İki dosyayı değiştirdim. İlgili testleri ekledim. İnceleme için hazır.",
        ] {
            assert_eq!(confirms(turkish, "tr"), Some(true), "{turkish:?}");
        }
    }

    #[test]
    fn only_the_dotted_capital_i_lowers_to_more_than_one_scalar() {
        let expanding: Vec<char> = (0..=u32::from(char::MAX))
            .filter_map(char::from_u32)
            .filter(|scalar| scalar.to_lowercase().count() > 1)
            .collect();
        assert_eq!(expanding, ['\u{130}']);
    }
}
