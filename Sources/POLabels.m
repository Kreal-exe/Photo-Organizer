#import "POLabels.h"
#import "POStrings.h"

// Vision's classifier returns English identifiers. This maps the common ones to Russian: the first alias is
// the display name, the rest are extra word forms the search should accept. Labels that are missing here are
// still searchable by their English name.
static NSString *const POLabelAliases =
    @"people=люди человек|adult=взрослый взрослые|child=ребёнок дети ребенок|baby=младенец малыш|teen=подросток|crowd=толпа|"
    @"bride=невеста|groom=жених|wedding=свадьба|wedding_dress=свадебное платье|wedding_cake=свадебный торт|celebration=праздник|"
    @"ceremony=церемония|graduation=выпускной|birthday_cake=торт день рождения|concert=концерт|performance=выступление|"
    @"dancing=танцы танец|parade=парад|fireworks=фейерверк салют|christmas_tree=ёлка елка новогодняя|christmas_decoration=новогодние украшения|"
    @"santa_claus=дед мороз санта|gift=подарок подарки|balloon=шарик шарики|"
    @"outdoor=улица на улице|interior_room=помещение комната интерьер|daytime=день|night_sky=ночное небо ночь|sky=небо|blue_sky=голубое небо|"
    @"cloudy=облака облачно тучи|sunset_sunrise=закат рассвет|sun=солнце|moon=луна|rainbow=радуга|storm=буря шторм|lightning=молния|"
    @"snow=снег|ice=лёд лед|blizzard=метель|haze=туман дымка|fire=огонь|aurora=северное сияние|"
    @"beach=пляж|ocean=океан море|shore=берег побережье|water=вода|water_body=водоём водоем|lake=озеро|river=река|creek=ручей|waterfall=водопад|"
    @"pool=бассейн|underwater=под водой|island=остров|sand=песок|sand_dune=дюна|desert=пустыня|mountain=гора горы|hill=холм холмы|"
    @"cliff=скала утёс|canyon=каньон|cave=пещера|volcano=вулкан|glacier=ледник|rocks=камни скалы|forest=лес|jungle=джунгли|tree=дерево деревья|"
    @"palm_tree=пальма пальмы|evergreen=хвойные|grass=трава|foliage=листва листья|plant=растение растения|flower=цветок цветы|"
    @"bouquet=букет|rose=роза розы|tulip=тюльпан тюльпаны|sunflower=подсолнух|blossom=цветение|garden=сад|park=парк|land=земля пейзаж|"
    @"vegetation=растительность|farm=ферма|agriculture=поле сельское хозяйство|vineyard=виноградник|trail=тропа|path=дорожка|"
    @"cityscape=город городской пейзаж|building=здание здания|skyscraper=небоскрёб небоскреб|house_single=дом|apartment=квартира многоэтажка|"
    @"street=улица|road=дорога|alley=переулок|sidewalk=тротуар|bridge=мост|tower=башня|castle=замок|monument=памятник|statue=статуя|"
    @"fountain=фонтан|ruins=руины|structure=сооружение|storefront=витрина магазин|restaurant=ресторан кафе|bar=бар|museum=музей|"
    @"stadium=стадион|playground=детская площадка|harbour=гавань порт|pier=пирс причал|lighthouse=маяк|parking_lot=парковка|"
    @"airport=аэропорт|train_station=вокзал|railroad=железная дорога|tunnel=туннель|stairs=лестница|door=дверь|window=окно|fence=забор|"
    @"roof=крыша|balcony=балкон|"
    @"kitchen=кухня|bedroom=спальня|bathroom=ванная|living_room=гостиная|dining_room=столовая|furniture=мебель|table=стол|chair=стул|"
    @"sofa=диван|bed=кровать|desk=рабочий стол|bookshelf=книжная полка|lamp=лампа|curtain=шторы|fireplace=камин|"
    @"animal=животное животные|mammal=млекопитающее|dog=собака собаки пёс пес|canine=собака псовые|cat=кошка кот коты кошки|kitten=котёнок котенок|"
    @"feline=кошачьи|bird=птица птицы|horse=лошадь лошади конь|cow=корова|sheep=овца|goat=коза|pig=свинья|rabbit=кролик|deer=олень|bear=медведь|"
    @"fox=лиса|squirrel=белка|elephant=слон|giraffe=жираф|lion=лев|tiger=тигр|zebra=зебра|fish=рыба рыбы|dolphin=дельфин|whale=кит|shark=акула|"
    @"turtle=черепаха|snake=змея|lizard=ящерица|frog=лягушка|insect=насекомое|butterfly=бабочка|bee=пчела|spider=паук|duck=утка|swan=лебедь|"
    @"gull=чайка|pigeon=голубь|parrot=попугай|owl=сова|eagle=орёл орел|penguin=пингвин|zoo=зоопарк|aquarium=аквариум|"
    @"vehicle=транспорт|automobile=автомобиль|car=машина машины автомобиль|suv=внедорожник|truck=грузовик|bus=автобус|van=фургон|"
    @"motorcycle=мотоцикл|bicycle=велосипед|cycling=велоспорт велосипед|scooter=самокат скутер|train=поезд|streetcar=трамвай|aircraft=самолёт|"
    @"airplane=самолёт самолет|helicopter=вертолёт вертолет|boat=лодка|sailboat=парусник яхта|yacht=яхта|cruise_ship=лайнер корабль|"
    @"watercraft=судно корабль|"
    @"food=еда|drink=напиток напитки|fruit=фрукт фрукты|vegetable=овощ овощи|dessert=десерт|cake=торт|ice_cream=мороженое|pizza=пицца|"
    @"hamburger=бургер|sandwich=бутерброд сэндвич|salad=салат|soup=суп|pasta=паста макароны|sushi=суши|meat=мясо|seafood=морепродукты|"
    @"bread=хлеб|cheese=сыр|egg=яйцо|coffee=кофе|tea_drink=чай|wine=вино|beer=пиво|cocktail=коктейль|juice=сок|tableware=посуда|plate=тарелка|"
    @"cup=чашка|drinking_glass=стакан бокал|bottle=бутылка|"
    @"sport=спорт|soccer=футбол|basketball=баскетбол|tennis=теннис|volleyball=волейбол|hockey=хоккей|swimming=плавание|skiing=лыжи|"
    @"snowboarding=сноуборд|skating=катание на коньках|surfing=сёрфинг серфинг|hiking=поход|camping=кемпинг палатка|fishing=рыбалка|"
    @"golf=гольф|yoga=йога|workout=тренировка|martial_arts=единоборства|rock_climbing=скалолазание|tent=палатка|"
    @"clothing=одежда|swimsuit=купальник|sunglasses=солнечные очки|eyeglasses=очки|hat=шляпа шапка|jacket=куртка|suit=костюм|gown=платье|"
    @"shoes=обувь|jewelry=украшения|bag=сумка|backpack=рюкзак|umbrella=зонт|"
    @"document=документ документы|printed_page=страница текст|handwriting=рукописный текст|screenshot=скриншот снимок экрана|receipt=чек|"
    @"map=карта|chart=график|diagram=схема|book=книга|newspaper=газета|whiteboard=доска|sign=вывеска знак|street_sign=дорожный знак|"
    @"art=искусство|painting=картина живопись|illustrations=рисунок иллюстрация|graffiti=граффити|"
    @"computer=компьютер|laptop=ноутбук|phone=телефон|television=телевизор|camera=камера фотоаппарат|consumer_electronics=электроника|"
    @"musical_instrument=музыкальный инструмент|guitar=гитара|piano=пианино|toy=игрушка игрушки|stuffed_animals=мягкая игрушка|"
    @"candle=свеча|flag=флаг|money=деньги|tool=инструмент|sunbathing=загар|tattoo=татуировка";

static NSDictionary<NSString *, NSArray<NSString *> *> *POAliasTable(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (NSString *entry in [POLabelAliases componentsSeparatedByString:@"|"]) {
            NSArray<NSString *> *parts = [entry componentsSeparatedByString:@"="];
            if (parts.count == 2) result[parts[0]] = parts[1];
        }
        table = result;
    });
    return table;
}

static NSString *PONormalize(NSString *text) {
    return [text.lowercaseString stringByReplacingOccurrencesOfString:@"ё" withString:@"е"];
}

NSString *POLabelDisplayName(NSString *identifier) {
    // The classifier's own names are English; only the Russian interface needs the table.
    NSString *aliases = POIsRussian() ? (NSString *)POAliasTable()[identifier] : nil;
    if (!aliases) return [identifier stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Multi-word display names; every other label is shown by its first alias word.
        names = @{@"wedding_dress": @"свадебное платье", @"wedding_cake": @"свадебный торт", @"birthday_cake": @"торт",
                  @"christmas_tree": @"ёлка", @"christmas_decoration": @"новогодние украшения", @"santa_claus": @"Дед Мороз",
                  @"outdoor": @"на улице", @"night_sky": @"ночное небо", @"blue_sky": @"голубое небо", @"underwater": @"под водой",
                  @"playground": @"детская площадка", @"train_station": @"вокзал", @"desk": @"рабочий стол",
                  @"bookshelf": @"книжная полка", @"sunglasses": @"солнечные очки", @"street_sign": @"дорожный знак",
                  @"musical_instrument": @"музыкальный инструмент", @"stuffed_animals": @"мягкая игрушка",
                  @"printed_page": @"страница с текстом", @"handwriting": @"рукописный текст", @"aurora": @"северное сияние",
                  @"railroad": @"железная дорога", @"cityscape": @"город", @"skating": @"коньки"};
    });
    return names[identifier] ?: [aliases componentsSeparatedByString:@" "].firstObject;
}

/// Every word the label can be found by: its Russian aliases and the parts of its English identifier.
static NSArray<NSString *> *POWordsForLabel(NSString *identifier) {
    static NSMutableDictionary<NSString *, NSArray<NSString *> *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        NSArray<NSString *> *words = cache[identifier];
        if (!words) {
            NSMutableArray<NSString *> *all = [[identifier.lowercaseString componentsSeparatedByString:@"_"] mutableCopy];
            NSString *aliases = (NSString *)POAliasTable()[identifier];
            if (aliases) [all addObjectsFromArray:[PONormalize(aliases) componentsSeparatedByString:@" "]];
            cache[identifier] = words = all;
        }
        return words;
    }
}

NSArray<NSString *> *POSearchTokens(NSString *query) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *word in [PONormalize(query) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (word.length) [tokens addObject:word];
    }
    return tokens;
}

BOOL POItemMatchesTokens(POPhotoItem *item, NSArray<NSString *> *tokens) {
    NSDictionary<NSString *, NSNumber *> *labels = item.labels;
    NSString *path = nil;
    for (NSString *token in tokens) {
        BOOL found = NO;
        for (NSString *label in labels) {
            for (NSString *word in POWordsForLabel(label)) {
                if ([word hasPrefix:token]) { found = YES; break; }
            }
            if (found) break;
        }
        if (!found) {
            if (!path) path = PONormalize(item.relativePath).precomposedStringWithCanonicalMapping;
            found = [path containsString:token];
        }
        if (!found) return NO;
    }
    return YES;
}
