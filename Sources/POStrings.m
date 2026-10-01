#import "POStrings.h"

NSString *POL(NSString *russian) {
    return [NSBundle.mainBundle localizedStringForKey:russian value:russian table:nil];
}

BOOL POIsRussian(void) {
    static BOOL russian;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Without a bundle (the command-line tests) the sources' own language applies.
        NSString *language = NSBundle.mainBundle.bundleIdentifier ? NSBundle.mainBundle.preferredLocalizations.firstObject : @"ru";
        russian = [language hasPrefix:@"ru"];
    });
    return russian;
}

NSLocale *POLocale(void) {
    return [NSLocale localeWithLocaleIdentifier:POIsRussian() ? @"ru_RU" : @"en_US"];
}

NSString *POPlural(NSInteger n, NSString *one, NSString *few, NSString *many) {
    if (!POIsRussian()) return n == 1 ? one : many;
    NSInteger mod10 = n % 10, mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return one;
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
    return many;
}

NSString *PONumber(NSInteger n) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSNumberFormatter new];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.locale = POLocale();
    });
    return [formatter stringFromNumber:@(n)] ?: [NSString stringWithFormat:@"%ld", (long)n];
}

NSString *POCount(NSInteger n, NSString *one, NSString *few, NSString *many) {
    return [NSString stringWithFormat:@"%@ %@", PONumber(n), POPlural(n, one, few, many)];
}
