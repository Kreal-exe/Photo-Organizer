#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The interface text is written in Russian in the sources; this returns its translation into the language the
/// app is running in (see Resources/en.lproj/Localizable.strings), or the text itself for Russian.
FOUNDATION_EXPORT NSString *POL(NSString *russian);

/// YES when the app's interface is in Russian.
FOUNDATION_EXPORT BOOL POIsRussian(void);

/// The locale that matches the interface language, for dates and numbers.
FOUNDATION_EXPORT NSLocale *POLocale(void);

/// Picks the plural form for `n` (1 файл / 2 файла / 5 файлов); in English, `one` for 1 and `many` otherwise.
/// Pass each form through POL().
FOUNDATION_EXPORT NSString *POPlural(NSInteger n, NSString *one, NSString *few, NSString *many);

/// `n` with thousands separators.
FOUNDATION_EXPORT NSString *PONumber(NSInteger n);

/// "1 234 файла" — formatted number followed by the matching plural form.
FOUNDATION_EXPORT NSString *POCount(NSInteger n, NSString *one, NSString *few, NSString *many);

NS_ASSUME_NONNULL_END
