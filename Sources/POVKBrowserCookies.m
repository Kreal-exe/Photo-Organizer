#import "POVKBrowserCookies.h"
#import "POStrings.h"
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <Security/Security.h>
#import <sqlite3.h>

/// VK's own hosts and their subdomains, nothing else: "xvk.ru" must not match.
static NSString *const POVKHostCondition =
    @"(host_key IN ('vk.ru', '.vk.ru', 'vk.com', '.vk.com') OR host_key LIKE '%.vk.ru' OR host_key LIKE '%.vk.com')";

/// Chromium counts time in microseconds since 1601.
static const int64_t POChromiumEpochOffset = 11644473600;

/// The browser keeps its database open, and a read-only immutable connection does not wait for its locks.
static sqlite3 *POOpenCookies(NSURL *file) {
    NSString *uri = [[NSURL fileURLWithPath:file.path].absoluteString stringByAppendingString:@"?immutable=1"];
    sqlite3 *database = NULL;
    if (sqlite3_open_v2(uri.UTF8String, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
        sqlite3_close(database);
        return NULL;
    }
    return database;
}

/// When the profile last used its VK sign-in (Chromium time), or 0 when it has none.
static int64_t POLastVKUse(NSURL *file) {
    sqlite3 *database = POOpenCookies(file);
    if (!database) return 0;
    NSString *sql = [NSString stringWithFormat:@"SELECT max(last_access_utc) FROM cookies WHERE name = 'remixsid' AND %@", POVKHostCondition];
    sqlite3_stmt *statement = NULL;
    int64_t last = 0;
    if (sqlite3_prepare_v2(database, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW) {
        last = sqlite3_column_int64(statement, 0);
    }
    sqlite3_finalize(statement);
    sqlite3_close(database);
    return last;
}

/// "v10" + AES-128-CBC with a key derived from the Safe Storage password. Since database version 24 the plain text
/// starts with the SHA-256 of the host. A value without the prefix was never encrypted.
static NSString *PODecrypt(NSData *encrypted, NSData *password, BOOL hostHashed) {
    if (encrypted.length < 3 || memcmp(encrypted.bytes, "v1", 2) != 0) return nil;
    uint8_t key[kCCKeySizeAES128];
    if (CCKeyDerivationPBKDF(kCCPBKDF2, password.bytes, password.length, (const uint8_t *)"saltysalt", 9,
                             kCCPRFHmacAlgSHA1, 1003, key, sizeof key) != kCCSuccess) return nil;
    uint8_t iv[kCCBlockSizeAES128];
    memset(iv, ' ', sizeof iv);
    NSMutableData *plain = [NSMutableData dataWithLength:encrypted.length];
    size_t written = 0;
    if (CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key, sizeof key, iv,
                (const uint8_t *)encrypted.bytes + 3, encrypted.length - 3,
                plain.mutableBytes, plain.length, &written) != kCCSuccess) return nil;
    size_t skip = hostHashed ? 32 : 0;
    if (written < skip) return nil;
    return [[NSString alloc] initWithBytes:(const char *)plain.bytes + skip length:written - skip encoding:NSUTF8StringEncoding];
}

@interface POVKBrowserSession ()
@property (nonatomic, readwrite) NSString *browserName;
@property (nonatomic, readwrite) NSURL *cookiesFile;
@property (nonatomic, readwrite) NSString *keychainService;
@end

@implementation POVKBrowserSession
@end

@implementation POVKBrowserCookies

+ (POVKBrowserSession *)mostRecentSession {
    NSArray<NSArray<NSString *> *> *browsers = @[
        @[@"Google Chrome", @"Google/Chrome", @"Chrome Safe Storage"],
        @[@"Yandex Browser", @"Yandex/YandexBrowser", @"Yandex Safe Storage"],
        @[@"Arc", @"Arc/User Data", @"Arc Safe Storage"],
        @[@"Brave", @"BraveSoftware/Brave-Browser", @"Brave Safe Storage"],
        @[@"Microsoft Edge", @"Microsoft Edge", @"Microsoft Edge Safe Storage"],
        @[@"Vivaldi", @"Vivaldi", @"Vivaldi Safe Storage"],
        @[@"Opera", @"com.operasoftware.Opera", @"Opera Safe Storage"],
        @[@"Chromium", @"Chromium", @"Chromium Safe Storage"],
    ];
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *support = [manager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    POVKBrowserSession *best = nil;
    int64_t bestUse = 0;
    for (NSArray<NSString *> *browser in browsers) {
        NSURL *root = [support URLByAppendingPathComponent:browser[1] isDirectory:YES];
        NSMutableArray<NSURL *> *folders = [NSMutableArray arrayWithObject:root];
        NSArray<NSURL *> *profiles = [manager contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:NULL];
        if (profiles) [folders addObjectsFromArray:profiles];
        for (NSURL *folder in folders) {
            for (NSString *name in @[@"Cookies", @"Network/Cookies"]) {   // newer versions keep it in Network
                NSURL *file = [folder URLByAppendingPathComponent:name];
                if (![manager fileExistsAtPath:file.path]) continue;
                int64_t use = POLastVKUse(file);
                if (use <= bestUse) continue;
                bestUse = use;
                best = [POVKBrowserSession new];
                best.browserName = browser[0];
                best.cookiesFile = file;
                best.keychainService = browser[2];
            }
        }
    }
    return best;
}

+ (NSArray<NSHTTPCookie *> *)cookiesOfSession:(POVKBrowserSession *)session error:(NSString **)error {
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService: session.keychainService,
                            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
                            (__bridge id)kSecReturnData: @YES};
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSData *password = CFBridgingRelease(result);
    if (status != errSecSuccess || !password.length) {
        if (error) *error = [NSString stringWithFormat:POL(@"Связка ключей не дала ключ %@. Разрешите доступ, когда macOS спросит, и попробуйте снова."), session.browserName];
        return nil;
    }
    NSArray<NSHTTPCookie *> *cookies = [self cookiesInFile:session.cookiesFile password:password];
    if (!cookies.count) {
        if (error) *error = [NSString stringWithFormat:POL(@"Не получилось прочитать вход VK из %@."), session.browserName];
        return nil;
    }
    return cookies;
}

+ (NSArray<NSHTTPCookie *> *)cookiesInFile:(NSURL *)file password:(NSData *)password {
    sqlite3 *database = POOpenCookies(file);
    if (!database) return nil;

    int version = 0;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(database, "SELECT value FROM meta WHERE key = 'version'", -1, &statement, NULL) == SQLITE_OK
        && sqlite3_step(statement) == SQLITE_ROW) {
        version = sqlite3_column_int(statement, 0);
    }
    sqlite3_finalize(statement);
    statement = NULL;

    NSString *sql = [NSString stringWithFormat:@"SELECT host_key, name, path, value, encrypted_value, expires_utc, is_secure, is_httponly, samesite "
                                               @"FROM cookies WHERE %@", POVKHostCondition];
    NSMutableArray<NSHTTPCookie *> *cookies = [NSMutableArray array];
    if (sqlite3_prepare_v2(database, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        while (sqlite3_step(statement) == SQLITE_ROW) {
            int64_t expires = sqlite3_column_int64(statement, 5);
            NSTimeInterval expiry = (NSTimeInterval)expires / 1000000 - POChromiumEpochOffset;
            if (expires && expiry < now) continue;

            NSString *value = nil;
            const void *blob = sqlite3_column_blob(statement, 4);
            int blobLength = sqlite3_column_bytes(statement, 4);
            if (blob && blobLength) {
                value = PODecrypt([NSData dataWithBytes:blob length:blobLength], password, version >= 24);
            } else if (sqlite3_column_text(statement, 3)) {
                value = @((const char *)sqlite3_column_text(statement, 3));
            }
            const char *host = (const char *)sqlite3_column_text(statement, 0);
            const char *name = (const char *)sqlite3_column_text(statement, 1);
            const char *path = (const char *)sqlite3_column_text(statement, 2);
            if (!value || !host || !name || !path) continue;

            NSMutableDictionary<NSHTTPCookiePropertyKey, id> *properties = [@{
                NSHTTPCookieDomain: @(host), NSHTTPCookieName: @(name), NSHTTPCookiePath: @(path), NSHTTPCookieValue: value,
            } mutableCopy];
            if (expires) properties[NSHTTPCookieExpires] = [NSDate dateWithTimeIntervalSince1970:expiry];
            if (sqlite3_column_int(statement, 6)) properties[NSHTTPCookieSecure] = @"TRUE";
            if (sqlite3_column_int(statement, 7)) properties[@"HttpOnly"] = @"TRUE";
            int sameSite = sqlite3_column_int(statement, 8);
            if (sameSite == 1) properties[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteLax;
            if (sameSite == 2) properties[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteStrict;
            NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
            if (cookie) [cookies addObject:cookie];
        }
    }
    sqlite3_finalize(statement);
    sqlite3_close(database);
    return cookies;
}

@end
