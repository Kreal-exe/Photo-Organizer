#import "POSettings.h"

NSNotificationName const POSettingsDidChangeNotification = @"POSettingsDidChangeNotification";

static NSString *const POKeyObjects = @"analyzesObjects";
static NSString *const POKeyNudity = @"detectsNudity";
static NSString *const POKeyFaces = @"groupsFaces";
static NSString *const POKeyNudityModel = @"nudityModel";
static NSString *const POKeyNudityThreshold = @"nudityThreshold";

@implementation POSettings

+ (void)initialize {
    if (self != POSettings.class) return;
    [NSUserDefaults.standardUserDefaults registerDefaults:@{POKeyObjects: @YES, POKeyNudity: @NO, POKeyNudityThreshold: @0.5}];
}

+ (void)didChange {
    [NSNotificationCenter.defaultCenter postNotificationName:POSettingsDidChangeNotification object:nil];
}

+ (BOOL)analyzesObjects { return [NSUserDefaults.standardUserDefaults boolForKey:POKeyObjects]; }
+ (void)setAnalyzesObjects:(BOOL)value {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:POKeyObjects];
    [self didChange];
}

+ (BOOL)detectsNudity { return [NSUserDefaults.standardUserDefaults boolForKey:POKeyNudity]; }
+ (void)setDetectsNudity:(BOOL)value {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:POKeyNudity];
    [self didChange];
}

+ (BOOL)groupsFaces { return [NSUserDefaults.standardUserDefaults boolForKey:POKeyFaces]; }
+ (void)setGroupsFaces:(BOOL)value {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:POKeyFaces];
    [self didChange];
}

+ (NSString *)nudityModelIdentifier { return [NSUserDefaults.standardUserDefaults stringForKey:POKeyNudityModel]; }
+ (void)setNudityModelIdentifier:(NSString *)value {
    [NSUserDefaults.standardUserDefaults setObject:value forKey:POKeyNudityModel];
    [self didChange];
}

+ (NSString *)language {
    // AppleLanguages in the app's own domain is how macOS itself stores a per-app language.
    NSArray *languages = [[NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier ?: @""] objectForKey:@"AppleLanguages"];
    NSString *first = [languages isKindOfClass:NSArray.class] ? languages.firstObject : nil;
    return [first hasPrefix:@"ru"] ? @"ru" : ([first hasPrefix:@"en"] ? @"en" : nil);
}
+ (void)setLanguage:(NSString *)language {
    if (language) {
        [NSUserDefaults.standardUserDefaults setObject:@[language] forKey:@"AppleLanguages"];
    } else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"AppleLanguages"];
    }
}

+ (double)nudityThreshold {
    return MIN(MAX([NSUserDefaults.standardUserDefaults doubleForKey:POKeyNudityThreshold], 0.05), 0.99);
}
+ (void)setNudityThreshold:(double)value {
    [NSUserDefaults.standardUserDefaults setDouble:value forKey:POKeyNudityThreshold];
    [self didChange];
}

@end
