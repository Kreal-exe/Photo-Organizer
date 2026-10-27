#import "POCompressController.h"
#import "POStrings.h"

static NSString *const POCompressVideoHeightKey = @"compressVideoHeight";
static NSString *const POCompressVideoQualityKey = @"compressVideoQuality";

@implementation POCompressController {
    NSArray<POPhotoItem *> *_raws, *_allVideos;
    NSInteger _typicalMegapixels, _typicalCount, _rawMegapixels;
    double _typicalBytesPerMegapixel;
    NSMutableArray<NSNumber *> *_sizes;
    NSButton *_photosCheckbox, *_videosCheckbox, *_confirmButton;
    NSPopUpButton *_sizePopup, *_heightPopup, *_qualityPopup;
    NSTextField *_photoEstimate, *_videoEstimate, *_totalLabel;
    // What the trial compression found: bytes per photo at each size tried.
    NSMutableDictionary<NSNumber *, NSNumber *> *_sampled;
    NSMapTable<POPhotoItem *, POVideoInfo *> *_probed;
    NSUInteger _probeDone;
    BOOL _probing, _closed;
    // Which videos by resolution (POVideoResolutionNames): a checkbox each, all ticked at first.
    NSStackView *_classStack;
    BOOL _classOn[4];
    BOOL _againOn;   // the videos compressed already, squeezed further: only when ticked
    NSSet<POPhotoItem *> *_live;   // the videos of live photos (see init), compressed only when ticked
    BOOL _liveOn;
    NSMutableArray<NSArray<NSArray *> *> *_rowJobs;   // the videos of each row of resolutions, for its list (by the button's tag)
    NSPopover *_listPopover;
}

- (instancetype)initWithItems:(NSArray<POPhotoItem *> *)items library:(NSArray<POPhotoItem *> *)library {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _raws = [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
            return POIsRawItem(item) && !item.isCloudOnly;
        }]];
        _allVideos = [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(POPhotoItem *item, NSDictionary *bindings) {
            return item.isVideo && !item.isCloudOnly;
        }]];
        // The videos of live photos: short, next to a photo of the same name (IMG_1234.HEIC and .MOV, MVIMG_….jpg and
        // .MP4). Squeezed they lose a little more than the others, for little: apart, and left alone unless ticked.
        NSMutableSet<NSString *> *photoNames = [NSMutableSet set];
        for (POPhotoItem *item in library) {
            if (!item.isVideo) [photoNames addObject:item.url.URLByDeletingPathExtension.path.lowercaseString];
        }
        NSMutableSet<POPhotoItem *> *live = [NSMutableSet set];
        for (POPhotoItem *video in _allVideos) {
            if (video.duration > 0 && video.duration <= 5 && [photoNames containsObject:video.url.URLByDeletingPathExtension.path.lowercaseString]) {
                [live addObject:video];
            }
        }
        _live = live;
        POTypicalPhoto(library, &_typicalMegapixels, &_typicalBytesPerMegapixel, &_typicalCount);
        // The largest of the RAW photos: every size up to it is offered (12, 24, 48 MP and the library's own).
        for (POPhotoItem *item in _raws) _rawMegapixels = MAX(_rawMegapixels, (NSInteger)llround(item.pixelWidth * (double)item.pixelHeight / 1e6));
        _sizes = [NSMutableArray array];
        _sampled = [NSMutableDictionary dictionary];
        _probed = [NSMapTable strongToStrongObjectsMapTable];
    }
    return self;
}

static NSTextField *POSmallLabel(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.textColor = NSColor.secondaryLabelColor;
    return label;
}

static NSTextField *POHint(NSString *text) {
    NSTextField *hint = [NSTextField wrappingLabelWithString:text];
    hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.selectable = NO;
    hint.preferredMaxLayoutWidth = 470;
    return hint;
}

/// The options of a checkbox, under it.
static NSStackView *POIndented(NSArray<NSView *> *views) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    stack.edgeInsets = NSEdgeInsetsMake(2, 22, 0, 0);
    return stack;
}

- (void)loadView {
    NSTextField *title = [NSTextField labelWithString:POL(@"Сжать")];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObjects:title,
        POHint(POL(@"Сжатые файлы занимают место оригиналов: RAW станет JPEG с тем же именем, видео останется под своим именем. Оригиналы уходят в Корзину — их можно вернуть оттуда, пока Корзина не очищена.")), nil];

    // Photos.
    if (_raws.count) {
        unsigned long long bytes = 0;
        for (POPhotoItem *item in _raws) bytes += item.fileSize;
        _photosCheckbox = [NSButton checkboxWithTitle:[NSString stringWithFormat:POL(@"RAW-фото: %@ · %@"), PONumber(_raws.count), POByteSize((long long)bytes)]
                                               target:self action:@selector(update)];
        _photosCheckbox.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
        _photosCheckbox.state = NSControlStateValueOn;
        _sizePopup = [NSPopUpButton new];
        // As most photos of the library first, then the usual sizes up to the RAW's own.
        for (NSNumber *mp in @[@(_typicalMegapixels), @12, @24, @48]) {
            NSInteger value = mp.integerValue;
            if (value <= 0 || (_rawMegapixels > 0 && value > _rawMegapixels) || [_sizes containsObject:mp]) continue;
            [_sizes addObject:mp];
            NSString *label = value == _typicalMegapixels && _typicalCount > 0
                ? [NSString stringWithFormat:POL(@"%@ МП — как большинство фото в медиатеке (%@)"), mp, PONumber(_typicalCount)]
                : _rawMegapixels > 0 && value >= _rawMegapixels ? [NSString stringWithFormat:POL(@"%@ МП — как в оригинале"), mp]
                : [NSString stringWithFormat:POL(@"%@ МП"), mp];
            [_sizePopup addItemWithTitle:label];
        }
        if (!_sizes.count) {
            [_sizes addObject:@(_rawMegapixels)];
            [_sizePopup addItemWithTitle:[NSString stringWithFormat:POL(@"%@ МП — как в оригинале"), @(_rawMegapixels)]];
        }
        _sizePopup.target = self;
        _sizePopup.action = @selector(sizeChanged:);
        _photoEstimate = POHint(@"");
        _photoEstimate.textColor = NSColor.labelColor;
        NSArray<NSView *> *photoViews = @[POSmallLabel(POL(@"Размер")), _sizePopup,
            POHint(POL(@"HDR сохраняется: JPEG с картой яркости (Ultra HDR, ISO 21496-1) — яркие места светятся на HDR-экранах, как в оригинале на iPhone. Дата, место и камера — как в оригинале.")),
            _photoEstimate];
        [views addObject:_photosCheckbox];
        [views addObject:POIndented(photoViews)];
    }

    // Videos.
    if (_allVideos.count) {
        unsigned long long bytes = 0;
        for (POPhotoItem *item in _allVideos) bytes += item.fileSize;
        _videosCheckbox = [NSButton checkboxWithTitle:[NSString stringWithFormat:POL(@"Видео: %@ · %@"), PONumber(_allVideos.count), POByteSize((long long)bytes)]
                                               target:self action:@selector(update)];
        _videosCheckbox.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
        _videosCheckbox.state = NSControlStateValueOn;
        _heightPopup = [NSPopUpButton new];
        NSArray<NSNumber *> *heights = POCompressionVideoHeights();
        for (NSNumber *height in heights) {
            [_heightPopup addItemWithTitle:height.integerValue == 2160 ? POL(@"4K (2160p)")
                                         : height.integerValue == POCompressionDefaultVideoHeight ? [NSString stringWithFormat:POL(@"%@p — рекомендуется"), height]
                                         : [NSString stringWithFormat:@"%@p", height]];
        }
        id savedHeight = [NSUserDefaults.standardUserDefaults objectForKey:POCompressVideoHeightKey];
        NSUInteger heightIndex = [heights indexOfObject:savedHeight ?: @(POCompressionDefaultVideoHeight)];
        [_heightPopup selectItemAtIndex:heightIndex == NSNotFound ? 1 : (NSInteger)heightIndex];
        _heightPopup.target = self;
        _heightPopup.action = @selector(update);
        _qualityPopup = [NSPopUpButton new];
        [_qualityPopup addItemsWithTitles:@[POL(@"Максимальное"), POL(@"Высокое — без видимых потерь"), POL(@"Экономное")]];
        id savedQuality = [NSUserDefaults.standardUserDefaults objectForKey:POCompressVideoQualityKey];
        [_qualityPopup selectItemAtIndex:MIN(MAX(savedQuality ? [savedQuality integerValue] : POCompressionDefaultVideoQuality, 0), 2)];
        _qualityPopup.target = self;
        _qualityPopup.action = @selector(update);
        _videoEstimate = POHint(@"");
        _videoEstimate.textColor = NSColor.labelColor;
        _classStack = [NSStackView new];
        _classStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        _classStack.alignment = NSLayoutAttributeLeading;
        _classStack.spacing = 4;
        for (int i = 0; i < 4; i++) _classOn[i] = YES;
        NSArray<NSView *> *videoViews = @[POSmallLabel(POL(@"Разрешение не больше")), _heightPopup, POSmallLabel(POL(@"Качество")), _qualityPopup,
            POSmallLabel(POL(@"Какие видео сжимать")), _classStack,
            POHint(POL(@"HDR сохраняется: HEVC 10 бит с тем же описанием цвета (HLG, PQ), Dolby Vision, HDR Vivid и HDR10+ — в каждом кадре. Без B-кадров, ключевой кадр каждую секунду — плавно на телефоне. Звук, дата и место съёмки — как в оригинале. Видео, которые и так весят немного, не трогаются.")),
            _videoEstimate];
        [views addObject:_videosCheckbox];
        [views addObject:POIndented(videoViews)];
    }
    if (!_raws.count && !_allVideos.count) {
        [views addObject:POHint(POL(@"Среди выбранных файлов нет RAW-фото и видео — сжимать нечего. Обычные JPEG и HEIC уже сжаты."))];
    }
    _totalLabel = [NSTextField labelWithString:@""];
    _totalLabel.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
    [views addObject:_totalLabel];

    NSButton *cancel = [NSButton buttonWithTitle:POL(@"Отмена") target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\e";
    _confirmButton = [NSButton buttonWithTitle:POL(@"Сжать") target:self action:@selector(confirm:)];
    _confirmButton.keyEquivalent = @"\r";
    NSStackView *buttons = [NSStackView stackViewWithViews:@[[NSView new], cancel, _confirmButton]];
    [views addObject:buttons];

    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    [stack setCustomSpacing:14 afterView:views[1]];
    if (_photoEstimate) [stack setCustomSpacing:16 afterView:_photoEstimate.superview];
    if (_videoEstimate) [stack setCustomSpacing:16 afterView:_videoEstimate.superview];
    [stack setCustomSpacing:16 afterView:_totalLabel];
    [buttons.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40].active = YES;
    // 780 wide at first, wider by dragging its edge — the rows of resolutions are long. As on Windows.
    [stack.widthAnchor constraintGreaterThanOrEqualToConstant:560].active = YES;
    NSLayoutConstraint *preferred = [stack.widthAnchor constraintEqualToConstant:780];
    preferred.priority = NSLayoutPriorityDefaultLow;
    preferred.active = YES;
    self.view = stack;
    [self update];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    self.view.window.styleMask |= NSWindowStyleMaskResizable;
    [self sample];
    [self probe];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    _closed = YES;
}

- (NSInteger)megapixels {
    return _sizes.count ? _sizes[MAX(_sizePopup.indexOfSelectedItem, 0)].integerValue : 12;
}

- (NSInteger)videoHeight {
    return POCompressionVideoHeights()[MAX(_heightPopup.indexOfSelectedItem, 0)].integerValue;
}

- (NSInteger)videoQuality {
    return MAX(_qualityPopup.indexOfSelectedItem, 0);
}

- (NSArray<POPhotoItem *> *)photos {
    return _photosCheckbox.state == NSControlStateValueOn ? _raws : @[];
}

- (NSArray<NSArray *> *)videos {
    if (_videosCheckbox.state != NSControlStateValueOn) return @[];
    NSMutableArray<NSArray *> *videos = [NSMutableArray array];
    for (NSArray *video in [self allJobs]) {
        BOOL live = [_live containsObject:video[0]] && !((POVideoJob *)video[2]).rebuild;
        BOOL on = live ? _liveOn : ((POVideoJob *)video[2]).again ? _againOn : _classOn[POVideoResolutionClass(video[1])];
        if (on) [videos addObject:video];
    }
    return videos;
}

/// Every video worth compressing with the size and quality chosen, whatever its resolution.
- (NSArray<NSArray *> *)allJobs {
    NSMutableArray<NSArray *> *videos = [NSMutableArray array];
    for (POPhotoItem *item in _allVideos) {
        POVideoInfo *info = [_probed objectForKey:item];
        POVideoJob *job = info ? POPlanVideo(info, self.videoHeight, self.videoQuality) : nil;
        if (job) [videos addObject:@[item, info, job]];
    }
    return videos;
}

/// A checkbox for each resolution found: "4K: 1 234 видео · 400 ГБ → 90 ГБ (−78 %)".
- (void)updateClasses {
    NSArray<NSArray *> *all = [self allJobs];
    NSUInteger found[4] = {0}, count[4] = {0}, planned[4] = {0}, rebuilt[4] = {0}, againCount = 0;
    long long againBefore = 0, againAfter = 0;
    long long before[4] = {0}, after[4] = {0}, rebuiltBefore[4] = {0}, rebuiltAfter[4] = {0};
    for (POPhotoItem *item in _allVideos) {
        POVideoInfo *info = [_probed objectForKey:item];
        if (info) found[POVideoResolutionClass(info)]++;
    }
    for (NSArray *video in all) {
        NSInteger kind = POVideoResolutionClass(video[1]);
        planned[kind]++;
        if ([_live containsObject:video[0]] && !((POVideoJob *)video[2]).rebuild) continue;   // a row of their own
        if (((POVideoJob *)video[2]).again) {
            againCount++;
            againBefore += (long long)((POPhotoItem *)video[0]).fileSize;
            againAfter += ((POVideoJob *)video[2]).estimatedSize;
            continue;
        }
        // What is compressed, and apart from it what is only rebuilt without B-frames (it comes out a little larger):
        // together they would read as "−0 %". As on Windows.
        if (((POVideoJob *)video[2]).rebuild) {
            rebuilt[kind]++;
            rebuiltBefore[kind] += (long long)((POPhotoItem *)video[0]).fileSize;
            rebuiltAfter[kind] += ((POVideoJob *)video[2]).estimatedSize;
            continue;
        }
        count[kind]++;
        before[kind] += (long long)((POPhotoItem *)video[0]).fileSize;
        after[kind] += ((POVideoJob *)video[2]).estimatedSize;
    }
    for (NSView *view in _classStack.arrangedSubviews.copy) [view removeFromSuperview];
    _rowJobs = [NSMutableArray array];
    NSMutableArray<NSMutableArray<NSArray *> *> *byKind = [NSMutableArray array];
    for (NSInteger kind = 0; kind < 6; kind++) [byKind addObject:[NSMutableArray array]];
    for (NSArray *video in all) {
        NSInteger row = [_live containsObject:video[0]] && !((POVideoJob *)video[2]).rebuild ? 5 : ((POVideoJob *)video[2]).again ? 4 : POVideoResolutionClass(video[1]);
        [byKind[row] addObject:video];
    }
    NSArray<NSString *> *names = POVideoResolutionNames();
    for (NSInteger kind = 0; kind < 4; kind++) {
        if (!found[kind]) continue;
        NSString *text = count[kind]
            ? [NSString stringWithFormat:POL(@"%@: %@ · %@"), names[kind], POCount(count[kind], POL(@"видео"), POL(@"видео"), POL(@"видео")),
               POCompressionSaving(before[kind], after[kind])]
            : rebuilt[kind] ? [NSString stringWithFormat:POL(@"%@: сжимать нечего"), names[kind]]
            : [NSString stringWithFormat:POL(@"%@: нечего сжимать"), names[kind]];
        if ((count[kind] || rebuilt[kind]) && found[kind] > planned[kind]) {
            text = [text stringByAppendingFormat:@" · %@", [NSString stringWithFormat:POL(@"ещё %@ и так компактные"), PONumber(found[kind] - planned[kind])]];
        }
        // Compressed before with B-frames: rebuilt without them, so phones play them smoothly. As on Windows.
        if (rebuilt[kind]) {
            text = [text stringByAppendingFormat:@"\n%@", [NSString stringWithFormat:POL(@"В %@ B-кадры (на телефоне идут рывками) — они будут убраны, кадры и HDR останутся те же: %@"),
                                                          POCount(rebuilt[kind], POL(@"видео"), POL(@"видео"), POL(@"видео")), POCompressionSaving(rebuiltBefore[kind], rebuiltAfter[kind])]];
        }
        NSButton *box = [NSButton checkboxWithTitle:text target:self action:@selector(classToggled:)];
        box.tag = kind;
        box.state = _classOn[kind] && count[kind] ? NSControlStateValueOn : NSControlStateValueOff;
        box.enabled = count[kind] > 0;
        [_classStack addArrangedSubview:count[kind] ? [self row:box listing:byKind[kind]] : box];
    }
    // Compressed already (HEVC near the quality asked): apart, off unless ticked. As on Windows.
    if (againCount) {
        NSString *text = [NSString stringWithFormat:POL(@"Уже сжатые — можно дожать: %@ · %@"), POCount(againCount, POL(@"видео"), POL(@"видео"), POL(@"видео")),
                          POCompressionSaving(againBefore, againAfter)];
        NSButton *again = [NSButton checkboxWithTitle:text target:self action:@selector(againToggled:)];
        again.toolTip = POL(@"Видео уже в HEVC и близко к выбранному качеству. Их можно сжать ещё раз — каждое повторное сжатие немного теряет в качестве.");
        again.state = _againOn ? NSControlStateValueOn : NSControlStateValueOff;
        [_classStack addArrangedSubview:[self row:again listing:byKind[4]]];
    }
    // The videos of live photos: apart, off unless ticked. As on Windows.
    NSArray<NSArray *> *live = byKind[5];
    if (!live.count) return;
    long long liveBefore = 0, liveAfter = 0;
    for (NSArray *video in live) {
        liveBefore += (long long)((POPhotoItem *)video[0]).fileSize;
        liveAfter += ((POVideoJob *)video[2]).estimatedSize;
    }
    NSString *liveText = [NSString stringWithFormat:POL(@"Видео живых фото: %@ · %@"), POCount(live.count, POL(@"видео"), POL(@"видео"), POL(@"видео")),
                          POCompressionSaving(liveBefore, liveAfter)];
    NSButton *liveBox = [NSButton checkboxWithTitle:liveText target:self action:@selector(liveToggled:)];
    liveBox.toolTip = POL(@"Короткие видео живых фото iPhone и Android (рядом лежит фото с тем же именем). После сжатия они чуть мягче, а весят и так немного — без галочки не трогаются.");
    liveBox.state = _liveOn ? NSControlStateValueOn : NSControlStateValueOff;
    [_classStack addArrangedSubview:[self row:liveBox listing:live]];
}

- (void)liveToggled:(NSButton *)sender {
    _liveOn = sender.state == NSControlStateValueOn;
    [self update];
}

/// A row of the resolutions with "Список ▾" after it, which shows its videos. As on Windows.
- (NSView *)row:(NSButton *)box listing:(NSArray<NSArray *> *)videos {
    NSButton *list = [NSButton buttonWithTitle:POL(@"Список ▾") target:self action:@selector(showList:)];
    list.bezelStyle = NSBezelStyleInline;
    list.controlSize = NSControlSizeSmall;
    list.toolTip = POL(@"Какие это видео: имя, сколько весит сейчас и сколько будет");
    list.tag = (NSInteger)_rowJobs.count;
    [_rowJobs addObject:videos];
    NSStackView *row = [NSStackView stackViewWithViews:@[box, list]];
    row.spacing = 10;
    return row;
}

/// The videos of a row, in a list under its button: the largest first, each with what it weighs now and what it
/// should weigh, its size and frame rate.
- (void)showList:(NSButton *)sender {
    if (_listPopover.isShown) [_listPopover close];
    NSArray<NSArray *> *videos = [_rowJobs[(NSUInteger)sender.tag] sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        unsigned long long sizeA = ((POPhotoItem *)a[0]).fileSize, sizeB = ((POPhotoItem *)b[0]).fileSize;
        return sizeA > sizeB ? NSOrderedAscending : sizeA < sizeB ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSArray *video in videos) {
        POPhotoItem *item = video[0];
        POVideoInfo *info = video[1];
        POVideoJob *job = video[2];
        [lines addObject:[NSString stringWithFormat:@"%@ — %@ → ≈ %@ · %ld×%ld, %@%@", item.url.lastPathComponent, POByteSize((long long)item.fileSize),
                          POByteSize(job.estimatedSize), (long)info.width, (long)info.height,
                          [NSString stringWithFormat:POL(@"%@ кадр/с"), @(llround(info.fps))],
                          [(info.hdr ? @" · HDR" : @"") stringByAppendingString:
                              [([info.dynamicHdr isEqualToString:@"dolby vision"] ? @" · Dolby Vision" : [info.dynamicHdr isEqualToString:@"vivid"] ? @" · HDR Vivid"
                                : [info.dynamicHdr isEqualToString:@"hdr10+"] ? @" · HDR10+" : @"")
                               stringByAppendingString:job.rebuild ? [@" · " stringByAppendingString:POL(@"B-кадры будут убраны")] : @""]]]];
    }
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 600, 340)];
    scroll.hasVerticalScroller = YES;
    NSTextView *text = [[NSTextView alloc] initWithFrame:scroll.bounds];
    text.editable = NO;
    text.textContainerInset = NSMakeSize(6, 6);
    text.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    text.string = [lines componentsJoinedByString:@"\n"];
    text.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = text;
    NSViewController *content = [NSViewController new];
    content.view = scroll;
    _listPopover = [NSPopover new];
    _listPopover.behavior = NSPopoverBehaviorTransient;
    _listPopover.contentViewController = content;
    _listPopover.contentSize = scroll.frame.size;
    [_listPopover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMaxY];
}

- (void)againToggled:(NSButton *)sender {
    _againOn = sender.state == NSControlStateValueOn;
    [self update];
}

- (void)classToggled:(NSButton *)sender {
    _classOn[sender.tag] = sender.state == NSControlStateValueOn;
    [self update];
}

- (void)sizeChanged:(id)sender {
    [self update];
    [self sample];
}

- (void)update {
    long long before = 0, after = 0;
    if (_raws.count) {
        NSNumber *sampled = _sampled[@(self.megapixels)];
        // The gain map adds about a tenth.
        double each = sampled ? sampled.doubleValue : self.megapixels * _typicalBytesPerMegapixel * 1.1;
        long long photosBefore = 0, photosAfter = (long long)(each * _raws.count);
        for (POPhotoItem *item in _raws) photosBefore += item.fileSize;
        _photoEstimate.stringValue = [NSString stringWithFormat:POL(@"Станет ≈ %@ — %@ на снимок, %@."), POByteSize(photosAfter), POByteSize((long long)each),
                                      sampled ? POL(@"по пробному сжатию") : POL(@"оценка по фото медиатеки, уточняется пробным сжатием…")];
        if (_photosCheckbox.state == NSControlStateValueOn) {
            before += photosBefore;
            after += photosAfter;
        }
    }
    if (_allVideos.count) {
        [self updateClasses];
        NSArray<NSArray *> *jobs = self.videos;
        long long videosBefore = 0, videosAfter = 0;
        for (NSArray *video in jobs) {
            videosBefore += (long long)((POPhotoItem *)video[0]).fileSize;
            videosAfter += [(POVideoJob *)video[2] estimatedSize];
        }
        // The compressing and the rebuilding apart: together they would read as "−0 %". As on Windows.
        NSUInteger squeezed = 0, rebuilt = 0;
        long long squeezedBefore = 0, squeezedAfter = 0, rebuiltBefore = 0, rebuiltAfter = 0;
        for (NSArray *video in jobs) {
            if (((POVideoJob *)video[2]).rebuild) { rebuilt++; rebuiltBefore += (long long)((POPhotoItem *)video[0]).fileSize; rebuiltAfter += [(POVideoJob *)video[2] estimatedSize]; }
            else { squeezed++; squeezedBefore += (long long)((POPhotoItem *)video[0]).fileSize; squeezedAfter += [(POVideoJob *)video[2] estimatedSize]; }
        }
        NSString *text = squeezed
            ? [NSString stringWithFormat:POL(@"Сожмутся %@: %@."), POCount(squeezed, POL(@"видео"), POL(@"видео"), POL(@"видео")), POCompressionSaving(squeezedBefore, squeezedAfter)]
            : jobs.count ? @"" : POL(@"Нечего сжимать: видео уже не больше этого размера и весят немного.");
        if (rebuilt) {
            text = [text stringByAppendingFormat:@"%@%@", text.length ? @" " : @"",
                    [NSString stringWithFormat:POL(@"Пересоберутся без B-кадров %@: %@."), POCount(rebuilt, POL(@"видео"), POL(@"видео"), POL(@"видео")), POCompressionSaving(rebuiltBefore, rebuiltAfter)]];
        }
        // Those that cannot be compressed without losing part of them: how many, and why. As on Windows.
        NSCountedSet<NSString *> *reasons = [NSCountedSet set];
        for (POVideoInfo *info in _probed.objectEnumerator) if (info.kept) [reasons addObject:info.kept];
        NSUInteger special = 0;
        for (NSString *reason in reasons) special += [reasons countForObject:reason];
        NSUInteger skipped = _probed.count - [self allJobs].count - special;
        if (jobs.count && skipped > 0 && _videosCheckbox.state == NSControlStateValueOn) {
            text = [text stringByAppendingFormat:@" %@", [NSString stringWithFormat:POL(@"Остальные %@ и так компактные — не трогаются."), PONumber(skipped)]];
        }
        for (NSString *reason in reasons) {
            text = [text stringByAppendingFormat:@" %@", [NSString stringWithFormat:POL(@"Не сжимаются (%@): %@."), PONumber([reasons countForObject:reason]), reason]];
        }
        if (_probing) text = [text stringByAppendingFormat:@" %@", [NSString stringWithFormat:POL(@"Проверено %@ из %@…"), PONumber(_probeDone), PONumber(_allVideos.count)]];
        _videoEstimate.stringValue = text;
        before += videosBefore;
        after += videosAfter;
    }
    _totalLabel.stringValue = before > 0 ? [NSString stringWithFormat:POL(@"Итого: %@"), POCompressionSaving(before, after)] : @"";
    // While the videos are being read, only the photos can go.
    _confirmButton.enabled = !(_probing && _videosCheckbox.state == NSControlStateValueOn) && (self.photos.count > 0 || self.videos.count > 0);
}

/// Two RAW photos compressed in memory at the size chosen, to say how much they will weigh.
- (void)sample {
    NSInteger megapixels = self.megapixels;
    if (!_raws.count || _sampled[@(megapixels)]) return;
    // Spread over the selection: the first ones are often of one day.
    NSOrderedSet<POPhotoItem *> *trial = [NSOrderedSet orderedSetWithArray:@[_raws[_raws.count / 3], _raws[_raws.count * 2 / 3]]];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        double total = 0;
        NSUInteger count = 0;
        for (POPhotoItem *item in trial) {
            @autoreleasepool {
                NSData *jpeg = POCompressRawPhoto(item.url, megapixels, NULL, NULL);
                if (jpeg) {
                    total += jpeg.length;
                    count++;
                }
            }
        }
        if (!count) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) me = weakSelf;
            if (!me || me->_closed) return;
            me->_sampled[@(megapixels)] = @(total / count);
            [me update];
        });
    });
}

/// Every video read (size, frame rate, bitrate, HDR), a few at a time, the estimate growing as it goes.
- (void)probe {
    if (!_allVideos.count || _probing) return;
    _probing = YES;
    _probeDone = 0;
    [self update];
    NSArray<POPhotoItem *> *videos = _allVideos;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = 4;
        for (POPhotoItem *item in videos) {
            [queue addOperationWithBlock:^{
                typeof(self) alive = weakSelf;
                if (!alive || alive->_closed) return;
                // Read once and remembered: the next time the window opens, only new or changed videos are read.
                POVideoInfo *info = POProbeVideoRemembered(item.url);
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) me = weakSelf;
                    if (!me) return;
                    if (info) [me->_probed setObject:info forKey:item];
                    if (++me->_probeDone % 25 == 0) [me update];
                });
            }];
        }
        [queue waitUntilAllOperationsAreFinished];
        POSaveProbedVideos();
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) me = weakSelf;
            if (!me) return;
            me->_probing = NO;
            [me update];
        });
    });
}

- (void)cancel:(id)sender {
    _closed = YES;
    [self dismissController:nil];
}

- (void)confirm:(id)sender {
    _closed = YES;
    if (_allVideos.count) {
        [NSUserDefaults.standardUserDefaults setInteger:self.videoHeight forKey:POCompressVideoHeightKey];
        [NSUserDefaults.standardUserDefaults setInteger:self.videoQuality forKey:POCompressVideoQualityKey];
    }
    [self dismissController:nil];
    if (self.completion) self.completion(self);
}

@end
