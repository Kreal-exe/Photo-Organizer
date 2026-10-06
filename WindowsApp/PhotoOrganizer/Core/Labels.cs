using System.Reflection;
using System.Text;

namespace PhotoOrganizer.Core;

/// <summary>
/// What is in a picture, in words: the labels of the macOS app (Vision's identifiers with Russian names), here found by
/// comparing the picture's MobileCLIP vector with the vector of each label (Resources/clip-labels.bin, made by
/// Tools/make_clip_labels.py), and searched for the way the macOS app searches them.
/// </summary>
public static class Labels
{
    // The first alias is the display name, the rest are extra word forms the search should accept (Sources/POLabels.m).
    const string AliasTable =
        "people=люди человек|adult=взрослый взрослые|child=ребёнок дети ребенок|baby=младенец малыш|teen=подросток|" +
        "crowd=толпа|bride=невеста|groom=жених|wedding=свадьба|wedding_dress=свадебное платье|" +
        "wedding_cake=свадебный торт|celebration=праздник|ceremony=церемония|graduation=выпускной|" +
        "birthday_cake=торт день рождения|concert=концерт|performance=выступление|dancing=танцы танец|parade=парад|" +
        "fireworks=фейерверк салют|christmas_tree=ёлка елка новогодняя|christmas_decoration=новогодние украшения|" +
        "santa_claus=дед мороз санта|gift=подарок подарки|balloon=шарик шарики|outdoor=улица на улице|" +
        "interior_room=помещение комната интерьер|daytime=день|night_sky=ночное небо ночь|sky=небо|" +
        "blue_sky=голубое небо|cloudy=облака облачно тучи|sunset_sunrise=закат рассвет|sun=солнце|moon=луна|" +
        "rainbow=радуга|storm=буря шторм|lightning=молния|snow=снег|ice=лёд лед|blizzard=метель|haze=туман дымка|" +
        "fire=огонь|aurora=северное сияние|beach=пляж|ocean=океан море|shore=берег побережье|water=вода|" +
        "water_body=водоём водоем|lake=озеро|river=река|creek=ручей|waterfall=водопад|pool=бассейн|" +
        "underwater=под водой|island=остров|sand=песок|sand_dune=дюна|desert=пустыня|mountain=гора горы|" +
        "hill=холм холмы|cliff=скала утёс|canyon=каньон|cave=пещера|volcano=вулкан|glacier=ледник|rocks=камни скалы|" +
        "forest=лес|jungle=джунгли|tree=дерево деревья|palm_tree=пальма пальмы|evergreen=хвойные|grass=трава|" +
        "foliage=листва листья|plant=растение растения|flower=цветок цветы|bouquet=букет|rose=роза розы|" +
        "tulip=тюльпан тюльпаны|sunflower=подсолнух|blossom=цветение|garden=сад|park=парк|land=земля пейзаж|" +
        "vegetation=растительность|farm=ферма|agriculture=поле сельское хозяйство|vineyard=виноградник|trail=тропа|" +
        "path=дорожка|cityscape=город городской пейзаж|building=здание здания|skyscraper=небоскрёб небоскреб|" +
        "house_single=дом|apartment=квартира многоэтажка|street=улица|road=дорога|alley=переулок|sidewalk=тротуар|" +
        "bridge=мост|tower=башня|castle=замок|monument=памятник|statue=статуя|fountain=фонтан|ruins=руины|" +
        "structure=сооружение|storefront=витрина магазин|restaurant=ресторан кафе|bar=бар|museum=музей|stadium=стадион|" +
        "playground=детская площадка|harbour=гавань порт|pier=пирс причал|lighthouse=маяк|parking_lot=парковка|" +
        "airport=аэропорт|train_station=вокзал|railroad=железная дорога|tunnel=туннель|stairs=лестница|door=дверь|" +
        "window=окно|fence=забор|roof=крыша|balcony=балкон|kitchen=кухня|bedroom=спальня|bathroom=ванная|" +
        "living_room=гостиная|dining_room=столовая|furniture=мебель|table=стол|chair=стул|sofa=диван|bed=кровать|" +
        "desk=рабочий стол|bookshelf=книжная полка|lamp=лампа|curtain=шторы|fireplace=камин|animal=животное животные|" +
        "mammal=млекопитающее|dog=собака собаки пёс пес|canine=собака псовые|cat=кошка кот коты кошки|" +
        "kitten=котёнок котенок|feline=кошачьи|bird=птица птицы|horse=лошадь лошади конь|cow=корова|sheep=овца|" +
        "goat=коза|pig=свинья|rabbit=кролик|deer=олень|bear=медведь|fox=лиса|squirrel=белка|elephant=слон|" +
        "giraffe=жираф|lion=лев|tiger=тигр|zebra=зебра|fish=рыба рыбы|dolphin=дельфин|whale=кит|shark=акула|" +
        "turtle=черепаха|snake=змея|lizard=ящерица|frog=лягушка|insect=насекомое|butterfly=бабочка|bee=пчела|" +
        "spider=паук|duck=утка|swan=лебедь|gull=чайка|pigeon=голубь|parrot=попугай|owl=сова|eagle=орёл орел|" +
        "penguin=пингвин|zoo=зоопарк|aquarium=аквариум|vehicle=транспорт|automobile=автомобиль|" +
        "car=машина машины автомобиль|suv=внедорожник|truck=грузовик|bus=автобус|van=фургон|motorcycle=мотоцикл|" +
        "bicycle=велосипед|cycling=велоспорт велосипед|scooter=самокат скутер|train=поезд|streetcar=трамвай|" +
        "aircraft=самолёт|airplane=самолёт самолет|helicopter=вертолёт вертолет|boat=лодка|sailboat=парусник яхта|" +
        "yacht=яхта|cruise_ship=лайнер корабль|watercraft=судно корабль|food=еда|drink=напиток напитки|" +
        "fruit=фрукт фрукты|vegetable=овощ овощи|dessert=десерт|cake=торт|ice_cream=мороженое|pizza=пицца|" +
        "hamburger=бургер|sandwich=бутерброд сэндвич|salad=салат|soup=суп|pasta=паста макароны|sushi=суши|meat=мясо|" +
        "seafood=морепродукты|bread=хлеб|cheese=сыр|egg=яйцо|coffee=кофе|tea_drink=чай|wine=вино|beer=пиво|" +
        "cocktail=коктейль|juice=сок|tableware=посуда|plate=тарелка|cup=чашка|drinking_glass=стакан бокал|" +
        "bottle=бутылка|sport=спорт|soccer=футбол|basketball=баскетбол|tennis=теннис|volleyball=волейбол|hockey=хоккей|" +
        "swimming=плавание|skiing=лыжи|snowboarding=сноуборд|skating=катание на коньках|surfing=сёрфинг серфинг|" +
        "hiking=поход|camping=кемпинг палатка|fishing=рыбалка|golf=гольф|yoga=йога|workout=тренировка|" +
        "martial_arts=единоборства|rock_climbing=скалолазание|tent=палатка|clothing=одежда|swimsuit=купальник|" +
        "sunglasses=солнечные очки|eyeglasses=очки|hat=шляпа шапка|jacket=куртка|suit=костюм|gown=платье|shoes=обувь|" +
        "jewelry=украшения|bag=сумка|backpack=рюкзак|umbrella=зонт|document=документ документы|" +
        "printed_page=страница текст|handwriting=рукописный текст|screenshot=скриншот снимок экрана|receipt=чек|" +
        "map=карта|chart=график|diagram=схема|book=книга|newspaper=газета|whiteboard=доска|sign=вывеска знак|" +
        "street_sign=дорожный знак|art=искусство|painting=картина живопись|illustrations=рисунок иллюстрация|" +
        "graffiti=граффити|computer=компьютер|laptop=ноутбук|phone=телефон|television=телевизор|" +
        "camera=камера фотоаппарат|consumer_electronics=электроника|musical_instrument=музыкальный инструмент|" +
        "guitar=гитара|piano=пианино|toy=игрушка игрушки|stuffed_animals=мягкая игрушка|candle=свеча|flag=флаг|" +
        "money=деньги|tool=инструмент|sunbathing=загар|tattoo=татуировка";

    // Multi-word display names; every other label is shown by its first alias word.
    static readonly Dictionary<string, string> DisplayNames = new()
    {
        ["wedding_dress"] = "свадебное платье",
        ["wedding_cake"] = "свадебный торт",
        ["birthday_cake"] = "торт",
        ["christmas_tree"] = "ёлка",
        ["christmas_decoration"] = "новогодние украшения",
        ["santa_claus"] = "Дед Мороз",
        ["outdoor"] = "на улице",
        ["night_sky"] = "ночное небо",
        ["blue_sky"] = "голубое небо",
        ["underwater"] = "под водой",
        ["playground"] = "детская площадка",
        ["train_station"] = "вокзал",
        ["desk"] = "рабочий стол",
        ["bookshelf"] = "книжная полка",
        ["sunglasses"] = "солнечные очки",
        ["street_sign"] = "дорожный знак",
        ["musical_instrument"] = "музыкальный инструмент",
        ["stuffed_animals"] = "мягкая игрушка",
        ["printed_page"] = "страница с текстом",
        ["handwriting"] = "рукописный текст",
        ["aurora"] = "северное сияние",
        ["railroad"] = "железная дорога",
        ["cityscape"] = "город",
        ["skating"] = "коньки",
    };

    /// <summary>
    /// Vision tags a dog as "dog", "canine", "mammal" and "animal" at once; CLIP picks the one that fits best. The parents
    /// are added so that "животное" finds the dog, as on the Mac.
    /// </summary>
    static readonly Dictionary<string, string[]> Parents = BuildParents(
        ("animal mammal", "dog cat kitten horse cow sheep goat pig rabbit deer bear fox squirrel elephant giraffe lion tiger zebra dolphin whale"),
        ("canine", "dog"), ("feline", "cat kitten lion tiger"),
        ("animal bird", "duck swan gull pigeon parrot owl eagle penguin"),
        ("animal", "bird fish shark turtle snake lizard frog insect butterfly bee spider mammal"), ("insect", "butterfly bee"), ("fish", "shark"),
        ("vehicle", "automobile car suv truck bus van motorcycle bicycle scooter train streetcar aircraft airplane helicopter boat sailboat yacht cruise_ship watercraft"),
        ("automobile", "car suv"), ("aircraft", "airplane helicopter"), ("watercraft", "boat sailboat yacht cruise_ship"),
        ("food", "fruit vegetable dessert cake ice_cream pizza hamburger sandwich salad soup pasta sushi meat seafood bread cheese egg birthday_cake wedding_cake"),
        ("dessert", "cake ice_cream birthday_cake wedding_cake"), ("drink", "coffee tea_drink wine beer cocktail juice"),
        ("people", "adult child baby teen crowd bride groom"), ("child", "baby"),
        ("sport", "soccer basketball tennis volleyball hockey swimming skiing snowboarding skating surfing golf yoga workout martial_arts rock_climbing cycling"),
        ("flower plant", "rose tulip sunflower bouquet blossom"), ("plant", "tree palm_tree evergreen grass foliage flower"), ("tree", "palm_tree evergreen"),
        ("water", "beach ocean lake river waterfall pool creek water_body underwater"),
        ("outdoor", "mountain hill cliff canyon desert forest jungle beach island field park garden street road cityscape land sky"),
        ("building structure", "skyscraper house_single apartment castle tower museum stadium"),
        ("interior_room", "kitchen bedroom bathroom living_room dining_room"), ("furniture", "table chair sofa bed desk bookshelf"),
        ("musical_instrument", "guitar piano"), ("consumer_electronics", "laptop computer phone television camera"),
        ("art", "painting graffiti illustrations statue"), ("clothing", "swimsuit jacket suit gown hat shoes wedding_dress"),
        ("sky", "sunset_sunrise blue_sky cloudy night_sky"), ("document", "printed_page handwriting receipt screenshot"),
        ("celebration", "wedding birthday_cake fireworks christmas_tree"), ("wedding", "bride groom wedding_dress wedding_cake"));

    static Dictionary<string, string[]> BuildParents(params (string Parents, string Children)[] rules)
    {
        var table = new Dictionary<string, HashSet<string>>();
        foreach (var (parents, children) in rules)
        {
            foreach (string child in children.Split(' '))
            {
                if (!table.TryGetValue(child, out var set)) table[child] = set = [];
                foreach (string parent in parents.Split(' ')) if (parent != child) set.Add(parent);
            }
        }
        return table.ToDictionary(p => p.Key, p => p.Value.ToArray());
    }

    /// <summary>Labels only the Windows version has (see Tools/make_clip_labels.py).</summary>
    const string WindowsAliasTable = "abstract=абстракция абстрактный|colorful=разноцветный яркий|pattern=узор орнамент|texture=текстура фактура";

    static Dictionary<string, string>? _aliases;
    static Dictionary<string, string> Aliases => _aliases ??= (AliasTable + "|" + WindowsAliasTable).Split('|').Select(e => e.Split('='))
        .Where(p => p.Length == 2).ToDictionary(p => p[0], p => p[1]);

    static string Normalize(string text) => text.ToLowerInvariant().Replace('ё', 'е');

    /// <summary>The Russian name of a label ("beach" → "пляж"); the identifier itself in English.</summary>
    public static string DisplayName(string identifier)
    {
        if (!Strings.IsRussian || !Aliases.TryGetValue(identifier, out var aliases)) return identifier.Replace('_', ' ');
        return DisplayNames.GetValueOrDefault(identifier) ?? aliases.Split(' ')[0];
    }

    static readonly Dictionary<string, string[]> WordsCache = [];

    /// <summary>Every word the label can be found by: its Russian aliases and the parts of its English identifier.</summary>
    static string[] WordsFor(string identifier)
    {
        lock (WordsCache)
        {
            if (!WordsCache.TryGetValue(identifier, out var words))
            {
                var all = identifier.ToLowerInvariant().Split('_').ToList();
                if (Aliases.TryGetValue(identifier, out var aliases)) all.AddRange(Normalize(aliases).Split(' '));
                WordsCache[identifier] = words = all.ToArray();
            }
            return words;
        }
    }

    /// <summary>Lower-cased words of a search query.</summary>
    public static string[] SearchTokens(string query) =>
        Normalize(query).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    /// <summary>True when every token begins a word of one of the item's labels (Russian or English) or occurs in its path.</summary>
    public static bool Matches(PhotoItem item, string[] tokens)
    {
        var labels = item.Labels;
        string? path = null;
        foreach (string token in tokens)
        {
            bool found = labels != null && labels.Keys.Any(label => WordsFor(label).Any(word => word.StartsWith(token, StringComparison.Ordinal)));
            if (!found)
            {
                path ??= Normalize(item.RelativePath).Normalize(NormalizationForm.FormC);
                found = path.Contains(token, StringComparison.Ordinal);
            }
            if (!found) return false;
        }
        return true;
    }

    // --- Tagging --------------------------------------------------------------------------------------------------

    static (string[] Names, float[] Vectors, int Dimension)? _vectors;

    static (string[] Names, float[] Vectors, int Dimension) Vectors
    {
        get
        {
            if (_vectors is { } loaded) return loaded;
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("clip-labels.bin")
                               ?? throw new InvalidOperationException("clip-labels.bin is not embedded");
            using var reader = new BinaryReader(stream);
            if (Encoding.ASCII.GetString(reader.ReadBytes(4)) != "POCL") throw new InvalidDataException("clip-labels.bin");
            int count = reader.ReadInt32(), dimension = reader.ReadInt32();
            var names = new string[count];
            for (int i = 0; i < count; i++) names[i] = Encoding.UTF8.GetString(reader.ReadBytes(reader.ReadUInt16()));
            var vectors = new float[count * dimension];
            for (int i = 0; i < vectors.Length; i++) vectors[i] = reader.ReadSingle();
            _vectors = (names, vectors, dimension);
            return _vectors.Value;
        }
    }

    /// <summary>Below this a label is noise: CLIP's similarity of a picture with a text that has nothing to do with it.</summary>
    const float MinimumSimilarity = 0.16f;
    /// <summary>A label stays when it takes at least this share of the softmax over all labels.</summary>
    const float MinimumShare = 0.2f;
    const int MaximumLabels = 5;

    /// <summary>
    /// The labels of a picture (identifier → confidence 0…1) from its unit-length MobileCLIP vector: the labels that
    /// stand out among all of them, then their parents.
    /// </summary>
    public static Dictionary<string, float> For(ReadOnlySpan<float> embedding)
    {
        var (names, vectors, dimension) = Vectors;
        var similarity = new float[names.Length];
        for (int i = 0; i < names.Length; i++)
        {
            similarity[i] = System.Numerics.Tensors.TensorPrimitives.Dot(vectors.AsSpan(i * dimension, dimension), embedding);
        }
        // CLIP's own temperature (logit scale 100) turns similarities into how much each label stands out.
        float max = similarity.Max();
        var shares = similarity.Select(s => MathF.Exp(100 * (s - max))).ToArray();
        float sum = shares.Sum();
        var result = new Dictionary<string, float>();
        foreach (int i in Enumerable.Range(0, names.Length).OrderByDescending(i => similarity[i]).Take(MaximumLabels))
        {
            float share = shares[i] / sum;
            if (similarity[i] < MinimumSimilarity || share < MinimumShare) continue;
            float confidence = MathF.Round(Math.Clamp(share, 0.3f, 1f), 2);
            result[names[i]] = Math.Max(result.GetValueOrDefault(names[i]), confidence);
            foreach (string parent in Parents.GetValueOrDefault(names[i]) ?? [])
            {
                result[parent] = Math.Max(result.GetValueOrDefault(parent), confidence);
                foreach (string grandparent in Parents.GetValueOrDefault(parent) ?? []) result[grandparent] = Math.Max(result.GetValueOrDefault(grandparent), confidence);
            }
        }
        return result;
    }
}
