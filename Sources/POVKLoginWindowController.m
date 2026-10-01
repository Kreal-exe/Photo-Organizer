#import "POVKLoginWindowController.h"
#import "POVKAlbum.h"
#import "POStrings.h"
#import <WebKit/WebKit.h>

/// Runs inside the signed-in vk.ru page and asks VK for the token its own web version uses — the request
/// carries the page's cookies and origin exactly as when vk.ru does it. Returns the raw reply, or null.
static NSString *const POTokenScript =
    @"for (const host of ['https://login.vk.ru', 'https://login.vk.com']) {"
    @"  try {"
    @"    const reply = await fetch(host + '/?act=web_token', {method: 'POST', credentials: 'include',"
    @"      headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: 'version=1&app_id=6287487'});"
    @"    const text = await reply.text();"
    @"    if (text.includes('access_token')) return text;"
    @"  } catch (error) {}"
    @"}"
    @"return null;";

/// Finds "access_token" (and "user_id") anywhere in a JSON reply.
static void POFindToken(id object, NSString **token, NSString **userID) {
    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = object;
        if ([dictionary[@"access_token"] isKindOfClass:NSString.class]) *token = dictionary[@"access_token"];
        if (dictionary[@"user_id"]) *userID = [NSString stringWithFormat:@"%@", dictionary[@"user_id"]];
        for (id value in dictionary.allValues) POFindToken(value, token, userID);
    } else if ([object isKindOfClass:NSArray.class]) {
        for (id value in object) POFindToken(value, token, userID);
    }
}

@interface POVKLoginWindowController () <WKNavigationDelegate>
@end

@implementation POVKLoginWindowController {
    WKWebView *_webView;
    NSTextField *_hintLabel;
    NSButton *_doneButton;
    BOOL _asking;
}

+ (POVKLoginWindowController *)sharedController {
    static POVKLoginWindowController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [POVKLoginWindowController new]; });
    return shared;
}

+ (void)signOut {
    POVKSaveToken(nil);
    WKWebsiteDataStore *store = WKWebsiteDataStore.defaultDataStore;
    [store fetchDataRecordsOfTypes:WKWebsiteDataStore.allWebsiteDataTypes completionHandler:^(NSArray<WKWebsiteDataRecord *> *records) {
        NSMutableArray<WKWebsiteDataRecord *> *vk = [NSMutableArray array];
        for (WKWebsiteDataRecord *record in records) {
            if ([record.displayName containsString:@"vk."] || [record.displayName containsString:@"userapi"]) [vk addObject:record];
        }
        [store removeDataOfTypes:WKWebsiteDataStore.allWebsiteDataTypes forDataRecords:vk completionHandler:^{}];
    }];
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 680)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    if (!(self = [super initWithWindow:window])) return nil;
    window.title = POL(@"Вход в VK");

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;   // the sign-in survives relaunches
    _webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
    _webView.navigationDelegate = self;
    _webView.translatesAutoresizingMaskIntoConstraints = NO;

    _hintLabel = [NSTextField wrappingLabelWithString:POL(@"Войдите в свой аккаунт VK — логин и пароль вводятся на странице VK, приложение их не видит. "
                                                         @"Когда войдёте, окно закроется само; если нет — нажмите «Готово».")];
    _hintLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _hintLabel.textColor = NSColor.secondaryLabelColor;
    _hintLabel.selectable = NO;
    [_hintLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _doneButton = [NSButton buttonWithTitle:POL(@"Готово") target:self action:@selector(done:)];
    _doneButton.keyEquivalent = @"\r";
    NSStackView *bar = [NSStackView stackViewWithViews:@[_hintLabel, _doneButton]];
    bar.edgeInsets = NSEdgeInsetsMake(10, 14, 10, 14);
    bar.alignment = NSLayoutAttributeCenterY;
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *content = [NSView new];
    [content addSubview:bar];
    [content addSubview:_webView];
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:content.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_webView.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [_webView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_webView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_webView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];
    window.contentView = content;
    [window center];
    return self;
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [_webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://vk.ru/"]]];
}

/// Pages a signed-out visitor sees; anywhere else on vk.ru means the user is in.
- (BOOL)looksSignedIn:(NSURL *)url {
    if (![url.host hasSuffix:@"vk.ru"] && ![url.host hasSuffix:@"vk.com"]) return NO;
    if ([url.host hasPrefix:@"id."] || [url.host hasPrefix:@"login."] || [url.host hasPrefix:@"oauth."]) return NO;
    NSString *path = url.path;
    return path.length > 1 && ![path hasPrefix:@"/login"] && ![path hasPrefix:@"/join"] && ![path hasPrefix:@"/challenge"];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if ([self looksSignedIn:webView.URL]) [self askForTokenQuietly:YES];
}

- (void)done:(id)sender {
    [self askForTokenQuietly:NO];
}

- (void)askForTokenQuietly:(BOOL)quietly {
    if (_asking) return;
    _asking = YES;
    __weak typeof(self) weakSelf = self;
    [_webView callAsyncJavaScript:POTokenScript arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld
                completionHandler:^(id result, NSError *error) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me->_asking = NO;
        NSString *token = nil, *userID = @"";
        if ([result isKindOfClass:NSString.class]) {
            id json = [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
            POFindToken(json, &token, &userID);
        }
        if (!token.length) {
            if (!quietly) {
                me->_hintLabel.stringValue = POL(@"Не получилось получить доступ. Убедитесь, что вы вошли (видна ваша лента или страница), и нажмите «Готово» ещё раз.");
                me->_hintLabel.textColor = NSColor.systemRedColor;
            }
            return;
        }
        POVKSaveToken(token);
        [me close];
        if (me.onLogin) me.onLogin(userID);
    }];
}

@end
